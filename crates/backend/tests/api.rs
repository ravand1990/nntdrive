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
async fn orphan_gc_api_is_opt_in_and_reports_batch_results() {
    let Some(env) = env().await else { return };
    let admin = register(&env.state, "gc-admin@example.test").await;
    let user = register(&env.state, "gc-user@example.test").await;
    let file = env._db.create_file(user.account_id, None, vec![1]).await;
    let revision = Uuid::new_v4();
    let manifest = nntdrive_storage::FileManifest::new(file, revision, 0, String::new());
    let sealed = user
        .master
        .seal_manifest(file, revision, &manifest.to_bytes())
        .unwrap()
        .to_bytes();
    let version_path = format!("/api/v1/files/{file}/versions");
    let (status, _) = call(
        &env.state,
        req(
            "POST",
            &version_path,
            Some(&user.token),
            Some(json!({"revision_id":revision,"size":0,"sealed_manifest":base64_key(&sealed)})),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let chunk_id = Uuid::new_v4();
    sqlx::query("INSERT INTO chunks(id,account_id,plaintext_hash,plaintext_len,ciphertext_len,created_at) VALUES($1,$2,$3,1,42,now()-interval '10 days')")
        .bind(chunk_id).bind(user.account_id).bind(vec![3u8;32]).execute(&env.state.pool).await.unwrap();
    let payload =
        json!({"account_id":user.account_id,"grace_days":7,"require_reference_commits":true});
    let path = "/api/v1/admin/jobs";
    for token in [None, Some(user.token.as_str())] {
        let (s, _) = call(
            &env.state,
            req(
                "POST",
                path,
                token,
                Some(json!({"kind":"orphan_gc","payload":payload})),
            ),
        )
        .await;
        assert!(s == StatusCode::UNAUTHORIZED || s == StatusCode::FORBIDDEN);
    }
    for p in [
        json!({}),
        json!({"account_id":user.account_id,"grace_days":0,"require_reference_commits":true}),
        json!({"account_id":user.account_id,"grace_days":7}),
    ] {
        let (s, _) = call(
            &env.state,
            req(
                "POST",
                path,
                Some(&admin.token),
                Some(json!({"kind":"orphan_gc","payload":p})),
            ),
        )
        .await;
        assert_eq!(s, StatusCode::BAD_REQUEST);
    }
    for backfilled in [false, true] {
        if backfilled {
            let backfill_path = format!("{version_path}/{revision}/references");
            let (s, _) = call(
                &env.state,
                req(
                    "PUT",
                    &backfill_path,
                    Some(&admin.token),
                    Some(json!({"chunk_ids":[]})),
                ),
            )
            .await;
            assert_eq!(s, StatusCode::NOT_FOUND);
            let (s, _) = call(
                &env.state,
                req(
                    "PUT",
                    &backfill_path,
                    Some(&user.token),
                    Some(json!({"chunk_ids":[]})),
                ),
            )
            .await;
            assert_eq!(s, StatusCode::OK);
        }
        let (s, queued) = call(
            &env.state,
            req(
                "POST",
                path,
                Some(&admin.token),
                Some(json!({"kind":"orphan_gc","payload":payload})),
            ),
        )
        .await;
        assert_eq!(s, StatusCode::CREATED);
        let job_id = queued["job_id"].as_str().unwrap().to_owned();
        let worker = tokio::spawn(nntdrive_backend::jobs::worker_loop(
            Arc::new(env.state.clone()),
            "gc-api-test".into(),
        ));
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                let (_, listing) =
                    call(&env.state, req("GET", path, Some(&admin.token), None)).await;
                let row = listing["jobs"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|r| r["id"] == job_id)
                    .unwrap();
                if row["state"] == "done" {
                    assert_eq!(
                        row["result"]["deleted_chunks"],
                        if backfilled { 1 } else { 0 }
                    );
                    if !backfilled {
                        assert_eq!(row["result"]["blocked"], "incomplete_version_references");
                    }
                    break;
                }
                assert_ne!(row["state"], "failed");
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap();
        worker.abort();
        let _ = worker.await;
    }
    assert!(env
        .state
        .store
        .load_chunk(user.account_id, chunk_id)
        .await
        .is_err());
    let mut body =
        json!({"revision_id":Uuid::new_v4(),"size":0,"sealed_manifest":base64_key(&sealed)});
    let (s, _) = call(
        &env.state,
        req("POST", &version_path, Some(&user.token), Some(body.clone())),
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    body["chunk_ids"] = json!([]);
    let (s, _) = call(
        &env.state,
        req("POST", &version_path, Some(&user.token), Some(body)),
    )
    .await;
    assert_eq!(s, StatusCode::CREATED);
}

#[tokio::test]
async fn maintenance_policy_and_results_survive_state_recreation() {
    let Some(env) = env().await else { return };
    let admin = register(&env.state, "maintenance-admin@example.com").await;
    let user = register(&env.state, "maintenance-user@example.com").await;
    let path = "/api/v1/admin/retention";
    for token in [None, Some(user.token.as_str())] {
        for method in ["GET", "PUT"] {
            let (status, _) = call(
                &env.state,
                req(method, path, token, Some(json!({"refresh_days": 7}))),
            )
            .await;
            assert!(status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN);
        }
    }
    let (_, initial) = call(&env.state, req("GET", path, Some(&admin.token), None)).await;
    assert_eq!(initial["refresh_days"], 30);
    for days in [0, 36501] {
        let (status, _) = call(
            &env.state,
            req(
                "PUT",
                path,
                Some(&admin.token),
                Some(json!({"refresh_days": days})),
            ),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    let (status, _) = call(
        &env.state,
        req(
            "PUT",
            path,
            Some(&admin.token),
            Some(json!({"refresh_days": 7})),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let recreated = AppState::new(
        env.state.pool.clone(),
        env.state.storage.nntp(),
        (*env.state.config).clone(),
    )
    .unwrap();
    let (_, saved) = call(&recreated, req("GET", path, Some(&admin.token), None)).await;
    assert_eq!(saved["refresh_days"], 7);
    for kind in ["health_sweep", "refresh_sweep", "repair_stripe"] {
        let (_, queued) = call(
            &recreated,
            req(
                "POST",
                "/api/v1/admin/jobs",
                Some(&admin.token),
                Some(json!({"kind":kind,"payload":{}})),
            ),
        )
        .await;
        let id: Uuid = queued["job_id"].as_str().unwrap().parse().unwrap();
        // Invalid repair input must persist a sanitized failure rather than an invented success.
        if kind == "repair_stripe" {
            sqlx::query("UPDATE jobs SET max_attempts = 1 WHERE id = $1")
                .bind(id)
                .execute(&recreated.pool)
                .await
                .unwrap();
        }
        let worker = tokio::spawn(nntdrive_backend::jobs::worker_loop(
            Arc::new(recreated.clone()),
            "test-maintenance".into(),
        ));
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            loop {
                let (_, listing) = call(
                    &recreated,
                    req("GET", "/api/v1/admin/jobs", Some(&admin.token), None),
                )
                .await;
                let row = listing["jobs"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|r| r["id"] == id.to_string())
                    .unwrap();
                if row["state"] == "done" || row["state"] == "failed" {
                    if kind == "repair_stripe" {
                        assert_eq!(row["state"], "failed");
                        assert_eq!(
                            row["last_error"],
                            "maintenance failed; retry or inspect backend diagnostics"
                        );
                        assert!(row["result"].is_null());
                    } else {
                        assert_eq!(row["state"], "done");
                        assert_eq!(row["result"]["checked"], 0);
                        assert_eq!(row["result"]["continued"], false);
                        if kind == "refresh_sweep" {
                            assert_eq!(row["result"]["refresh_days"], 7);
                        }
                    }
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap();
        worker.abort();
        let _ = worker.await;
    }
    let recreated_again = AppState::new(
        env.state.pool.clone(),
        env.state.storage.nntp(),
        (*env.state.config).clone(),
    )
    .unwrap();
    let (_, listing) = call(
        &recreated_again,
        req("GET", "/api/v1/admin/jobs", Some(&admin.token), None),
    )
    .await;
    assert_eq!(listing["jobs"].as_array().unwrap().len(), 3);
    assert_eq!(
        listing["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["result"].is_object())
            .count(),
        2
    );
}

#[tokio::test]
async fn retention_worker_reposts_old_shards_and_records_loss() {
    let Some(env) = env().await else { return };
    let admin = register(&env.state, "refresh-admin@example.com").await;
    let data = b"retention regression ciphertext".to_vec();
    let prepared = nntdrive_storage::prepare_chunk(
        &admin.master,
        &nntdrive_storage::Chunk {
            index: 0,
            offset: 0,
            hash: *blake3::hash(&data).as_bytes(),
            data,
        },
        3,
    )
    .unwrap();
    env.state
        .storage
        .publish_prepared(admin.account_id, &prepared)
        .await
        .unwrap();
    let (status, _) = call(
        &env.state,
        req(
            "PUT",
            "/api/v1/admin/retention",
            Some(&admin.token),
            Some(json!({"refresh_days": 7})),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    for lost in [false, true] {
        sqlx::query("UPDATE shards SET posted_at = now() - interval '8 days'")
            .execute(&env.state.pool)
            .await
            .unwrap();
        if lost {
            env.state
                .storage
                .replace_nntp(Arc::new(NntpPool::new(vec![]).unwrap()));
        }
        let id =
            nntdrive_backend::jobs::enqueue(&env.state.pool, "refresh_sweep", None, json!({}), 0)
                .await
                .unwrap();
        let worker = tokio::spawn(nntdrive_backend::jobs::worker_loop(
            Arc::new(env.state.clone()),
            "refresh-test".into(),
        ));
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            loop {
                let result: Option<Value> =
                    sqlx::query_scalar("SELECT result FROM jobs WHERE id = $1")
                        .bind(id)
                        .fetch_one(&env.state.pool)
                        .await
                        .unwrap();
                if let Some(result) = result {
                    assert_eq!(result["checked"], 1);
                    assert_eq!(result["refresh_days"], 7);
                    assert_eq!(result["refreshed"], if lost { 0 } else { 1 });
                    assert_eq!(result["failed"], if lost { 1 } else { 0 });
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap();
        worker.abort();
        let _ = worker.await;
        if !lost {
            let recent: bool = sqlx::query_scalar(
                "SELECT bool_and(posted_at > now() - interval '1 day') FROM shards",
            )
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
            assert!(recent);
        }
    }
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
    assert_eq!(body["restart_required"], false);

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

#[tokio::test]
async fn provider_reload_transfers_and_fails_closed() {
    let Some(env) = env().await else { return };
    let admin = register(&env.state, "reload-admin@example.com").await;
    let member = register(&env.state, "reload-member@example.com").await;
    let server = MockNntpServer::start(MockConfig::default()).await;
    let cfg = server.client_config();
    let input = json!({"name":"live", "host":cfg.host, "port":cfg.port,
        "tls":false, "groups":cfg.groups, "username":cfg.username, "password":cfg.password});
    let (status, _) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/admin/providers",
            Some(&member.token),
            Some(input.clone()),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, body) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/admin/providers",
            Some(&admin.token),
            Some(input),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["applied"], true);
    let path = format!("/api/v1/admin/providers/{}", body["id"].as_str().unwrap());
    let old = env.state.storage.nntp();
    let article = nntdrive_nntp::Article::new(
        cfg.groups.clone(),
        "opaque".into(),
        nntdrive_nntp::yenc_encode("reload@invalid", b"ciphertext"),
        "reload@invalid".into(),
    );
    assert_eq!(old.post(&article).await.unwrap(), "live");
    assert_eq!(old.fetch("reload@invalid").await.unwrap(), b"ciphertext");
    let data = b"encrypted-reload-first".to_vec();
    let prepared = nntdrive_storage::prepare_chunk(
        &admin.master,
        &nntdrive_storage::Chunk {
            index: 0,
            offset: 0,
            hash: *blake3::hash(&data).as_bytes(),
            data,
        },
        3,
    )
    .unwrap();
    let (entry, _) = env
        .state
        .storage
        .publish_prepared(admin.account_id, &prepared)
        .await
        .unwrap();
    assert!(!entry.stripes.is_empty());
    assert!(env._server.store.article_ids().await.is_empty());

    for invalid in [
        json!({"port":0}),
        json!({"max_connections":201}),
        json!({"groups":["bad\r\ngroup"]}),
    ] {
        let (status, _) = call(
            &env.state,
            req("PATCH", &path, Some(&admin.token), Some(invalid)),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(Arc::ptr_eq(&old, &env.state.storage.nntp()));
    }
    let second = MockNntpServer::start(MockConfig::default()).await;
    let cfg2 = second.client_config();
    let (status, _) = call(
        &env.state,
        req(
            "PATCH",
            &path,
            Some(&admin.token),
            Some(json!({"host":cfg2.host,"port":cfg2.port})),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let new = env.state.storage.nntp();
    assert!(!Arc::ptr_eq(&old, &new));
    new.post(&article).await.unwrap();
    assert_eq!(new.fetch("reload@invalid").await.unwrap(), b"ciphertext");
    let data = b"encrypted-reload-second".to_vec();
    let prepared = nntdrive_storage::prepare_chunk(
        &admin.master,
        &nntdrive_storage::Chunk {
            index: 0,
            offset: 0,
            hash: *blake3::hash(&data).as_bytes(),
            data,
        },
        3,
    )
    .unwrap();
    let (entry, _) = env
        .state
        .storage
        .publish_prepared(admin.account_id, &prepared)
        .await
        .unwrap();
    assert!(!entry.stripes.is_empty());
    // Old snapshots remain usable, even after replacement/disable.
    assert_eq!(old.fetch("reload@invalid").await.unwrap(), b"ciphertext");
    let (status, _) = call(
        &env.state,
        req(
            "PATCH",
            &path,
            Some(&admin.token),
            Some(json!({"enabled":false})),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(env.state.storage.nntp().providers().is_empty());
    assert!(
        nntdrive_backend::load_providers(&env.state.pool, &env.state.config.secret_key)
            .await
            .unwrap()
            .providers()
            .is_empty()
    );
    let (status, _) = call(&env.state, req("DELETE", &path, Some(&admin.token), None)).await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        nntdrive_backend::load_providers(&env.state.pool, &env.state.config.secret_key)
            .await
            .unwrap()
            .providers()
            .is_empty()
    );
}

#[tokio::test]
async fn corrupt_provider_credentials_do_not_replace_pool() {
    let Some(env) = env().await else { return };
    let admin = register(&env.state, "corrupt-admin@example.com").await;
    let cfg = env._server.client_config();
    let (_, body) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/admin/providers",
            Some(&admin.token),
            Some(json!({
                "name":"sealed", "host":cfg.host,"port":cfg.port,"tls":false,
                "username":"user", "password":"do-not-disclose"
            })),
        ),
    )
    .await;
    let id = Uuid::parse_str(body["id"].as_str().unwrap()).unwrap();
    let old = env.state.storage.nntp();
    sqlx::query("UPDATE providers SET password_enc = $1 WHERE id = $2")
        .bind(vec![0u8; 42])
        .bind(id)
        .execute(&env.state.pool)
        .await
        .unwrap();
    assert!(
        nntdrive_backend::load_providers(&env.state.pool, &env.state.config.secret_key)
            .await
            .is_err()
    );
    let (status, body) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/admin/providers/{id}"),
            Some(&admin.token),
            Some(json!({"name":"changed"})),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(!body.to_string().contains("do-not-disclose"));
    assert!(Arc::ptr_eq(&old, &env.state.storage.nntp()));
    let name: String = sqlx::query_scalar("SELECT name FROM providers WHERE id = $1")
        .bind(id)
        .fetch_one(&env.state.pool)
        .await
        .unwrap();
    assert_eq!(name, "sealed");
}

#[tokio::test]
async fn in_flight_storage_upload_keeps_one_provider_snapshot() {
    use tokio::io::AsyncWriteExt;
    let Some(env) = env().await else { return };
    let admin = register(&env.state, "snapshot@example.com").await;
    let ctx = nntdrive_storage::Context::new(admin.account_id, admin.master);
    let second = MockNntpServer::start(MockConfig::default()).await;
    let (mut writer, reader) = tokio::io::duplex(1024);
    let upload = env
        .state
        .storage
        .upload(&ctx, Uuid::new_v4(), Uuid::new_v4(), reader);
    tokio::pin!(upload);
    // Poll through operation admission, then block awaiting input.
    tokio::select! {
        result = &mut upload => panic!("upload completed before input: {:?}", result.err()),
        _ = tokio::time::sleep(std::time::Duration::from_millis(20)) => {}
    }
    env.state.storage.replace_nntp(Arc::new(
        NntpPool::new(vec![second.client_config()]).unwrap(),
    ));
    writer
        .write_all(b"first snapshot ciphertext source")
        .await
        .unwrap();
    writer.shutdown().await.unwrap();
    upload.await.unwrap();
    assert!(env._server.store.article_count().await > 0);
    assert_eq!(second.store.article_count().await, 0);
    env.state
        .storage
        .upload(
            &ctx,
            Uuid::new_v4(),
            Uuid::new_v4(),
            &b"different subsequent content"[..],
        )
        .await
        .unwrap();
    assert!(second.store.article_count().await > 0);
}
