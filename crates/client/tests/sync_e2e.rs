//! Two-device folder sync through the real HTTP API and mock NNTP provider.

use nntdrive_backend::state::{AppState, ServerConfig};
use nntdrive_client::{ApiClient, HttpRemote};
use nntdrive_crypto::{derive_auth_verifier, DeviceKeypair, KeyFile, MasterKey};
use nntdrive_nntp::{MockConfig, MockNntpServer, NntpPool};
use nntdrive_storage::TestDb;
use nntdrive_sync::{Journal, SyncEngine};
use serde_json::json;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use uuid::Uuid;

struct Stack {
    _db: TestDb,
    _nntp: MockNntpServer,
    _cache: tempfile::TempDir,
    addr: SocketAddr,
    token: String,
    master: MasterKey,
    _task: tokio::task::JoinHandle<()>,
}

async fn stack() -> Option<Stack> {
    let db = TestDb::create().await?;
    let nntp = MockNntpServer::start(MockConfig::default()).await;
    let pool = Arc::new(NntpPool::new(vec![nntp.client_config()]).unwrap());
    let cache = tempfile::tempdir().unwrap();
    let config = ServerConfig {
        bind: "127.0.0.1:0".into(),
        cache_dir: cache.path().to_path_buf(),
        cache_limit_bytes: 32 * 1024 * 1024,
        allow_registration: false,
        secret_key: [5u8; 32],
        default_quota_bytes: None,
        health_check_interval_secs: 3600,
        retention_refresh_days: 30,
        retention_interval_secs: 3600,
    };
    let state = AppState::new(db.store.pool().clone(), pool, config).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let handler = tokio::spawn(async move {
        axum::serve(
            listener,
            nntdrive_backend::app(state).into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .unwrap();
    });

    let account_id = Uuid::new_v4();
    let password = "sync test password";
    let (keyfile, master) = KeyFile::create(password, account_id).unwrap();
    let verifier = derive_auth_verifier(password, account_id);
    let device = DeviceKeypair::generate();
    let res = reqwest::Client::new()
        .post(format!("http://{addr}/api/v1/auth/register"))
        .json(&json!({
            "account_id": account_id,
            "email": format!("sync-{account_id}@example.com"),
            "verifier": verifier,
            "keyfile": keyfile,
            "device": {
                "id": Uuid::new_v4(),
                "name": "sync-test",
                "platform": "linux",
                "public_key": b64(&device.public().0),
            }
        }))
        .send()
        .await
        .unwrap();
    assert!(res.status().is_success());
    let body: serde_json::Value = res.json().await.unwrap();
    let token = body["token"].as_str().unwrap().to_string();
    Some(Stack {
        _db: db,
        _nntp: nntp,
        _cache: cache,
        addr,
        token,
        master,
        _task: handler,
    })
}

fn api(s: &Stack) -> ApiClient {
    let mut api = ApiClient::new(format!("http://{}", s.addr)).unwrap();
    api.set_token(s.token.clone());
    api
}

async fn make_root(s: &Stack, api: &ApiClient, name: &str) -> Uuid {
    let id = Uuid::new_v4();
    let sealed = s.master.seal_name(id, name).unwrap().to_bytes();
    api.create_file(id, None, sealed, true).await.unwrap();
    id
}

async fn sync(
    s: &Stack,
    root: Uuid,
    local: &Path,
    journal: &Path,
    device: &str,
) -> nntdrive_sync::SyncReport {
    let mut remote = HttpRemote::new(api(s), s.master.clone(), root);
    let journal = Journal::open(journal).await.unwrap();
    SyncEngine::new(device)
        .run_once(&mut remote, local, &journal, "2026-11-04T120000Z")
        .await
        .unwrap()
}

#[tokio::test]
async fn two_devices_sync_versions_conflicts_and_deletes() {
    let Some(s) = stack().await else { return };
    let api = api(&s);
    let root = make_root(&s, &api, "SyncRoot").await;

    let dir_a = tempfile::tempdir().unwrap();
    let dir_b = tempfile::tempdir().unwrap();
    let journals = tempfile::tempdir().unwrap();
    let ja = journals.path().join("a.sqlite");
    let jb = journals.path().join("b.sqlite");
    let file_a = dir_a.path().join("docs/report.txt");
    tokio::fs::create_dir_all(file_a.parent().unwrap())
        .await
        .unwrap();
    tokio::fs::write(&file_a, b"version one").await.unwrap();

    let r = sync(&s, root, dir_a.path(), &ja, "device-a").await;
    assert_eq!(r.uploaded, 1, "{r:?}");
    assert!(r.errors.is_empty(), "{r:?}");

    // Device B downloads.
    let r = sync(&s, root, dir_b.path(), &jb, "device-b").await;
    assert_eq!(r.downloaded, 1, "{r:?}");
    assert_eq!(
        tokio::fs::read(dir_b.path().join("docs/report.txt"))
            .await
            .unwrap(),
        b"version one"
    );

    // B edits, A pulls the new revision.
    tokio::fs::write(dir_b.path().join("docs/report.txt"), b"version two")
        .await
        .unwrap();
    let r = sync(&s, root, dir_b.path(), &jb, "device-b").await;
    assert_eq!(r.uploaded, 1, "{r:?}");
    let r = sync(&s, root, dir_a.path(), &ja, "device-a").await;
    assert_eq!(r.downloaded, 1, "{r:?}");
    assert_eq!(tokio::fs::read(&file_a).await.unwrap(), b"version two");

    // Concurrent offline edits: A uploads first, B must preserve both.
    tokio::fs::write(&file_a, b"offline A").await.unwrap();
    sync(&s, root, dir_a.path(), &ja, "device-a").await;
    tokio::fs::write(dir_b.path().join("docs/report.txt"), b"offline B")
        .await
        .unwrap();
    let r = sync(&s, root, dir_b.path(), &jb, "device-b").await;
    assert_eq!(r.conflicts, 1, "{r:?}");
    assert_eq!(
        tokio::fs::read(dir_b.path().join("docs/report.txt"))
            .await
            .unwrap(),
        b"offline A"
    );
    let conflict = dir_b
        .path()
        .join("docs/report (conflict device-b 2026-11-04T120000Z).txt");
    assert_eq!(tokio::fs::read(&conflict).await.unwrap(), b"offline B");

    // Delete on A propagates to B.
    tokio::fs::remove_file(&file_a).await.unwrap();
    let r = sync(&s, root, dir_a.path(), &ja, "device-a").await;
    assert_eq!(r.deleted_remote, 1, "{r:?}");
    let r = sync(&s, root, dir_b.path(), &jb, "device-b").await;
    assert!(r.deleted_local >= 1, "{r:?}");
    assert!(!dir_b.path().join("docs/report.txt").exists());
}

#[tokio::test]
async fn multiple_roots_are_independent() {
    let Some(s) = stack().await else { return };
    let api = api(&s);
    let root1 = make_root(&s, &api, "Photos").await;
    let root2 = make_root(&s, &api, "Work").await;
    assert_ne!(root1, root2);

    let d1 = tempfile::tempdir().unwrap();
    let d2 = tempfile::tempdir().unwrap();
    let journals = tempfile::tempdir().unwrap();
    tokio::fs::write(d1.path().join("a.txt"), b"a")
        .await
        .unwrap();
    tokio::fs::write(d2.path().join("b.txt"), b"b")
        .await
        .unwrap();

    sync(
        &s,
        root1,
        d1.path(),
        &journals.path().join("j1.sqlite"),
        "d",
    )
    .await;
    sync(
        &s,
        root2,
        d2.path(),
        &journals.path().join("j2.sqlite"),
        "d",
    )
    .await;

    let files = api.list_files(Some(root1)).await.unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(api.list_files(Some(root2)).await.unwrap().len(), 1);
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}
