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
async fn guarded_rename_rejects_namespace_races_and_foreign_nodes() {
    let Some(env) = env().await else { return };
    let alice = register(&env.state, "guard-alice@example.com").await;
    let bob = register(&env.state, "guard-bob@example.com").await;
    let ids = [Uuid::new_v4(), Uuid::new_v4()];
    for id in ids {
        let (s, _) = call(
            &env.state,
            req(
                "POST",
                "/api/v1/files",
                Some(&alice.token),
                Some(json!({"id": id, "name_enc": base64_key(id.as_bytes()), "is_dir": false})),
            ),
        )
        .await;
        assert_eq!(s, StatusCode::CREATED);
    }
    let snapshot = json!([
        {"id": ids[0], "name_enc": base64_key(ids[0].as_bytes())},
        {"id": ids[1], "name_enc": base64_key(ids[1].as_bytes())}
    ]);
    let body =
        json!({"parent_id": null, "name_enc": base64_key(b"new envelope"), "siblings": snapshot});
    let uri = format!("/api/v1/files/{}/rename", ids[0]);
    for target in [ids[0], Uuid::new_v4()] {
        let (s, _) = call(
            &env.state,
            req(
                "POST",
                &format!("/api/v1/files/{target}/rename"),
                Some(&bob.token),
                Some(body.clone()),
            ),
        )
        .await;
        assert_eq!(s, StatusCode::NOT_FOUND);
    }
    let mut missing = body.clone();
    missing["siblings"] = json!([]);
    let (s, _) = call(
        &env.state,
        req("POST", &uri, Some(&alice.token), Some(missing)),
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
    let mut duplicate = body.clone();
    duplicate["siblings"] = json!([snapshot[0], snapshot[0]]);
    let (s, _) = call(
        &env.state,
        req("POST", &uri, Some(&alice.token), Some(duplicate)),
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);

    let mut oversized = body.clone();
    oversized["siblings"] = json!(vec![snapshot[0].clone(); 4097]);
    let (s, _) = call(
        &env.state,
        req("POST", &uri, Some(&alice.token), Some(oversized)),
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let mut huge_body = body.clone();
    huge_body["name_enc"] = json!("a".repeat(2 * 1024 * 1024));
    let (s, _) = call(
        &env.state,
        req("POST", &uri, Some(&alice.token), Some(huge_body)),
    )
    .await;
    assert_eq!(s, StatusCode::PAYLOAD_TOO_LARGE);

    // Every namespace dimension checked locally must be checked atomically:
    // sibling addition, sibling rename, and source move all invalidate a guard.
    let folder = Uuid::new_v4();
    let (s, _) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/files",
            Some(&alice.token),
            Some(json!({"id": folder, "name_enc": base64_key(b"folder envelope"), "is_dir": true})),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::CREATED);
    let (s, _) = call(
        &env.state,
        req("POST", &uri, Some(&alice.token), Some(body.clone())),
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
    let (_, with_folder) = call(
        &env.state,
        req("GET", "/api/v1/files", Some(&alice.token), None),
    )
    .await;
    let mut including_folder = body.clone();
    including_folder["siblings"] = with_folder["files"].clone();
    let (s, _) = call(
        &env.state,
        req(
            "POST",
            &format!("/api/v1/files/{}/move", ids[0]),
            Some(&alice.token),
            Some(json!({"parent_id": folder})),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = call(
        &env.state,
        req("POST", &uri, Some(&alice.token), Some(including_folder)),
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
    let (s, _) = call(
        &env.state,
        req(
            "POST",
            &format!("/api/v1/files/{}/move", ids[0]),
            Some(&alice.token),
            Some(json!({"parent_id": null})),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/files/{folder}"),
            Some(&alice.token),
            Some(json!({"deleted": true})),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/files/{}", ids[1]),
            Some(&alice.token),
            Some(json!({"name_enc": base64_key(b"legacy new name")})),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = call(
        &env.state,
        req("POST", &uri, Some(&alice.token), Some(body.clone())),
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
    let (s, _) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/files/{}", ids[1]),
            Some(&alice.token),
            Some(json!({"name_enc": base64_key(ids[1].as_bytes())})),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);

    // Prove the guarded endpoint actually waits for namespace ownership, rather
    // than relying on favorable task scheduling in the race below.
    let mut owner = env.state.pool.begin().await.unwrap();
    sqlx::query("SELECT id FROM accounts WHERE id = $1 FOR UPDATE")
        .bind(alice.account_id)
        .fetch_one(&mut *owner)
        .await
        .unwrap();
    let state = env.state.clone();
    let token = alice.token.clone();
    let blocked_uri = uri.clone();
    let mut invalid = body.clone();
    invalid["siblings"] = json!([]);
    let mut blocked = tokio::spawn(async move {
        call(
            &state,
            req("POST", &blocked_uri, Some(&token), Some(invalid)),
        )
        .await
    });
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(100), &mut blocked)
            .await
            .is_err()
    );
    owner.rollback().await.unwrap();
    assert_eq!(blocked.await.unwrap().0, StatusCode::CONFLICT);

    // Two valid collision-preflight requests from the same snapshot cannot both
    // commit, even though their independently sealed names differ in ciphertext.
    let mut other = body.clone();
    other["name_enc"] = json!(base64_key(b"another randomized envelope"));
    let uri2 = format!("/api/v1/files/{}/rename", ids[1]);
    let (first, second) = tokio::join!(
        call(
            &env.state,
            req("POST", &uri, Some(&alice.token), Some(body.clone()))
        ),
        call(
            &env.state,
            req("POST", &uri2, Some(&alice.token), Some(other))
        )
    );
    let mut statuses = [first.0.as_u16(), second.0.as_u16()];
    statuses.sort();
    assert_eq!(statuses, [200, 409]);
    let (_, listing) = call(
        &env.state,
        req("GET", "/api/v1/files", Some(&alice.token), None),
    )
    .await;
    let rows = listing["files"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(
        rows.iter()
            .filter(|r| {
                r["name_enc"] == base64_key(b"new envelope")
                    || r["name_enc"] == base64_key(b"another randomized envelope")
            })
            .count(),
        1
    );
    assert!(rows.iter().all(|r| r["current_version"].is_null()));
    let events: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM sync_events WHERE account_id = $1 AND kind = 'rename'",
    )
    .bind(alice.account_id)
    .fetch_one(&env.state.pool)
    .await
    .unwrap();
    assert_eq!(events, 1);

    // A fresh snapshot is invalidated by legacy namespace writers as well.
    let fresh = json!({"parent_id": null, "name_enc": base64_key(b"next envelope"),
        "siblings": rows.iter().map(|r| json!({"id": r["id"], "name_enc": r["name_enc"]})).collect::<Vec<_>>()});
    let (s, _) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/files/{}", ids[1]),
            Some(&alice.token),
            Some(json!({"deleted": true})),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = call(
        &env.state,
        req("POST", &uri, Some(&alice.token), Some(fresh)),
    )
    .await;
    assert!(s == StatusCode::CONFLICT || s == StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn registration_login_and_admin_authorization() {
    let Some(env) = env().await else { return };
    let (s, status) = call(&env.state, req("GET", "/api/v1/setup/status", None, None)).await;
    assert_eq!(s, StatusCode::OK, "{status}");
    assert_eq!(status["setup_required"], true);

    let first = register(&env.state, "admin@example.com").await;
    let second = register(&env.state, "user@example.com").await;

    let (_, status) = call(&env.state, req("GET", "/api/v1/setup/status", None, None)).await;
    assert_eq!(status["setup_required"], false);

    // The first-run flow mints a dashboard token for the administrator.
    let (s, body) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/tokens",
            Some(&first.token),
            Some(json!({ "label": "admin-dashboard" })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::CREATED, "{body}");
    let dashboard_token = body["token"].as_str().unwrap();
    let (s, _) = call(
        &env.state,
        req("GET", "/api/v1/admin/stats", Some(dashboard_token), None),
    )
    .await;
    assert_eq!(s, StatusCode::OK);

    // Admin-only restart trigger. In the test runtime nothing listens for the
    // shutdown notification, so this only verifies routing and authorization.
    let (s, body) = call(
        &env.state,
        req("POST", "/api/v1/admin/restart", Some(&first.token), None),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert_eq!(body["status"], "restarting");
    let (s, _) = call(
        &env.state,
        req("POST", "/api/v1/admin/restart", Some(&second.token), None),
    )
    .await;
    assert_eq!(s, StatusCode::FORBIDDEN);

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

    // Rename mutates only the encrypted namespace, not content or history.
    let renamed = base64_key(b"different-opaque-sealed-name");
    for target in [file_id, Uuid::new_v4()] {
        let (status, body) = call(
            &env.state,
            req(
                "PATCH",
                &format!("/api/v1/files/{target}"),
                Some(&bob.token),
                Some(json!({"name_enc": renamed})),
            ),
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    }
    let (status, body) = call(
        &env.state,
        req(
            "POST",
            &format!("/api/v1/files/{file_id}/rename"),
            Some(&alice.token),
            Some(json!({"name_enc": renamed, "parent_id": null,
                "siblings": [{"id": file_id, "name_enc": base64_key(b"opaque-sealed-name")}]})),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let (status, body) = call(
        &env.state,
        req("GET", "/api/v1/files", Some(&alice.token), None),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let entry = body["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["id"] == file_id.to_string())
        .unwrap();
    assert_eq!(entry["name_enc"], renamed);
    assert_eq!(entry["current_version"], manifest.revision_id.to_string());
    assert_eq!(entry["size"], manifest.size);
    let retained: Vec<u8> = sqlx::query_scalar(
        "SELECT manifest FROM file_versions WHERE account_id = $1 AND file_id = $2 AND revision_id = $3",
    )
    .bind(alice.account_id)
    .bind(file_id)
    .bind(manifest.revision_id)
    .fetch_one(&env.state.pool)
    .await
    .unwrap();
    assert_eq!(retained, sealed);

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

    // Admin user listing must not panic when an account actually has chunks
    // (PostgreSQL SUM(bigint) is numeric; the query must cast it).
    let (s, body) = call(
        &env.state,
        req("GET", "/api/v1/admin/users", Some(&alice.token), None),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(body["users"].as_array().unwrap().iter().any(|u| {
        u["id"] == alice.account_id.to_string() && u["used_bytes"].as_i64().unwrap_or(0) > 0
    }));

    // Independently verify recent articles against the retrieval provider.
    let (s, body) = call(
        &env.state,
        req(
            "GET",
            "/api/v1/admin/articles/verify",
            Some(&alice.token),
            None,
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(body["total"].as_u64().unwrap_or(0) > 0);
    assert_eq!(body["available"], body["total"], "{body}");
}

#[tokio::test]
async fn admins_can_edit_users_and_providers_in_place() {
    let Some(env) = env().await else { return };
    let admin = register(&env.state, "admin@example.com").await;
    let member = register(&env.state, "member@example.com").await;

    let user_path = format!("/api/v1/admin/users/{}", member.account_id);
    let (s, body) = call(
        &env.state,
        req(
            "PATCH",
            &user_path,
            Some(&admin.token),
            Some(json!({
                "display_name": "Member One",
                "quota_bytes": 5 * 1024 * 1024,
                "is_admin": true
            })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");

    let (_, body) = call(
        &env.state,
        req("GET", "/api/v1/admin/users", Some(&admin.token), None),
    )
    .await;
    let listed = body["users"]
        .as_array()
        .unwrap()
        .iter()
        .find(|u| u["id"] == member.account_id.to_string())
        .unwrap();
    assert_eq!(listed["display_name"], "Member One");
    assert_eq!(listed["quota_bytes"], 5 * 1024 * 1024);
    assert_eq!(listed["is_admin"], true);

    // Clearing the quota restores unlimited storage.
    let (s, _) = call(
        &env.state,
        req(
            "PATCH",
            &user_path,
            Some(&admin.token),
            Some(json!({ "unlimited_quota": true })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let (_, body) = call(
        &env.state,
        req("GET", "/api/v1/admin/users", Some(&admin.token), None),
    )
    .await;
    let listed = body["users"]
        .as_array()
        .unwrap()
        .iter()
        .find(|u| u["id"] == member.account_id.to_string())
        .unwrap();
    assert!(listed["quota_bytes"].is_null());

    // An administrator cannot remove their own admin role.
    let (s, _) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/admin/users/{}", admin.account_id),
            Some(&admin.token),
            Some(json!({ "is_admin": false })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);

    // Create a provider with credentials, then edit it without resending the
    // password.
    let (s, body) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/admin/providers",
            Some(&admin.token),
            Some(json!({
                "name": "test-provider",
                "host": "news.example.com",
                "port": 563,
                "username": "alice",
                "password": "secret",
                "role": "both",
                "groups": ["alt.binaries.nntdrive"]
            })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::CREATED, "{body}");
    let provider_id = body["id"].as_str().unwrap().to_string();

    let (s, body) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/admin/providers/{provider_id}"),
            Some(&admin.token),
            Some(json!({
                "host": "news2.example.com",
                "role": "retrieval_only",
                "priority": 5,
                "username": "alice"
            })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert_eq!(body["restart_required"], true);

    let (_, body) = call(
        &env.state,
        req("GET", "/api/v1/admin/providers", Some(&admin.token), None),
    )
    .await;
    let listed = body["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == provider_id)
        .unwrap();
    assert_eq!(listed["host"], "news2.example.com");
    assert_eq!(listed["role"], "retrieval_only");
    assert_eq!(listed["priority"], 5);
    assert_eq!(listed["username"], "alice");

    // Invalid edits are rejected, and deletion still works.
    let (s, _) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/admin/providers/{provider_id}"),
            Some(&admin.token),
            Some(json!({ "groups": [] })),
        ),
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (s, _) = call(
        &env.state,
        req(
            "DELETE",
            &format!("/api/v1/admin/providers/{provider_id}"),
            Some(&admin.token),
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
