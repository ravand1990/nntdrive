use axum::body::Body;
use axum::extract::connect_info::ConnectInfo;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use nntdrive_backend::app;
use nntdrive_backend::state::{AppState, ServerConfig};
use nntdrive_crypto::{derive_auth_verifier, KeyFile, MasterKey};
use nntdrive_nntp::{MockConfig, MockNntpServer, NntpPool};
use nntdrive_storage::TestDb;
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

struct Env {
    state: AppState,
    _db: TestDb,
    _server: MockNntpServer,
}

async fn env() -> Option<Env> {
    let db = TestDb::create().await?;
    let server = MockNntpServer::start(MockConfig::default()).await;
    let nntp = Arc::new(NntpPool::new(vec![server.client_config()]).unwrap());
    let cache = tempfile::tempdir().unwrap();
    let config = ServerConfig {
        bind: "127.0.0.1:0".into(),
        cache_dir: cache.path().to_path_buf(),
        cache_limit_bytes: 10 * 1024 * 1024,
        allow_registration: true,
        secret_key: [7u8; 32],
        default_quota_bytes: None,
        health_check_interval_secs: 3600,
        retention_refresh_days: 30,
        retention_interval_secs: 3600,
    };
    let state = AppState::new(db.store.pool().clone(), nntp, config).unwrap();
    Some(Env {
        state,
        _db: db,
        _server: server,
    })
}

fn req(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut b = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json");
    if let Some(t) = token {
        b = b.header("authorization", format!("Bearer {t}"));
    }
    let body = body.map_or_else(Body::empty, |v| Body::from(serde_json::to_vec(&v).unwrap()));
    let mut req = b.body(body).unwrap();
    req.extensions_mut()
        .insert(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 40000))));
    req
}

async fn call(state: &AppState, req: Request<Body>) -> (StatusCode, Value) {
    let resp = app(state.clone()).oneshot(req).await.unwrap();
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let value = serde_json::from_slice(&bytes).unwrap_or(json!(null));
    (status, value)
}

struct Account {
    account_id: Uuid,
    device_id: Uuid,
    token: String,
    master: MasterKey,
    verifier: String,
}

async fn register(state: &AppState, email: &str) -> Account {
    let account_id = Uuid::new_v4();
    let device_id = Uuid::new_v4();
    let device_key = nntdrive_crypto::DeviceKeypair::generate();
    let password = "correct horse battery staple";
    let (keyfile, master) = KeyFile::create(password, account_id).unwrap();
    let verifier = derive_auth_verifier(password, account_id);
    let (status, body) = call(
        state,
        req(
            "POST",
            "/api/v1/auth/register",
            None,
            Some(json!({
                "account_id": account_id,
                "email": email,
                "verifier": verifier,
                "keyfile": keyfile,
                "device": {
                    "id": device_id,
                    "name": "test",
                    "platform": "linux",
                    "public_key": base64_key(&device_key.public().0)
                }
            })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    Account {
        account_id,
        device_id,
        token: body["token"].as_str().unwrap().to_string(),
        master,
        verifier,
    }
}

fn base64_key(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[tokio::test]
async fn registration_login_and_admin_authorization() {
    let Some(env) = env().await else { return };
    let first = register(&env.state, "admin@example.com").await;
    let second = register(&env.state, "user@example.com").await;

    let (_, me) = call(
        &env.state,
        req("GET", "/api/v1/me", Some(&first.token), None),
    )
    .await;
    assert_eq!(me["is_admin"], true);
    let (_, me2) = call(
        &env.state,
        req("GET", "/api/v1/me", Some(&second.token), None),
    )
    .await;
    assert_eq!(me2["is_admin"], false);

    let (s, body) = call(
        &env.state,
        req("GET", "/api/v1/admin/stats", Some(&first.token), None),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(body["users"].as_i64().unwrap() >= 2);
    let (s, _) = call(
        &env.state,
        req("GET", "/api/v1/admin/stats", Some(&second.token), None),
    )
    .await;
    assert_eq!(s, StatusCode::FORBIDDEN);

    // Wrong verifier cannot log in.
    let (s, _) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/auth/login",
            None,
            Some(json!({ "email": "admin@example.com", "verifier": "00".repeat(32) })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);

    let (s, body) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/auth/login",
            None,
            Some(json!({ "email": "admin@example.com", "verifier": first.verifier })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(body["keyfile"].is_object());
    assert!(body["token"].as_str().unwrap().len() > 20);

    // A new device can resolve the account id before deriving its verifier.
    let (s, body) = call(
        &env.state,
        req(
            "GET",
            "/api/v1/auth/lookup?email=admin%40example.com",
            None,
            None,
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert_eq!(body["account_id"], first.account_id.to_string());
}

#[tokio::test]
async fn revoked_device_tokens_stop_working() {
    let Some(env) = env().await else { return };
    let account = register(&env.state, "revoke@example.com").await;
    let (s, _) = call(
        &env.state,
        req("GET", "/api/v1/me", Some(&account.token), None),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = call(
        &env.state,
        req(
            "DELETE",
            &format!("/api/v1/devices/{}", account.device_id),
            Some(&account.token),
            None,
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = call(
        &env.state,
        req("GET", "/api/v1/me", Some(&account.token), None),
    )
    .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn tenant_isolation_and_encrypted_upload_flow() {
    let Some(env) = env().await else { return };
    let alice = register(&env.state, "alice@example.com").await;
    let bob = register(&env.state, "bob@example.com").await;

    let file_id = Uuid::new_v4();
    let (s, body) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/files",
            Some(&alice.token),
            Some(json!({
                "id": file_id,
                "parent_id": null,
                "name_enc": base64_key(b"opaque-sealed-name"),
                "is_dir": false
            })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::CREATED, "{body}");

    // A file created by Alice is invisible to Bob.
    let (s, _) = call(
        &env.state,
        req("GET", "/api/v1/files", Some(&bob.token), None),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/files/{file_id}"),
            Some(&bob.token),
            Some(json!({ "favorite": true })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::NOT_FOUND);

    // Client-side encryption: prepare a chunk and publish only ciphertext.
    let plaintext = b"TOP-SECRET-CONTENT-DO-NOT-UPLOAD-PLAINTEXT".repeat(8000);
    let chunk = nntdrive_storage::Chunk {
        index: 0,
        offset: 0,
        hash: *blake3::hash(&plaintext).as_bytes(),
        data: plaintext.clone(),
    };
    let prepared = nntdrive_storage::prepare_chunk(&alice.master, &chunk, 3).unwrap();
    let (s, body) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/chunks",
            Some(&alice.token),
            Some(json!({
                "chunk_id": prepared.id,
                "index": 0,
                "offset": 0,
                "plaintext_hash": hex(&prepared.plaintext_hash),
                "plaintext_len": prepared.plaintext_len,
                "compression": prepared.compression as u8,
                "ciphertext": base64_key(&prepared.ciphertext),
            })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    let chunk_json = &body["chunk"];
    assert!(!chunk_json["stripes"].as_array().unwrap().is_empty());

    // Server-side articles must not contain the plaintext marker.
    for id in env._server.store.article_ids().await {
        let raw = env._server.store.raw_article(&id).await.unwrap();
        assert!(!raw.windows(16).any(|w| w == b"TOP-SECRET-CONTE"));
    }

    // Commit a sealed manifest for the version.
    let mut manifest = nntdrive_storage::FileManifest::new(
        file_id,
        Uuid::new_v4(),
        prepared.plaintext_len,
        "0".repeat(64),
    );
    manifest
        .chunks
        .push(serde_json::from_value(chunk_json.clone()).unwrap());
    let sealed = alice
        .master
        .seal_manifest(file_id, manifest.revision_id, &manifest.to_bytes())
        .unwrap()
        .to_bytes();
    let (s, body) = call(
        &env.state,
        req(
            "POST",
            &format!("/api/v1/files/{file_id}/versions"),
            Some(&alice.token),
            Some(json!({
                "revision_id": manifest.revision_id,
                "parent_revision": null,
                "base_revision": null,
                "size": manifest.size,
                "sealed_manifest": base64_key(&sealed)
            })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::CREATED, "{body}");

    // The owner can fetch the sealed manifest and an article through the proxy.
    let (s, _) = call(
        &env.state,
        req(
            "GET",
            &format!("/api/v1/files/{file_id}/manifest"),
            Some(&alice.token),
            None,
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);

    // Bob can neither read the sealed manifest nor the version list.
    let (s, _) = call(
        &env.state,
        req(
            "GET",
            &format!("/api/v1/files/{file_id}/manifest"),
            Some(&bob.token),
            None,
        ),
    )
    .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    let (s, _) = call(
        &env.state,
        req(
            "GET",
            &format!("/api/v1/files/{file_id}/versions"),
            Some(&bob.token),
            None,
        ),
    )
    .await;
    assert_eq!(s, StatusCode::NOT_FOUND);

    let stripe = &chunk_json["stripes"][0];
    let message_id = find_message_id(&env, stripe["id"].as_str().unwrap()).await;
    let (s, _) = call(
        &env.state,
        req(
            "GET",
            &format!("/api/v1/articles/{message_id}"),
            Some(&alice.token),
            None,
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = call(
        &env.state,
        req(
            "GET",
            &format!("/api/v1/articles/{message_id}"),
            Some(&bob.token),
            None,
        ),
    )
    .await;
    assert_eq!(s, StatusCode::NOT_FOUND);

    // The chunk is deduplicated for the same account.
    let (s, _) = call(
        &env.state,
        req(
            "GET",
            &format!(
                "/api/v1/chunks/lookup?hash={}&len={}",
                hex(&prepared.plaintext_hash),
                prepared.plaintext_len
            ),
            Some(&alice.token),
            None,
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
}

async fn find_message_id(env: &Env, stripe_id: &str) -> String {
    let id: Uuid = stripe_id.parse().unwrap();
    env.state
        .store
        .load_shards(id)
        .await
        .unwrap()
        .first()
        .unwrap()
        .message_id
        .clone()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
