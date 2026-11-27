//! Fail-closed privacy regressions against disposable PostgreSQL, never mocks.
use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{Request, StatusCode};
use base64::{engine::general_purpose::STANDARD, Engine};
use http_body_util::BodyExt;
use nntdrive_backend::{
    app,
    state::{AppState, ServerConfig},
};
use nntdrive_crypto::{DeviceKeypair, Envelope, MasterKey};
use nntdrive_nntp::{MockConfig, MockNntpServer, NntpPool};
use nntdrive_storage::TestDb;
use serde_json::{json, Value};
use std::{net::SocketAddr, sync::Arc};
use tower::ServiceExt;
use uuid::Uuid;

struct Env {
    state: AppState,
    _db: TestDb,
    _server: MockNntpServer,
    _cache: tempfile::TempDir,
}

async fn env() -> Env {
    let db = TestDb::create()
        .await
        .expect("device privacy requires isolated PostgreSQL");
    let server = MockNntpServer::start(MockConfig::default()).await;
    let cache = tempfile::tempdir().unwrap();
    let config = ServerConfig {
        bind: "127.0.0.1:0".into(),
        cache_dir: cache.path().to_path_buf(),
        cache_limit_bytes: 1024 * 1024,
        allow_registration: true,
        secret_key: [7; 32],
        default_quota_bytes: None,
        health_check_interval_secs: 3600,
        retention_refresh_days: 30,
        retention_interval_secs: 3600,
        trash_retention_days: 30,
    };
    let nntp = Arc::new(NntpPool::new(vec![server.client_config()]).unwrap());
    let state = AppState::new(db.store.pool().clone(), nntp, config).unwrap();
    Env {
        state,
        _db: db,
        _server: server,
        _cache: cache,
    }
}

async fn call(
    state: &AppState,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Value,
) -> (StatusCode, Value) {
    let mut builder = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    let mut request = builder
        .body(Body::from(serde_json::to_vec(&body).unwrap()))
        .unwrap();
    request
        .extensions_mut()
        .insert(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 40000))));
    let response = app(state.clone()).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap())
}

struct Account {
    id: Uuid,
    device: Uuid,
    email: String,
    token: String,
    key: String,
}

async fn register(state: &AppState, legacy_name: Option<&str>) -> Account {
    let id = Uuid::new_v4();
    let device = Uuid::new_v4();
    let email = format!("{id}@example.test");
    let key = STANDARD.encode(DeviceKeypair::generate().public().0);
    let mut payload = json!({"id": device, "public_key": key, "platform": "linux"});
    if let Some(name) = legacy_name {
        payload["name"] = json!(name);
    }
    let (status, body) = call(
        state,
        "POST",
        "/api/v1/auth/register",
        None,
        json!({
            "account_id": id, "email": email, "verifier": "ab".repeat(32),
            "keyfile": {}, "device": payload
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["device_id"], json!(device));
    Account {
        id,
        device,
        email,
        token: body["token"].as_str().unwrap().into(),
        key,
    }
}

async fn device_row(state: &AppState, device: Uuid) -> (Uuid, String, String, String) {
    sqlx::query_as("SELECT account_id, name, platform, public_key FROM devices WHERE id = $1")
        .bind(device)
        .fetch_one(&state.pool)
        .await
        .unwrap()
}

async fn identity_login(
    state: &AppState,
    account: &Account,
    id: Option<Uuid>,
    key: &str,
) -> (StatusCode, Value) {
    call(
        state,
        "POST",
        "/api/v1/auth/login",
        None,
        json!({
            "email": account.email, "verifier": "ab".repeat(32),
            "device": {"id": id, "platform": "linux", "public_key": key}
        }),
    )
    .await
}

#[tokio::test]
async fn identity_reuses_missing_unknown_and_concurrent_ids_with_existing_root() {
    let env = env().await;
    let alice = register(&env.state, None).await;
    let node = Uuid::new_v4();
    let master = MasterKey::generate(alice.id, 1);
    let sealed = STANDARD.encode(master.seal_name(node, "Private root").unwrap().to_bytes());
    assert_eq!(
        call(
            &env.state,
            "POST",
            "/api/v1/roots",
            Some(&alice.token),
            json!({"kind": "device", "node_id": node, "name_enc": sealed})
        )
        .await
        .0,
        StatusCode::CREATED
    );
    for id in [None, Some(Uuid::new_v4()), Some(alice.device)] {
        let (status, body) = identity_login(&env.state, &alice, id, &alice.key).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body["device_id"], json!(alice.device));
        let token = body["token"].as_str().unwrap();
        let (status, roots) =
            call(&env.state, "GET", "/api/v1/roots", Some(token), Value::Null).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(roots["roots"][0]["node_id"], json!(node));
        assert_eq!(roots["roots"][0]["name_enc"], sealed);
    }
    let key = STANDARD.encode(DeviceKeypair::generate().public().0);
    let (a, b) = tokio::time::timeout(std::time::Duration::from_secs(20), async {
        tokio::join!(
            identity_login(&env.state, &alice, None, &key),
            identity_login(&env.state, &alice, Some(Uuid::new_v4()), &key)
        )
    })
    .await
    .expect("concurrent enrollment must finish");
    assert_eq!(a.0, StatusCode::OK, "{}", a.1);
    assert_eq!(b.0, StatusCode::OK, "{}", b.1);
    assert_eq!(a.1["device_id"], b.1["device_id"]);
    assert_ne!(a.1["device_id"], json!(alice.device));
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE account_id = $1")
        .bind(alice.id)
        .fetch_one(&env.state.pool)
        .await
        .unwrap();
    assert_eq!(count, 2);
}

#[tokio::test]
async fn identity_conflicts_revocation_and_legacy_duplicates_fail_without_tokens() {
    let env = env().await;
    let alice = register(&env.state, None).await;
    let bob = register(&env.state, None).await;
    let other_key = STANDARD.encode(DeviceKeypair::generate().public().0);
    let before: i64 = sqlx::query_scalar("SELECT count(*) FROM api_tokens")
        .fetch_one(&env.state.pool)
        .await
        .unwrap();
    assert_eq!(
        identity_login(&env.state, &alice, Some(alice.device), &other_key)
            .await
            .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        identity_login(&env.state, &alice, Some(bob.device), &alice.key)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    sqlx::query("UPDATE devices SET revoked_at = now() WHERE id = $1")
        .bind(alice.device)
        .execute(&env.state.pool)
        .await
        .unwrap();
    for id in [Some(alice.device), None, Some(Uuid::new_v4())] {
        assert_eq!(
            identity_login(&env.state, &alice, id, &alice.key).await.0,
            StatusCode::UNAUTHORIZED
        );
    }
    let after: i64 = sqlx::query_scalar("SELECT count(*) FROM api_tokens")
        .fetch_one(&env.state.pool)
        .await
        .unwrap();
    assert_eq!(before, after);
    // Legacy duplicates are not silently merged or selected; explicit known IDs remain usable.
    sqlx::query("INSERT INTO devices (id, account_id, name, public_key, platform) VALUES ($1,$2,'Device',$3,'linux')")
        .bind(Uuid::new_v4()).bind(bob.id).bind(&bob.key).execute(&env.state.pool).await.unwrap();
    assert_eq!(
        identity_login(&env.state, &bob, None, &bob.key).await.0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        identity_login(&env.state, &bob, Some(bob.device), &bob.key)
            .await
            .0,
        StatusCode::OK
    );
    // Same key in a different tenant is independent, not a cross-account dedupe.
    let (status, body) = identity_login(&env.state, &bob, None, &alice.key).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_ne!(body["device_id"], json!(alice.device));
}

#[tokio::test]
async fn registration_and_login_never_persist_legacy_device_names() {
    let env = env().await;
    let alice = register(&env.state, Some("Alice private laptop")).await;
    assert_eq!(
        device_row(&env.state, alice.device).await,
        (alice.id, "Device".into(), "linux".into(), alice.key.clone())
    );
    // Same-device upsert ignores a new legacy name, preserves enrollment key,
    // updates platform/last-seen and still issues a working bound token.
    let (status, login) = call(&env.state, "POST", "/api/v1/auth/login", None, json!({
        "email": alice.email, "verifier": "ab".repeat(32),
        "device": {"id": alice.device, "name": "Secret renamed hostname", "platform": "windows", "public_key": alice.key}
    })).await;
    assert_eq!(status, StatusCode::OK, "{login}");
    assert_eq!(login["device_id"], json!(alice.device));
    assert_eq!(
        device_row(&env.state, alice.device).await,
        (
            alice.id,
            "Device".into(),
            "windows".into(),
            alice.key.clone()
        )
    );
    let seen: bool =
        sqlx::query_scalar("SELECT last_seen_at IS NOT NULL FROM devices WHERE id = $1")
            .bind(alice.device)
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
    assert!(seen);
    assert_eq!(
        call(
            &env.state,
            "GET",
            "/api/v1/me",
            login["token"].as_str(),
            Value::Null
        )
        .await
        .0,
        StatusCode::OK
    );

    // New clients may omit the obsolete field altogether at either entry point.
    let bob = register(&env.state, None).await;
    assert_eq!(device_row(&env.state, bob.device).await.1, "Device");
    let fresh = Uuid::new_v4();
    let (status, login) = call(
        &env.state,
        "POST",
        "/api/v1/auth/login",
        None,
        json!({
            "email": alice.email, "verifier": "ab".repeat(32),
            "device": {"id": fresh, "platform": "android", "public_key": alice.key}
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{login}");
    assert_eq!(login["device_id"], json!(alice.device));
    assert_eq!(
        device_row(&env.state, alice.device).await,
        (
            alice.id,
            "Device".into(),
            "android".into(),
            alice.key.clone()
        )
    );

    let tokens_before: i64 =
        sqlx::query_scalar("SELECT count(*) FROM api_tokens WHERE account_id = $1")
            .bind(alice.id)
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
    let bob_before = device_row(&env.state, bob.device).await;
    let (status, _) = call(&env.state, "POST", "/api/v1/auth/login", None, json!({
        "email": alice.email, "verifier": "ab".repeat(32),
        "device": {"id": bob.device, "name": "Cross-tenant overwrite", "platform": "windows", "public_key": alice.key}
    })).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(device_row(&env.state, bob.device).await, bob_before);
    let tokens_after: i64 =
        sqlx::query_scalar("SELECT count(*) FROM api_tokens WHERE account_id = $1")
            .bind(alice.id)
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
    assert_eq!(tokens_after, tokens_before);
}

#[tokio::test]
async fn device_and_root_responses_expose_only_placeholder_and_sealed_label() {
    let env = env().await;
    let alice = register(&env.state, Some("Private workstation")).await;
    let bob = register(&env.state, Some("Other private workstation")).await;
    let master = MasterKey::generate(alice.id, 1);
    let node = Uuid::new_v4();
    let ciphertext = master
        .seal_name(node, "Confirmed private device label")
        .unwrap()
        .to_bytes();
    let (status, root) = call(
        &env.state,
        "POST",
        "/api/v1/roots",
        Some(&alice.token),
        json!({
            "kind": "device", "node_id": node, "name_enc": STANDARD.encode(&ciphertext)
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{root}");
    let global = Uuid::new_v4();
    let (status, _) = call(
        &env.state,
        "POST",
        "/api/v1/roots",
        Some(&alice.token),
        json!({
            "kind": "global", "node_id": global,
            "name_enc": STANDARD.encode(master.seal_name(global, "Global").unwrap().to_bytes())
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    // Simulate residual pre-upgrade rows ONLY in the disposable test schema.
    // This proves response redaction independently of the migration/trigger.
    let mut tx = env.state.pool.begin().await.unwrap();
    sqlx::query("ALTER TABLE devices DISABLE TRIGGER devices_anonymous_name")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("UPDATE devices SET name = 'Residual legacy hostname'")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("ALTER TABLE devices ENABLE TRIGGER devices_anonymous_name")
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    for account in [&alice, &bob] {
        for path in ["/api/v1/me", "/api/v1/devices"] {
            let (status, body) =
                call(&env.state, "GET", path, Some(&account.token), Value::Null).await;
            assert_eq!(status, StatusCode::OK);
            let devices = body["devices"].as_array().unwrap();
            assert_eq!(devices.len(), 1);
            assert_eq!(devices[0]["id"], json!(account.device));
            assert_eq!(devices[0]["name"], "Device");
            assert_eq!(devices[0]["current"], true);
            assert!(!body.to_string().contains("Residual legacy hostname"));
        }
    }
    let (status, body) = call(
        &env.state,
        "GET",
        "/api/v1/roots",
        Some(&alice.token),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let roots = body["roots"].as_array().unwrap();
    assert_eq!(roots.len(), 2);
    let device = roots.iter().find(|r| r["kind"] == "device").unwrap();
    assert_eq!(device["device_name"], "Device");
    assert_eq!(device["node_id"], json!(node));
    assert_eq!(device["name_enc"], STANDARD.encode(&ciphertext));
    assert_eq!(
        master
            .open_name(node, &Envelope::from_bytes(&ciphertext).unwrap())
            .unwrap(),
        "Confirmed private device label"
    );
    assert!(roots.iter().find(|r| r["kind"] == "global").unwrap()["device_name"].is_null());
    assert!(!body.to_string().contains("Residual legacy hostname"));
    assert!(!body.to_string().contains("Confirmed private device label"));
    let (status, body) = call(
        &env.state,
        "GET",
        "/api/v1/roots",
        Some(&bob.token),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["roots"], json!([]));
    let (status, _) = call(
        &env.state,
        "DELETE",
        &format!("/api/v1/devices/{}", alice.device),
        Some(&bob.token),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let stored: Vec<u8> =
        sqlx::query_scalar("SELECT name_enc FROM files WHERE account_id = $1 AND id = $2")
            .bind(alice.id)
            .bind(node)
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
    assert_eq!(stored, ciphertext);
}

// Include whole rows (and raw BYTEA via PostgreSQL JSON) so preservation checks
// cover ciphertext, current content revision, ancestry and immutable history.
async fn account_namespace(state: &AppState, account: Uuid) -> Value {
    sqlx::query_scalar("SELECT jsonb_build_object(
        'files', (SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY id), '[]') FROM files f WHERE account_id=$1),
        'versions', (SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY id), '[]') FROM file_versions v WHERE account_id=$1),
        'roots', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id), '[]') FROM account_roots r WHERE account_id=$1),
        'events', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY seq), '[]') FROM sync_events e WHERE account_id=$1))")
        .bind(account).fetch_one(&state.pool).await.unwrap()
}

#[tokio::test]
async fn guarded_device_root_rename_preserves_tree_history_and_tenant_boundaries() {
    let env = env().await;
    let alice = register(&env.state, None).await;
    let foreign = register(&env.state, None).await;
    let master = MasterKey::generate(alice.id, 1);
    let seal = |id, name: &str| STANDARD.encode(master.seal_name(id, name).unwrap().to_bytes());
    // An independent enrolled reader of the same account, not the renamer's token.
    let reader_device = Uuid::new_v4();
    let (status, reader) = call(
        &env.state,
        "POST",
        "/api/v1/auth/login",
        None,
        json!({
            "email": alice.email, "verifier": "ab".repeat(32),
            "device": {"id": reader_device, "platform": "android",
                       "public_key": STANDARD.encode(DeviceKeypair::generate().public().0)}
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{reader}");
    let reader_token = reader["token"].as_str().unwrap();
    let root = Uuid::new_v4();
    let global = Uuid::new_v4();
    let old_name = seal(root, "Original private laptop");
    let global_name = seal(global, "Global");
    for (id, kind, name) in [
        (root, "device", &old_name),
        (global, "global", &global_name),
    ] {
        let (status, body) = call(
            &env.state,
            "POST",
            "/api/v1/roots",
            Some(&alice.token),
            json!({
                "kind": kind, "node_id": id, "name_enc": name
            }),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
    }
    let folder = Uuid::new_v4();
    let child = Uuid::new_v4();
    for (id, parent, is_dir, label) in [
        (folder, root, true, "Private folder"),
        (child, folder, false, "Private document"),
    ] {
        let (status, body) = call(
            &env.state,
            "POST",
            "/api/v1/files",
            Some(&alice.token),
            json!({
                "id": id, "parent_id": parent, "is_dir": is_dir, "name_enc": seal(id, label)
            }),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
    }
    // Real authenticated manifests for two committed empty-content versions.
    // Empty content needs no fabricated chunks or ciphertext articles.
    let revisions = [Uuid::new_v4(), Uuid::new_v4()];
    let mut manifests = Vec::new();
    for (index, revision) in revisions.into_iter().enumerate() {
        let manifest = nntdrive_storage::FileManifest::new(child, revision, 0, String::new());
        let sealed = master
            .seal_manifest(child, revision, &manifest.to_bytes())
            .unwrap()
            .to_bytes();
        let previous = index.checked_sub(1).map(|i| revisions[i]);
        let (status, body) = call(
            &env.state,
            "POST",
            &format!("/api/v1/files/{child}/versions"),
            Some(&alice.token),
            json!({
                "revision_id": revision, "parent_revision": previous, "base_revision": previous,
                "size": 0, "sealed_manifest": STANDARD.encode(&sealed), "chunk_ids": []
            }),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        manifests.push((sealed, manifest.to_bytes()));
    }
    let before = account_namespace(&env.state, alice.id).await;
    let siblings =
        json!([{"id": root, "name_enc": old_name}, {"id": global, "name_enc": global_name}]);
    let new_name = seal(root, "Confirmed private laptop");
    let rename_path = format!("/api/v1/files/{root}/rename");
    let payload = json!({"parent_id": null, "name_enc": new_name, "siblings": siblings});
    // This assertion is the old-code regression: the original blanket fixed-root
    // check returns 409 instead of 200 even for this exact fresh snapshot.
    let (status, body) = call(
        &env.state,
        "POST",
        &rename_path,
        Some(&alice.token),
        payload.clone(),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "guarded device-root rename must succeed: {body}"
    );
    let after = account_namespace(&env.state, alice.id).await;
    assert_eq!(
        before["roots"], after["roots"],
        "root and device/node identities stay fixed"
    );
    assert_eq!(
        before["versions"], after["versions"],
        "all immutable history and ciphertext stay byte-identical"
    );
    assert_eq!(after["versions"].as_array().unwrap().len(), 2);
    let mut expected_files = before["files"].clone();
    let expected_root = expected_files
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|f| f["id"] == json!(root))
        .unwrap();
    let actual_root = after["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["id"] == json!(root))
        .unwrap();
    assert_ne!(expected_root["name_enc"], actual_root["name_enc"]);
    assert_eq!(
        actual_root["revision"].as_i64().unwrap(),
        expected_root["revision"].as_i64().unwrap() + 1
    );
    for field in ["name_enc", "revision", "updated_at"] {
        expected_root[field] = actual_root[field].clone();
    }
    assert_eq!(
        expected_files, after["files"],
        "only root name, namespace revision and timestamp may change"
    );
    let current: Uuid =
        sqlx::query_scalar("SELECT current_version FROM files WHERE account_id=$1 AND id=$2")
            .bind(alice.id)
            .bind(child)
            .fetch_one(&env.state.pool)
            .await
            .unwrap();
    assert_eq!(current, revisions[1]);
    for (revision, (sealed, plaintext)) in revisions.into_iter().zip(&manifests) {
        let stored: Vec<u8> = sqlx::query_scalar("SELECT manifest FROM file_versions WHERE account_id=$1 AND file_id=$2 AND revision_id=$3")
            .bind(alice.id).bind(child).bind(revision).fetch_one(&env.state.pool).await.unwrap();
        assert_eq!(&stored, sealed);
        let opened = master
            .open_manifest(child, revision, &Envelope::from_bytes(&stored).unwrap())
            .unwrap();
        assert_eq!(&opened, plaintext);
    }
    let old_events = before["events"].as_array().unwrap();
    let events = after["events"].as_array().unwrap();
    assert_eq!(&events[..old_events.len()], old_events.as_slice());
    assert_eq!(events.len(), old_events.len() + 1);
    let event = events.last().unwrap();
    assert_eq!(event["kind"], "rename");
    assert_eq!(event["file_id"], json!(root));
    assert_eq!(event["device_id"], json!(alice.device));
    assert!(event["revision_id"].is_null());
    let (status, roots) = call(
        &env.state,
        "GET",
        "/api/v1/roots",
        Some(reader_token),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{roots}");
    let visible = roots["roots"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["node_id"] == json!(root))
        .unwrap();
    assert_eq!(visible["name_enc"], new_name);
    assert_eq!(visible["device_name"], "Device");
    let bytes = STANDARD
        .decode(visible["name_enc"].as_str().unwrap())
        .unwrap();
    assert_eq!(
        master
            .open_name(root, &Envelope::from_bytes(&bytes).unwrap())
            .unwrap(),
        "Confirmed private laptop"
    );
    assert!(!roots.to_string().contains("Confirmed private laptop"));

    // Exact snapshots, including opaque envelopes and complete membership, are
    // still mandatory for a device root. No special unguarded rename escape.
    let current_siblings =
        json!([{"id": root, "name_enc": new_name}, {"id": global, "name_enc": global_name}]);
    let next_name = seal(root, "Must not be published");
    for guard in [
        siblings.clone(),
        json!([{"id": root, "name_enc": new_name}]),
    ] {
        let (status, body) = call(
            &env.state,
            "POST",
            &rename_path,
            Some(&alice.token),
            json!({
                "parent_id": null, "name_enc": next_name, "siblings": guard
            }),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
    }
    let (status, body) = call(
        &env.state,
        "POST",
        &rename_path,
        Some(&alice.token),
        json!({
            "parent_id": folder, "name_enc": next_name, "siblings": current_siblings
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    let (status, body) = call(&env.state, "POST", &format!("/api/v1/files/{global}/rename"), Some(&alice.token), json!({
        "parent_id": null, "name_enc": seal(global, "Forbidden Global rename"), "siblings": current_siblings
    })).await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert!(body["message"]
        .as_str()
        .unwrap()
        .contains("fixed account root"));
    for id in [root, global] {
        for parent in [Value::Null, json!(folder)] {
            for endpoint in ["move", "move-checked"] {
                let name = if id == root { &new_name } else { &global_name };
                let (status, body) = call(&env.state, "POST", &format!("/api/v1/files/{id}/{endpoint}"), Some(&alice.token), json!({
                    "parent_id": parent, "source_parent_id": null, "source_name_enc": name, "siblings": []
                })).await;
                assert_eq!(status, StatusCode::CONFLICT, "{endpoint}: {body}");
            }
        }
        for patch in [
            json!({"deleted": true}),
            json!({"name_enc": seal(id, "Forbidden legacy rename")}),
        ] {
            let (status, body) = call(
                &env.state,
                "PATCH",
                &format!("/api/v1/files/{id}"),
                Some(&alice.token),
                patch,
            )
            .await;
            assert_eq!(status, StatusCode::CONFLICT, "{body}");
        }
    }
    let (status, body) = call(
        &env.state,
        "POST",
        &rename_path,
        Some(&foreign.token),
        json!({
            "parent_id": null, "name_enc": next_name, "siblings": current_siblings
        }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    for path in [
        format!("/api/v1/files/{child}/versions"),
        format!("/api/v1/files/{child}/manifest"),
        format!("/api/v1/files/{root}/manifest"),
    ] {
        let (status, body) =
            call(&env.state, "GET", &path, Some(&foreign.token), Value::Null).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    }
    for path in [
        "/api/v1/roots".to_owned(),
        "/api/v1/files".to_owned(),
        format!("/api/v1/files?parent_id={root}"),
        format!("/api/v1/files?parent_id={folder}"),
    ] {
        let (status, body) =
            call(&env.state, "GET", &path, Some(&foreign.token), Value::Null).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let entries = if path == "/api/v1/roots" {
            &body["roots"]
        } else {
            &body["files"]
        };
        assert_eq!(entries, &json!([]), "{body}");
    }
    assert_eq!(
        account_namespace(&env.state, alice.id).await,
        after,
        "all rejected mutations must leave namespace, history and events untouched"
    );
}

#[tokio::test]
async fn migration_scrubs_legacy_rows_and_normalizes_legacy_writers() {
    let db = TestDb::create()
        .await
        .expect("device privacy migration requires isolated PostgreSQL");
    // Build an actual pre-upgrade schema. Rollback removes it and all fixtures.
    let mut tx = db.store.pool().begin().await.unwrap();
    let schema = format!("device_upgrade_{}", Uuid::new_v4().simple());
    sqlx::query(&format!("CREATE SCHEMA {schema}"))
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query(&format!("SET LOCAL search_path TO {schema}"))
        .execute(&mut *tx)
        .await
        .unwrap();
    for migration in [
        include_str!("../../../migrations/0001_init.sql"),
        include_str!("../../../migrations/0002_account_keys.sql"),
        include_str!("../../../migrations/0003_provider_management.sql"),
        include_str!("../../../migrations/0004_maintenance_results.sql"),
        include_str!("../../../migrations/0005_chunk_references.sql"),
        include_str!("../../../migrations/0006_account_roots.sql"),
        include_str!("../../../migrations/0007_trash.sql"),
    ] {
        sqlx::raw_sql(migration).execute(&mut *tx).await.unwrap();
    }
    let alice = Uuid::new_v4();
    let bob = Uuid::new_v4();
    let device = Uuid::new_v4();
    let other = Uuid::new_v4();
    for (account, id, name) in [
        (alice, device, "Legacy personal laptop"),
        (bob, other, "Legacy personal phone"),
    ] {
        sqlx::query("INSERT INTO accounts(id,email,password_hash) VALUES($1,$2,'test')")
            .bind(account)
            .bind(format!("{account}@example.test"))
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(id,account_id,name,public_key,platform,last_seen_at,revoked_at) VALUES($1,$2,$3,'unchanged-key','linux',now(),now())")
            .bind(id).bind(account).bind(name).execute(&mut *tx).await.unwrap();
    }
    let node = Uuid::new_v4();
    let ciphertext = MasterKey::generate(alice, 1)
        .seal_name(node, "Encrypted original label")
        .unwrap()
        .to_bytes();
    sqlx::query("INSERT INTO files(id,account_id,name_enc,is_dir) VALUES($1,$2,$3,true)")
        .bind(node)
        .bind(alice)
        .bind(&ciphertext)
        .execute(&mut *tx)
        .await
        .unwrap();
    let root = Uuid::new_v4();
    sqlx::query("INSERT INTO account_roots(id,account_id,kind,device_id,node_id) VALUES($1,$2,'device',$3,$4)")
        .bind(root).bind(alice).bind(device).bind(node).execute(&mut *tx).await.unwrap();
    let before: Vec<Value> =
        sqlx::query_scalar("SELECT to_jsonb(d) - 'name' FROM devices d ORDER BY id")
            .fetch_all(&mut *tx)
            .await
            .unwrap();
    sqlx::raw_sql(include_str!(
        "../../../migrations/0008_private_device_names.sql"
    ))
    .execute(&mut *tx)
    .await
    .unwrap();
    let names: Vec<String> = sqlx::query_scalar("SELECT name FROM devices ORDER BY id")
        .fetch_all(&mut *tx)
        .await
        .unwrap();
    assert_eq!(names, ["Device", "Device"]);
    let after: Vec<Value> =
        sqlx::query_scalar("SELECT to_jsonb(d) - 'name' FROM devices d ORDER BY id")
            .fetch_all(&mut *tx)
            .await
            .unwrap();
    assert_eq!(
        before, after,
        "scrub must preserve identity, keys, timestamps and revocation"
    );
    let preserved: (Uuid, Uuid, Vec<u8>) = sqlx::query_as("SELECT r.id,r.node_id,f.name_enc FROM account_roots r JOIN files f ON f.account_id=r.account_id AND f.id=r.node_id WHERE r.account_id=$1")
        .bind(alice).fetch_one(&mut *tx).await.unwrap();
    assert_eq!(preserved, (root, node, ciphertext));
    // Old backend INSERT/UPDATE/UPSERT and omitted/NULL names all normalize,
    // including RETURNING (nothing echoes the submitted plaintext).
    let fresh = Uuid::new_v4();
    let name: String = sqlx::query_scalar("INSERT INTO devices(id,account_id,name,public_key) VALUES($1,$2,'Old backend hostname','key') RETURNING name")
        .bind(fresh).bind(alice).fetch_one(&mut *tx).await.unwrap();
    assert_eq!(name, "Device");
    let name: String = sqlx::query_scalar("INSERT INTO devices(id,account_id,name,public_key) VALUES($1,$2,'Old upsert hostname','key') ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name RETURNING name")
        .bind(fresh).bind(alice).fetch_one(&mut *tx).await.unwrap();
    assert_eq!(name, "Device");
    for value in [Some("Old update hostname"), Some(""), None] {
        let name: String = sqlx::query_scalar(
            "UPDATE devices SET name=$2 WHERE id=$1 AND account_id=$3 RETURNING name",
        )
        .bind(device)
        .bind(value)
        .bind(alice)
        .fetch_one(&mut *tx)
        .await
        .unwrap();
        assert_eq!(name, "Device");
    }
    for with_null in [false, true] {
        let sql = if with_null {
            "INSERT INTO devices(id,account_id,name,public_key) VALUES($1,$2,NULL,'key') RETURNING name"
        } else {
            "INSERT INTO devices(id,account_id,public_key) VALUES($1,$2,'key') RETURNING name"
        };
        let name: String = sqlx::query_scalar(sql)
            .bind(Uuid::new_v4())
            .bind(bob)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
        assert_eq!(name, "Device");
    }
    let other_after: Value = sqlx::query_scalar(
        "SELECT to_jsonb(d) - 'name' FROM devices d WHERE id=$1 AND account_id=$2",
    )
    .bind(other)
    .bind(bob)
    .fetch_one(&mut *tx)
    .await
    .unwrap();
    assert!(
        before.contains(&other_after),
        "legacy tenant-scoped writes must not mutate the other tenant"
    );
    tx.rollback().await.unwrap();
}
