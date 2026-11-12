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

// These tests poll the real response body before invalidation: opening a fresh
// request after revocation alone cannot detect a stale live-stream credential.
async fn sse_change(body: &mut Body) -> Value {
    tokio::time::timeout(std::time::Duration::from_secs(6), async {
        loop {
            let frame = body
                .frame()
                .await
                .expect("stream ended before change")
                .unwrap();
            if let Ok(bytes) = frame.into_data() {
                let text = std::str::from_utf8(&bytes).unwrap();
                if text.contains("event: change") {
                    let data = text
                        .lines()
                        .find_map(|line| line.strip_prefix("data: "))
                        .unwrap();
                    return serde_json::from_str(data).unwrap();
                }
            }
        }
    })
    .await
    .expect("stream did not produce a change")
}

async fn sse_fixture_event(state: &AppState, account_id: Uuid, seq: i64) {
    sqlx::query(
        "INSERT INTO sync_events (account_id, seq, kind, payload) VALUES ($1, $2, 'test', '{}')",
    )
    .bind(account_id)
    .bind(seq)
    .execute(&state.pool)
    .await
    .unwrap();
}

#[derive(Clone, Copy)]
enum SseInvalidation {
    Logout,
    TokenRevoke,
    TokenReplacement,
    DeviceRevoke,
    Disable,
    Expiry,
}

async fn sse_invalidation(case: SseInvalidation) {
    // Unlike ordinary optional local integration tests, these security regressions
    // fail closed if their disposable PostgreSQL prerequisite is unavailable.
    let env = env()
        .await
        .expect("SSE regressions require isolated PostgreSQL");
    let account = register(&env.state, "sse@example.com").await;
    // An independent backend state has no shared in-memory cancellation channel.
    let other = AppState::new(
        env.state.pool.clone(),
        Arc::new(NntpPool::new(vec![env._server.client_config()]).unwrap()),
        (*env.state.config).clone(),
    )
    .unwrap();
    let (status, extra) = call(
        &other,
        req(
            "POST",
            "/api/v1/tokens",
            Some(&account.token),
            Some(json!({"label": "still-valid"})),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let other_token = extra["token"].as_str().unwrap();
    sse_fixture_event(&other, account.account_id, 1).await;
    let response = app(env.state.clone())
        .oneshot(req(
            "GET",
            "/api/v1/events/stream",
            Some(&account.token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let mut body = response.into_body();
    assert_eq!(sse_change(&mut body).await["seq"], 1);

    match case {
        SseInvalidation::Logout => {
            assert_eq!(
                call(
                    &other,
                    req("POST", "/api/v1/auth/logout", Some(&account.token), None)
                )
                .await
                .0,
                StatusCode::OK
            );
        }
        SseInvalidation::DeviceRevoke => {
            assert_eq!(
                call(
                    &other,
                    req(
                        "DELETE",
                        &format!("/api/v1/devices/{}", account.device_id),
                        Some(&account.token),
                        None
                    )
                )
                .await
                .0,
                StatusCode::OK
            );
        }
        SseInvalidation::TokenRevoke => {
            sqlx::query(
                "UPDATE api_tokens SET revoked_at = now() WHERE token_hash = decode($1, 'hex')",
            )
            .bind(nntdrive_backend::auth::token_hash_hex(&account.token))
            .execute(&other.pool)
            .await
            .unwrap();
        }
        SseInvalidation::TokenReplacement => {
            // Even replacing the digest on the same row must not transfer the
            // original stream's authority to a different bearer credential.
            sqlx::query("UPDATE api_tokens SET token_hash = decode($1, 'hex') WHERE token_hash = decode($2, 'hex')")
                .bind(nntdrive_backend::auth::token_hash_hex("replacement-test-credential-not-issued"))
                .bind(nntdrive_backend::auth::token_hash_hex(&account.token))
                .execute(&other.pool).await.unwrap();
        }
        SseInvalidation::Disable => {
            // Check the account flag independently of token revocation (including
            // the admin handler's gap between its two updates).
            sqlx::query("UPDATE accounts SET disabled = true WHERE id = $1")
                .bind(account.account_id)
                .execute(&other.pool)
                .await
                .unwrap();
        }
        SseInvalidation::Expiry => {
            sqlx::query("UPDATE api_tokens SET expires_at = now() + interval '250 milliseconds' WHERE token_hash = decode($1, 'hex')")
                .bind(nntdrive_backend::auth::token_hash_hex(&account.token)).execute(&other.pool).await.unwrap();
            tokio::time::sleep(std::time::Duration::from_millis(350)).await;
        }
    }
    // New requests must fail as well, but this is not the live-body assertion.
    assert_eq!(
        call(
            &other,
            req("GET", "/api/v1/events/stream", Some(&account.token), None)
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    if matches!(
        case,
        SseInvalidation::Logout | SseInvalidation::TokenRevoke | SseInvalidation::Expiry
    ) {
        // A valid replacement token must not revive the originally opened stream.
        assert_eq!(
            call(&other, req("GET", "/api/v1/me", Some(other_token), None))
                .await
                .0,
            StatusCode::OK
        );
    }
    // No batch containing this event could have been admitted before invalidation.
    sse_fixture_event(&other, account.account_id, 2).await;
    tokio::time::timeout(std::time::Duration::from_secs(6), async {
        while let Some(frame) = body.frame().await {
            let frame = frame.unwrap();
            if let Ok(bytes) = frame.into_data() {
                assert!(
                    !std::str::from_utf8(&bytes)
                        .unwrap()
                        .contains("event: change"),
                    "already-open SSE emitted a change after credential invalidation"
                );
            }
        }
    })
    .await
    .expect("invalidated SSE did not close within polling bound plus test slack");
}

#[tokio::test]
async fn sse_live_logout() {
    sse_invalidation(SseInvalidation::Logout).await;
}
#[tokio::test]
async fn sse_live_token_revoke() {
    sse_invalidation(SseInvalidation::TokenRevoke).await;
}
#[tokio::test]
async fn sse_live_device_revoke() {
    sse_invalidation(SseInvalidation::DeviceRevoke).await;
}
#[tokio::test]
async fn sse_live_account_disable() {
    sse_invalidation(SseInvalidation::Disable).await;
}
#[tokio::test]
async fn sse_live_expiry() {
    sse_invalidation(SseInvalidation::Expiry).await;
}

#[tokio::test]
async fn sse_live_token_replacement() {
    sse_invalidation(SseInvalidation::TokenReplacement).await;
}

#[tokio::test]
async fn sse_live_backpressured_batch_rechecks_before_resuming() {
    let env = env()
        .await
        .expect("SSE regressions require isolated PostgreSQL");
    let account = register(&env.state, "sse-paused@example.com").await;
    sse_fixture_event(&env.state, account.account_id, 1).await;
    sse_fixture_event(&env.state, account.account_id, 2).await;
    let response = app(env.state.clone())
        .oneshot(req(
            "GET",
            "/api/v1/events/stream",
            Some(&account.token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let mut body = response.into_body();
    assert_eq!(sse_change(&mut body).await["seq"], 1);
    assert_eq!(
        call(
            &env.state,
            req("POST", "/api/v1/auth/logout", Some(&account.token), None)
        )
        .await
        .0,
        StatusCode::OK
    );
    // Leave the second already-fetched event suspended beyond the auth lease.
    tokio::time::sleep(std::time::Duration::from_millis(2100)).await;
    let next = tokio::time::timeout(std::time::Duration::from_secs(3), body.frame())
        .await
        .expect("resumed invalidated SSE did not close");
    assert!(
        next.is_none(),
        "resumed SSE drained an expired authorized batch"
    );
}

#[tokio::test]
async fn sse_live_database_deadline_fails_closed() {
    let env = env()
        .await
        .expect("SSE regressions require isolated PostgreSQL");
    let account = register(&env.state, "sse-deadline@example.com").await;
    sse_fixture_event(&env.state, account.account_id, 1).await;
    let response = app(env.state.clone())
        .oneshot(req(
            "GET",
            "/api/v1/events/stream",
            Some(&account.token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let mut body = response.into_body();
    assert_eq!(sse_change(&mut body).await["seq"], 1);
    // Real PostgreSQL lock stalls the next auth SELECT without stopping the DB
    // or touching anything outside this test's isolated schema.
    let mut blocker = env.state.pool.begin().await.unwrap();
    sqlx::query("LOCK TABLE api_tokens IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *blocker)
        .await
        .unwrap();
    let next = tokio::time::timeout(std::time::Duration::from_secs(6), body.frame())
        .await
        .expect("blocked authorization did not close SSE by its deadline");
    assert!(
        next.is_none(),
        "failed authorization exposed a frame or diagnostics"
    );
    blocker.rollback().await.unwrap();
}

#[tokio::test]
async fn sse_live_valid_token_stays_tenant_scoped() {
    let env = env()
        .await
        .expect("SSE regressions require isolated PostgreSQL");
    let alice = register(&env.state, "sse-alice@example.com").await;
    let bob = register(&env.state, "sse-bob@example.com").await;
    // Exercise the supported NULL expiry and device-less token cases, too.
    sqlx::query("UPDATE api_tokens SET expires_at = NULL, device_id = NULL WHERE account_id = $1")
        .bind(alice.account_id)
        .execute(&env.state.pool)
        .await
        .unwrap();
    sse_fixture_event(&env.state, alice.account_id, 1).await;
    sse_fixture_event(&env.state, bob.account_id, 100).await;
    let response = app(env.state.clone())
        .oneshot(req(
            "GET",
            "/api/v1/events/stream",
            Some(&alice.token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let mut body = response.into_body();
    assert_eq!(sse_change(&mut body).await["seq"], 1);
    sse_fixture_event(&env.state, alice.account_id, 2).await;
    assert_eq!(sse_change(&mut body).await["seq"], 2);
}

fn base64_key(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[tokio::test]
async fn guarded_move_preserves_subtree_and_rejects_stale_or_foreign_inputs() {
    let Some(env) = env().await else { return };
    let alice = register(&env.state, "move-alice@example.com").await;
    let bob = register(&env.state, "move-bob@example.com").await;
    let source = Uuid::new_v4();
    let destination = Uuid::new_v4();
    let child = Uuid::new_v4();
    for (id, parent, is_dir) in [
        (source, None, true),
        (destination, None, true),
        (child, Some(source), false),
    ] {
        assert_eq!(call(&env.state, req("POST", "/api/v1/files", Some(&alice.token), Some(json!({
            "id": id, "parent_id": parent, "is_dir": is_dir, "name_enc": base64_key(id.as_bytes())
        })))).await.0, StatusCode::CREATED);
    }
    let uri = format!("/api/v1/files/{source}/move-checked");
    let body = json!({"parent_id": destination, "source_parent_id": null,
        "source_name_enc": base64_key(source.as_bytes()), "siblings": []});
    for token in [&bob.token] {
        assert_eq!(
            call(
                &env.state,
                req("POST", &uri, Some(token), Some(body.clone()))
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
    }
    let mut stale = body.clone();
    stale["source_name_enc"] = json!(base64_key(b"stale"));
    assert_eq!(
        call(
            &env.state,
            req("POST", &uri, Some(&alice.token), Some(stale))
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let mut cycle = body.clone();
    cycle["parent_id"] = json!(source);
    cycle["siblings"] = json!([{"id": child, "name_enc": base64_key(child.as_bytes())}]);
    assert_eq!(
        call(
            &env.state,
            req("POST", &uri, Some(&alice.token), Some(cycle))
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    let mut foreign = body.clone();
    foreign["parent_id"] = json!(Uuid::new_v4());
    assert_eq!(
        call(
            &env.state,
            req("POST", &uri, Some(&alice.token), Some(foreign))
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let nested = Uuid::new_v4();
    assert_eq!(call(&env.state, req("POST", "/api/v1/files", Some(&alice.token), Some(json!({
        "id": nested, "parent_id": source, "is_dir": true, "name_enc": base64_key(b"nested")
    })))).await.0, StatusCode::CREATED);
    let mut descendant = body.clone();
    descendant["parent_id"] = json!(nested);
    assert_eq!(
        call(
            &env.state,
            req("POST", &uri, Some(&alice.token), Some(descendant))
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    let foreign_folder = Uuid::new_v4();
    assert_eq!(
        call(
            &env.state,
            req(
                "POST",
                "/api/v1/files",
                Some(&bob.token),
                Some(json!({
                    "id": foreign_folder, "is_dir": true, "name_enc": base64_key(b"foreign")
                }))
            )
        )
        .await
        .0,
        StatusCode::CREATED
    );
    for target in [foreign_folder, Uuid::new_v4()] {
        let mut invalid = body.clone();
        invalid["parent_id"] = json!(target);
        assert_eq!(
            call(
                &env.state,
                req("POST", &uri, Some(&alice.token), Some(invalid))
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
    }
    let mut oversized = body.clone();
    oversized["siblings"] = json!(vec![
        json!({"id": child, "name_enc": base64_key(b"opaque")});
        4097
    ]);
    assert_eq!(
        call(
            &env.state,
            req("POST", &uri, Some(&alice.token), Some(oversized))
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    // Membership changes invalidate the destination snapshot, even though the
    // backend cannot compare plaintext names itself.
    let added = Uuid::new_v4();
    assert_eq!(
        call(
            &env.state,
            req(
                "POST",
                "/api/v1/files",
                Some(&alice.token),
                Some(json!({
                    "id": added, "parent_id": destination, "name_enc": base64_key(b"opaque")
                }))
            )
        )
        .await
        .0,
        StatusCode::CREATED
    );
    assert_eq!(
        call(
            &env.state,
            req("POST", &uri, Some(&alice.token), Some(body.clone()))
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let mut valid = body.clone();
    valid["siblings"] = json!([{"id": added, "name_enc": base64_key(b"opaque")}]);
    // The guard must wait for the same account namespace lock as legacy writers.
    let mut owner = env.state.pool.begin().await.unwrap();
    sqlx::query("SELECT id FROM accounts WHERE id = $1 FOR UPDATE")
        .bind(alice.account_id)
        .fetch_one(&mut *owner)
        .await
        .unwrap();
    let state = env.state.clone();
    let token = alice.token.clone();
    let blocked_uri = uri.clone();
    let blocked_body = valid.clone();
    let mut blocked = tokio::spawn(async move {
        call(
            &state,
            req("POST", &blocked_uri, Some(&token), Some(blocked_body)),
        )
        .await
    });
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(100), &mut blocked)
            .await
            .is_err()
    );
    owner.rollback().await.unwrap();
    assert_eq!(blocked.await.unwrap().0, StatusCode::OK);
    assert_eq!(
        call(
            &env.state,
            req("POST", &uri, Some(&alice.token), Some(valid))
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let parent: Option<Uuid> =
        sqlx::query_scalar("SELECT parent_id FROM files WHERE account_id = $1 AND id = $2")
            .bind(alice.account_id)
            .bind(child)
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
    assert_eq!(parent, Some(source));
    let name: Vec<u8> =
        sqlx::query_scalar("SELECT name_enc FROM files WHERE account_id = $1 AND id = $2")
            .bind(alice.account_id)
            .bind(source)
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
    assert_eq!(name, source.as_bytes());
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

// Fixed account roots (#95): one Global space and one root per device.
fn sealed(name: &str) -> String {
    base64_key(name.as_bytes())
}

async fn bootstrap_root(
    state: &AppState,
    token: &str,
    kind: &str,
    name: &str,
) -> (StatusCode, Value) {
    let node_id = Uuid::new_v4();
    bootstrap_root_at(state, token, kind, node_id, &sealed(name)).await
}

async fn bootstrap_root_at(
    state: &AppState,
    token: &str,
    kind: &str,
    node_id: Uuid,
    name_enc: &str,
) -> (StatusCode, Value) {
    call(
        state,
        req(
            "POST",
            "/api/v1/roots",
            Some(token),
            Some(json!({ "kind": kind, "node_id": node_id, "name_enc": name_enc })),
        ),
    )
    .await
}

async fn listed_roots(state: &AppState, token: &str) -> Vec<Value> {
    let (status, body) = call(state, req("GET", "/api/v1/roots", Some(token), None)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["roots"].as_array().cloned().unwrap_or_default()
}

async fn login_with_device(
    state: &AppState,
    email: &str,
    verifier: &str,
    name: &str,
) -> (Uuid, String) {
    let device_id = Uuid::new_v4();
    let device_key = nntdrive_crypto::DeviceKeypair::generate();
    let (status, body) = call(
        state,
        req(
            "POST",
            "/api/v1/auth/login",
            None,
            Some(json!({
                "email": email,
                "verifier": verifier,
                "device": {
                    "id": device_id,
                    "name": name,
                    "platform": "linux",
                    "public_key": base64_key(&device_key.public().0)
                }
            })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    (device_id, body["token"].as_str().unwrap().to_string())
}

#[tokio::test]
async fn global_root_bootstraps_once_and_is_tenant_scoped() {
    let Some(env) = env().await else { return };
    let alice = register(&env.state, "roots-global@example.com").await;
    let (status, first) = bootstrap_root(&env.state, &alice.token, "global", "Global").await;
    assert_eq!(status, StatusCode::CREATED, "{first}");
    let node = first["node_id"].as_str().unwrap().to_string();

    // A retry or another client converges on the same root and envelope.
    let (status, again) = bootstrap_root(&env.state, &alice.token, "global", "Different").await;
    assert_eq!(status, StatusCode::OK, "{again}");
    assert_eq!(again["node_id"], node);
    assert_eq!(again["name_enc"], first["name_enc"]);

    let listed = listed_roots(&env.state, &alice.token).await;
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["kind"], "global");
    assert_eq!(listed[0]["node_id"].as_str().unwrap(), node);
    assert_eq!(listed[0]["name_enc"], sealed("Global"));
    assert_eq!(listed[0]["stale"], false);
    assert!(listed[0]["device_id"].is_null(), "{listed:?}");

    // The root is an ordinary top-level folder for existing clients.
    let (status, body) = call(
        &env.state,
        req("GET", "/api/v1/files", Some(&alice.token), None),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let top = body["files"].as_array().unwrap();
    assert_eq!(top.len(), 1, "{top:?}");
    assert_eq!(top[0]["id"].as_str().unwrap(), node);
    assert_eq!(top[0]["is_dir"], true);

    // Only opaque ciphertext is stored, and exactly one root row exists.
    let stored: Vec<u8> =
        sqlx::query_scalar("SELECT name_enc FROM files WHERE account_id = $1 AND id = $2")
            .bind(alice.account_id)
            .bind(Uuid::parse_str(&node).unwrap())
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
    assert_eq!(stored, "Global".as_bytes());
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM account_roots WHERE account_id = $1")
        .bind(alice.account_id)
        .fetch_one(&env.state.pool)
        .await
        .unwrap();
    assert_eq!(count, 1);

    // Tenant isolation: another account starts empty and gets its own root.
    let bob = register(&env.state, "roots-other@example.com").await;
    assert!(listed_roots(&env.state, &bob.token).await.is_empty());
    let (status, bob_root) = bootstrap_root(&env.state, &bob.token, "global", "Global").await;
    assert_eq!(status, StatusCode::CREATED, "{bob_root}");
    assert_ne!(bob_root["node_id"].as_str().unwrap(), node);
    let visible = listed_roots(&env.state, &bob.token).await;
    assert_eq!(visible.len(), 1);
    assert_eq!(visible[0]["node_id"], bob_root["node_id"]);

    // The endpoint requires authentication.
    let (status, _) = call(&env.state, req("GET", "/api/v1/roots", None, None)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

/// Root names are sealed with the node ID as authenticated data, so the client
/// must choose the node ID before sealing. A real envelope for the chosen ID has
/// to stay openable after bootstrap, and a second client has to converge on that
/// same openable envelope instead of creating its own unopenable root.
#[tokio::test]
async fn client_sealed_root_names_stay_openable() {
    use base64::Engine;
    let Some(env) = env().await else { return };
    let alice = register(&env.state, "roots-sealed@example.com").await;
    let engine = base64::engine::general_purpose::STANDARD;

    let global_node = Uuid::new_v4();
    let global_sealed = alice
        .master
        .seal_name(global_node, "Global")
        .unwrap()
        .to_bytes();
    let (status, created) = bootstrap_root_at(
        &env.state,
        &alice.token,
        "global",
        global_node,
        &base64_key(&global_sealed),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");

    // The listed envelope must open with the node ID the server reports, which
    // is what every later client uses; a server-chosen ID would fail here.
    let listed = listed_roots(&env.state, &alice.token).await;
    assert_eq!(listed.len(), 1, "{listed:?}");
    let listed_node = Uuid::parse_str(listed[0]["node_id"].as_str().unwrap()).unwrap();
    let stored = engine
        .decode(listed[0]["name_enc"].as_str().unwrap())
        .unwrap();
    let envelope = nntdrive_crypto::Envelope::from_bytes(&stored).unwrap();
    assert_eq!(
        alice.master.open_name(listed_node, &envelope).unwrap(),
        "Global"
    );
    assert_eq!(listed_node, global_node);

    // A second device seals its own candidate first, then converges on the
    // original root; the returned envelope is still openable there.
    let (_device_two, token_two) = login_with_device(
        &env.state,
        "roots-sealed@example.com",
        &alice.verifier,
        "second",
    )
    .await;
    let candidate = Uuid::new_v4();
    let candidate_sealed = alice
        .master
        .seal_name(candidate, "Global candidate")
        .unwrap()
        .to_bytes();
    let (status, converged) = bootstrap_root_at(
        &env.state,
        &token_two,
        "global",
        candidate,
        &base64_key(&candidate_sealed),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{converged}");
    assert_eq!(
        converged["node_id"].as_str().unwrap(),
        global_node.to_string()
    );
    assert_eq!(converged["name_enc"], listed[0]["name_enc"]);
    let stored = engine
        .decode(converged["name_enc"].as_str().unwrap())
        .unwrap();
    let envelope = nntdrive_crypto::Envelope::from_bytes(&stored).unwrap();
    assert_eq!(
        alice.master.open_name(global_node, &envelope).unwrap(),
        "Global"
    );

    // A missing or nil node ID is refused instead of storing an unopenable name.
    for node in [json!(null), json!(Uuid::nil())] {
        let (status, body) = call(
            &env.state,
            req(
                "POST",
                "/api/v1/roots",
                Some(&alice.token),
                Some(json!({ "kind": "device", "node_id": node, "name_enc": sealed("x") })),
            ),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    }

    // Reusing an existing node ID is a conflict, not a second root.
    let (status, body) = bootstrap_root_at(
        &env.state,
        &alice.token,
        "device",
        global_node,
        &sealed("duplicate"),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
}

#[tokio::test]
async fn device_roots_are_per_device_and_need_a_device_token() {
    let Some(env) = env().await else { return };
    let alice = register(&env.state, "roots-device@example.com").await;
    let (status, first) = bootstrap_root(&env.state, &alice.token, "device", "This device").await;
    assert_eq!(status, StatusCode::CREATED, "{first}");
    assert_eq!(
        first["device_id"].as_str().unwrap(),
        alice.device_id.to_string()
    );
    let (status, again) = bootstrap_root(&env.state, &alice.token, "device", "Again").await;
    assert_eq!(status, StatusCode::OK, "{again}");
    assert_eq!(again["node_id"], first["node_id"]);

    // A token that is not bound to a device cannot own a device root.
    let (status, body) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/auth/login",
            None,
            Some(json!({
                "email": "roots-device@example.com",
                "verifier": alice.verifier
            })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let device_less = body["token"].as_str().unwrap().to_string();
    let (status, body) = bootstrap_root(&env.state, &device_less, "device", "No device").await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");

    // A second device gets its own root; every client sees both.
    let (device_two, token_two) = login_with_device(
        &env.state,
        "roots-device@example.com",
        &alice.verifier,
        "second",
    )
    .await;
    let (status, second) = bootstrap_root(&env.state, &token_two, "device", "This device").await;
    assert_eq!(status, StatusCode::CREATED, "{second}");
    assert_eq!(
        second["device_id"].as_str().unwrap(),
        device_two.to_string()
    );
    assert_ne!(second["node_id"], first["node_id"]);

    let listed = listed_roots(&env.state, &alice.token).await;
    assert_eq!(listed.len(), 2, "{listed:?}");
    assert!(
        listed
            .iter()
            .all(|r| r["kind"] == "device" && r["stale"] == false),
        "{listed:?}"
    );
    let names: Vec<String> = listed
        .iter()
        .map(|r| r["device_name"].as_str().unwrap_or_default().to_string())
        .collect();
    assert!(names.contains(&"test".to_string()), "{names:?}");
    assert!(names.contains(&"second".to_string()), "{names:?}");

    // Revoking a device keeps its root listed, marked stale.
    let (status, body) = call(
        &env.state,
        req(
            "DELETE",
            &format!("/api/v1/devices/{device_two}"),
            Some(&alice.token),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let listed = listed_roots(&env.state, &alice.token).await;
    assert_eq!(listed.len(), 2, "{listed:?}");
    assert!(
        listed.iter().any(|r| {
            r["device_id"].as_str() == Some(device_two.to_string().as_str())
                && r["device_revoked"] == true
                && r["stale"] == true
        }),
        "{listed:?}"
    );
}

#[tokio::test]
async fn fixed_roots_reject_rename_move_and_delete() {
    let Some(env) = env().await else { return };
    let alice = register(&env.state, "roots-fixed@example.com").await;
    let (status, global) = bootstrap_root(&env.state, &alice.token, "global", "Global").await;
    assert_eq!(status, StatusCode::CREATED, "{global}");
    let root_node = global["node_id"].as_str().unwrap().to_string();

    // An ordinary folder next to the root, used as a move destination.
    let folder = Uuid::new_v4();
    let (status, body) = call(
        &env.state,
        req(
            "POST",
            "/api/v1/files",
            Some(&alice.token),
            Some(json!({
                "id": folder,
                "parent_id": null,
                "name_enc": sealed("Folder"),
                "is_dir": true
            })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");

    // Rename with the exact current root-level snapshot still refuses the root.
    let siblings = vec![
        json!({ "id": root_node, "name_enc": sealed("Global") }),
        json!({ "id": folder, "name_enc": sealed("Folder") }),
    ];
    let (status, body) = call(
        &env.state,
        req(
            "POST",
            &format!("/api/v1/files/{root_node}/rename"),
            Some(&alice.token),
            Some(json!({
                "parent_id": null,
                "name_enc": sealed("Renamed"),
                "siblings": siblings
            })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert!(
        body["message"]
            .as_str()
            .unwrap_or_default()
            .contains("fixed account root"),
        "{body}"
    );

    // Moving into a folder and a no-op move are both refused.
    for target in [json!(folder), Value::Null] {
        let (status, body) = call(
            &env.state,
            req(
                "POST",
                &format!("/api/v1/files/{root_node}/move"),
                Some(&alice.token),
                Some(json!({ "parent_id": target })),
            ),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
    }

    // Delete and rename through the generic patch endpoint are refused too.
    let (status, body) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/files/{root_node}"),
            Some(&alice.token),
            Some(json!({ "deleted": true })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    let (status, body) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/files/{root_node}"),
            Some(&alice.token),
            Some(json!({ "name_enc": sealed("Nope") })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");

    // Favourite is not structural and stays allowed.
    let (status, body) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/files/{root_node}"),
            Some(&alice.token),
            Some(json!({ "favorite": true })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");

    // Ordinary folders keep the normal behaviour.
    let (status, body) = call(
        &env.state,
        req(
            "PATCH",
            &format!("/api/v1/files/{folder}"),
            Some(&alice.token),
            Some(json!({ "deleted": true })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let root_alive: bool =
        sqlx::query_scalar("SELECT NOT deleted FROM files WHERE account_id = $1 AND id = $2")
            .bind(alice.account_id)
            .bind(Uuid::parse_str(&root_node).unwrap())
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
    assert!(root_alive);
}

#[tokio::test]
async fn concurrent_bootstrap_creates_one_global_root() {
    let Some(env) = env().await else { return };
    let alice = register(&env.state, "roots-race@example.com").await;
    let (a, b) = tokio::join!(
        bootstrap_root(&env.state, &alice.token, "global", "First"),
        bootstrap_root(&env.state, &alice.token, "global", "Second")
    );
    assert!(
        a.0 == StatusCode::CREATED || a.0 == StatusCode::OK,
        "{:?}",
        a.1
    );
    assert!(
        b.0 == StatusCode::CREATED || b.0 == StatusCode::OK,
        "{:?}",
        b.1
    );
    assert_eq!(a.1["node_id"], b.1["node_id"]);
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM account_roots WHERE account_id = $1")
        .bind(alice.account_id)
        .fetch_one(&env.state.pool)
        .await
        .unwrap();
    assert_eq!(count, 1);
    assert_eq!(listed_roots(&env.state, &alice.token).await.len(), 1);
}
