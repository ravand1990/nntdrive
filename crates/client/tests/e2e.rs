//! End-to-end: a real Flutter-facing client uploads and downloads through the
//! real Axum router, real PostgreSQL and the in-process NNTP server.

use nntdrive_backend::state::{AppState, ServerConfig};
use nntdrive_client::{download_file, upload_file, ApiClient};
use nntdrive_crypto::{derive_auth_verifier, DeviceKeypair, KeyFile};
use nntdrive_nntp::{MockConfig, MockNntpServer, NntpPool};
use nntdrive_storage::{FileManifest, TestDb};
use serde_json::json;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use uuid::Uuid;

struct Stack {
    _db: TestDb,
    _nntp: MockNntpServer,
    base_url: String,
    token: String,
    account_id: Uuid,
    master: nntdrive_crypto::MasterKey,
    _cache: tempfile::TempDir,
    _handle: tokio::task::JoinHandle<()>,
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
        secret_key: [3u8; 32],
        default_quota_bytes: None,
        health_check_interval_secs: 3600,
        retention_refresh_days: 30,
        retention_interval_secs: 3600,
    };
    let state = AppState::new(db.store.pool().clone(), pool, config).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let app = nntdrive_backend::app(state);
    let handle = tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .unwrap();
    });

    // Register through the real API.
    let account_id = Uuid::new_v4();
    let password = "correct horse battery staple";
    let (keyfile, master) = KeyFile::create(password, account_id).unwrap();
    let device = DeviceKeypair::generate();
    let verifier = derive_auth_verifier(password, account_id);
    let http = reqwest::Client::new();
    let res = http
        .post(format!("http://{addr}/api/v1/auth/register"))
        .json(&json!({
            "account_id": account_id,
            "email": "e2e@example.com",
            "verifier": verifier,
            "keyfile": keyfile,
            "device": {
                "id": Uuid::new_v4(),
                "name": "e2e",
                "platform": "test",
                "public_key": base64(&device.public().0),
            }
        }))
        .send()
        .await
        .unwrap();
    assert!(
        res.status().is_success(),
        "register failed: {}",
        res.status()
    );
    let body: serde_json::Value = res.json().await.unwrap();
    let token = body["token"].as_str().unwrap().to_string();

    Some(Stack {
        _db: db,
        _nntp: nntp,
        base_url: format!("http://{addr}"),
        token,
        account_id,
        master,
        _cache: cache,
        _handle: handle,
    })
}

fn base64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

async fn create_node(api: &ApiClient, master: &nntdrive_crypto::MasterKey, name: &str) -> Uuid {
    let id = Uuid::new_v4();
    let sealed = master.seal_name(id, name).unwrap().to_bytes();
    api.create_file(id, None, sealed, false).await.unwrap();
    id
}

#[tokio::test]
async fn client_upload_download_and_dedupe_through_real_api() {
    let Some(s) = stack().await else { return };
    let mut api = ApiClient::new(s.base_url.clone()).unwrap();
    api.set_token(s.token.clone());

    let dir = tempfile::tempdir().unwrap();
    let data: Vec<u8> = (0..900_000u32)
        .map(|i| (i.wrapping_mul(2654435761) >> 7) as u8)
        .collect();
    let src = dir.path().join("upload.bin");
    tokio::fs::write(&src, &data).await.unwrap();

    let file_id = create_node(&api, &s.master, "Report 2026.pdf").await;
    let revision = Uuid::new_v4();
    let result = upload_file(&api, &s.master, file_id, revision, None, &src)
        .await
        .unwrap();
    assert_eq!(result.size, data.len() as u64);
    assert!(result.chunks_new > 0);

    // Download and byte-compare.
    let dest = dir.path().join("download.bin");
    let downloaded = download_file(&api, &s.master, file_id, None, &dest)
        .await
        .unwrap();
    assert_eq!(downloaded.size, data.len() as u64);
    assert_eq!(tokio::fs::read(&dest).await.unwrap(), data);

    // The list endpoint exposes only sealed names; open them with the key.
    let files = api.list_files(None).await.unwrap();
    let listed = files.iter().find(|f| f.id == file_id).unwrap();
    let envelope = nntdrive_crypto::Envelope::from_bytes(&base64_decode(&listed.name_enc)).unwrap();
    assert_eq!(
        s.master.open_name(file_id, &envelope).unwrap(),
        "Report 2026.pdf"
    );

    // The sealed manifest survives the roundtrip.
    let (sealed, rev) = api.manifest(file_id, None).await.unwrap();
    assert_eq!(rev, revision);
    let env = nntdrive_crypto::Envelope::from_bytes(&sealed).unwrap();
    let manifest =
        FileManifest::from_bytes(&s.master.open_manifest(file_id, rev, &env).unwrap()).unwrap();
    manifest.validate().unwrap();

    // Upload the same bytes as another file: chunks must be reused.
    let file2 = create_node(&api, &s.master, "Copy.bin").await;
    let result2 = upload_file(&api, &s.master, file2, Uuid::new_v4(), None, &src)
        .await
        .unwrap();
    assert!(result2.chunks_reused > 0, "{result2:?}");
    assert_eq!(result2.chunks_new, 0);

    // A new version of the first file, with ancestry, keeps the old revision.
    let mut changed = data.clone();
    changed.extend_from_slice(b"second revision");
    let src2 = dir.path().join("upload-v2.bin");
    tokio::fs::write(&src2, &changed).await.unwrap();
    let revision2 = Uuid::new_v4();
    let up2 = upload_file(&api, &s.master, file_id, revision2, Some(revision), &src2)
        .await
        .unwrap();
    assert_eq!(up2.size, changed.len() as u64);
    let versions = api.versions(file_id).await.unwrap();
    assert_eq!(versions.len(), 2);
    let dest2 = dir.path().join("download-v2.bin");
    download_file(&api, &s.master, file_id, None, &dest2)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&dest2).await.unwrap(), changed);
    let dest1 = dir.path().join("download-v1.bin");
    download_file(&api, &s.master, file_id, Some(revision), &dest1)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&dest1).await.unwrap(), data);

    // Unauthorized access fails.
    let mut anon = ApiClient::new(s.base_url.clone()).unwrap();
    anon.set_token("not-a-token");
    assert!(anon.manifest(file_id, None).await.is_err());

    // The account's plaintext never reached the NNTP store.
    for id in s._nntp.store.article_ids().await {
        let raw = s._nntp.store.raw_article(&id).await.unwrap();
        assert!(!raw.windows(8).any(|w| w == b"Report 2"));
    }
    let _ = s.account_id;
    let _ = Path::new("");
}

fn base64_decode(s: &str) -> Vec<u8> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(s).unwrap()
}
