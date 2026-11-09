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

#[path = "e2e/copy_tree.rs"]
mod copy_tree_tests;

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

    // Simulate an older client: real encrypted historical manifest with no
    // reference declaration blocks GC until an unlocked client backfills it.
    let legacy_file = create_node(&api, &s.master, "Legacy.bin").await;
    let legacy_rev = Uuid::new_v4();
    let mut legacy = manifest.clone();
    legacy.file_id = legacy_file;
    legacy.revision_id = legacy_rev;
    let sealed_legacy = s
        .master
        .seal_manifest(legacy_file, legacy_rev, &legacy.to_bytes())
        .unwrap()
        .to_bytes();
    api.commit(legacy_file, legacy_rev, None, legacy.size, &sealed_legacy)
        .await
        .unwrap();
    sqlx::query("UPDATE chunks SET created_at=now()-interval '10 days' WHERE account_id=$1")
        .bind(s.account_id)
        .execute(s._db.store.pool())
        .await
        .unwrap();
    assert!(s
        ._db
        .store
        .collect_orphan_chunks(s.account_id, 1, 1000)
        .await
        .is_err());
    let wrong = nntdrive_crypto::MasterKey::generate(s.account_id, 0);
    assert!(
        nntdrive_client::backfill_version_references(&api, &wrong, legacy_file, legacy_rev)
            .await
            .is_err()
    );
    assert!(s
        ._db
        .store
        .collect_orphan_chunks(s.account_id, 1, 1000)
        .await
        .is_err());
    // More than one page, and a logically deleted file: no hidden history may
    // be skipped just because it is not in the visible namespace/current tree.
    for _ in 0..200 {
        let mut historical = legacy.clone();
        historical.revision_id = Uuid::new_v4();
        let sealed = s
            .master
            .seal_manifest(legacy_file, historical.revision_id, &historical.to_bytes())
            .unwrap()
            .to_bytes();
        s._db
            .store
            .insert_version_with_references(
                s.account_id,
                legacy_file,
                &historical,
                &sealed,
                None,
                None,
                None,
            )
            .await
            .unwrap();
    }
    sqlx::query("UPDATE files SET deleted=true WHERE account_id=$1 AND id=$2")
        .bind(s.account_id)
        .bind(legacy_file)
        .execute(s._db.store.pool())
        .await
        .unwrap();
    let failed = nntdrive_client::backfill_reference_batch(&api, &wrong).await;
    assert_eq!(
        failed,
        serde_json::json!({"completed":0,"more":true,"failed":true})
    );
    let batch = nntdrive_client::backfill_reference_batch(&api, &s.master).await;
    assert_eq!(
        batch,
        serde_json::json!({"completed":200,"more":true,"failed":false})
    );
    assert_eq!(
        nntdrive_client::backfill_account_references(&api, &s.master)
            .await
            .unwrap(),
        1
    );
    let empty = nntdrive_client::backfill_reference_batch(&api, &s.master).await;
    assert_eq!(
        empty,
        serde_json::json!({"completed":0,"more":false,"failed":false})
    );
    assert_eq!(
        nntdrive_client::backfill_account_references(&api, &s.master)
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        s._db
            .store
            .collect_orphan_chunks(s.account_id, 1, 1000)
            .await
            .unwrap(),
        0
    );
    download_file(&api, &s.master, file_id, Some(revision), &dest1)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&dest1).await.unwrap(), data);
    download_file(&api, &s.master, legacy_file, Some(legacy_rev), &dest1)
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

#[tokio::test]
async fn guarded_copy_publication_retains_bytes_and_rejects_races() {
    let Some(s) = stack().await else { return };
    let mut api = ApiClient::new(s.base_url.clone()).unwrap();
    api.set_token(s.token.clone());
    let dir = tempfile::tempdir().unwrap();
    let input = dir.path().join("input");
    let output = dir.path().join("output");
    let data = b"guarded encrypted copy bytes";
    tokio::fs::write(&input, data).await.unwrap();
    let id = create_node(&api, &s.master, "Caf\u{e9}.txt").await;
    let revision = Uuid::new_v4();
    upload_file(&api, &s.master, id, revision, None, &input)
        .await
        .unwrap();
    let folder = Uuid::new_v4();
    api.create_file(
        folder,
        None,
        s.master
            .seal_name(folder, "destination")
            .unwrap()
            .to_bytes(),
        true,
    )
    .await
    .unwrap();
    let files = api.list_files(None).await.unwrap();
    let source = files.iter().find(|f| f.id == id).unwrap();
    // Real native crypto and HTTP; same-folder canonical collision fails closed.
    assert!(api
        .copy_file_checked(&s.master, source, None)
        .await
        .is_err());
    let (copied, copied_revision) = api
        .copy_file_checked(&s.master, source, Some(folder))
        .await
        .unwrap();
    assert_ne!(copied, id);
    assert_ne!(copied_revision, revision);
    download_file(&api, &s.master, copied, None, &output)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&output).await.unwrap(), data);
    assert!(api
        .copy_file_checked(&s.master, source, Some(folder))
        .await
        .is_err());
    // A canonically equivalent but differently encrypted spelling also collides.
    api.rename_file(
        copied,
        &base64(
            &s.master
                .seal_name(copied, "Cafe\u{301}.txt")
                .unwrap()
                .to_bytes(),
        ),
    )
    .await
    .unwrap();
    assert!(api
        .copy_file_checked(&s.master, source, Some(folder))
        .await
        .is_err());

    let (sealed, _) = api.manifest(id, Some(revision)).await.unwrap();
    let candidate = nntdrive_client::copy::prepare_file_copy(
        &s.master,
        id,
        revision,
        &base64_decode(&source.name_enc),
        &sealed,
    )
    .unwrap();
    let body = json!({"source_revision":revision,"source_parent_id":null,"source_name_enc":source.name_enc,
        "parent_id":folder,"siblings":[],"id":candidate.file_id,"revision_id":candidate.revision_id,
        "size":candidate.size,"name_enc":base64(&candidate.name_enc),"sealed_manifest":base64(&candidate.sealed_manifest),"chunk_ids":candidate.chunk_ids});
    let http = reqwest::Client::new();
    let url = format!("{}/api/v1/files/{id}/copy-checked", s.base_url);
    // Destination membership/name guards must reject a stale opaque snapshot.
    assert_eq!(
        http.post(&url)
            .bearer_auth(&s.token)
            .json(&body)
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    let siblings = api.list_files(Some(folder)).await.unwrap();
    let mut valid = body.clone();
    valid["siblings"] = json!(siblings
        .iter()
        .map(|f| json!({"id":f.id,"name_enc":f.name_enc}))
        .collect::<Vec<_>>());
    for (field, value, status) in [
        ("source_revision", json!(Uuid::new_v4()), 409),
        ("source_parent_id", json!(folder), 409),
        (
            "source_name_enc",
            json!(base64(
                &s.master.seal_name(id, "changed").unwrap().to_bytes()
            )),
            409,
        ),
        ("parent_id", json!(Uuid::new_v4()), 404),
        ("chunk_ids", json!([Uuid::new_v4()]), 400),
        ("chunk_ids", json!([]), 400),
        ("id", json!(copied), 409),
        ("revision_id", json!(copied_revision), 409),
        (
            "siblings",
            json!(vec![json!({"id":copied,"name_enc":source.name_enc}); 4097]),
            400,
        ),
    ] {
        let mut bad = valid.clone();
        bad[field] = value;
        assert_eq!(
            http.post(&url)
                .bearer_auth(&s.token)
                .json(&bad)
                .send()
                .await
                .unwrap()
                .status()
                .as_u16(),
            status,
            "field {field}"
        );
    }
    // All rejected transactions leave neither candidate nor references/events.
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM files WHERE id=$1")
        .bind(candidate.file_id)
        .fetch_one(s._db.store.pool())
        .await
        .unwrap();
    assert_eq!(count, 0);
    for lock in [
        "SELECT pg_advisory_xact_lock(hashtext($1))",
        "SELECT id FROM accounts WHERE id=$1::uuid FOR UPDATE",
    ] {
        let mut owner = s._db.store.pool().begin().await.unwrap();
        sqlx::query(lock)
            .bind(s.account_id.to_string())
            .execute(&mut *owner)
            .await
            .unwrap();
        let client = http.clone();
        let uri = url.clone();
        let token = s.token.clone();
        let payload = body.clone();
        let mut blocked = tokio::spawn(async move {
            client
                .post(uri)
                .bearer_auth(token)
                .json(&payload)
                .send()
                .await
                .unwrap()
        });
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(100), &mut blocked)
                .await
                .is_err()
        );
        owner.rollback().await.unwrap();
        assert_eq!(blocked.await.unwrap().status(), 409);
    }
    // Foreign source and nonexistent source have identical opaque responses.
    let foreign = s._db.create_account("foreign-copy@example.test").await;
    let foreign_file = s._db.create_file(foreign, None, vec![1]).await;
    for other in [foreign_file, Uuid::new_v4()] {
        assert_eq!(
            http.post(format!("{}/api/v1/files/{other}/copy-checked", s.base_url))
                .bearer_auth(&s.token)
                .json(&valid)
                .send()
                .await
                .unwrap()
                .status(),
            404
        );
    }
    // Foreign destination/chunks are rejected without publishing the candidate.
    let foreign_chunk = Uuid::new_v4();
    sqlx::query("INSERT INTO chunks(id,account_id,plaintext_hash,plaintext_len,ciphertext_len) VALUES($1,$2,$3,1,42)")
        .bind(foreign_chunk).bind(foreign).bind(vec![9u8;32]).execute(s._db.store.pool()).await.unwrap();
    for (field, value, status) in [
        ("parent_id", json!(foreign_file), 404),
        ("chunk_ids", json!([foreign_chunk]), 400),
    ] {
        let mut bad = valid.clone();
        bad[field] = value;
        assert_eq!(
            http.post(&url)
                .bearer_auth(&s.token)
                .json(&bad)
                .send()
                .await
                .unwrap()
                .status()
                .as_u16(),
            status
        );
    }
    // Empty files publish an explicitly complete empty reference set.
    let empty = create_node(&api, &s.master, "empty.txt").await;
    let empty_input = dir.path().join("empty");
    tokio::fs::write(&empty_input, b"").await.unwrap();
    upload_file(&api, &s.master, empty, Uuid::new_v4(), None, &empty_input)
        .await
        .unwrap();
    let empty_source = api
        .list_files(None)
        .await
        .unwrap()
        .into_iter()
        .find(|f| f.id == empty)
        .unwrap();
    let (empty_copy, _) = api
        .copy_file_checked(&s.master, &empty_source, Some(folder))
        .await
        .unwrap();
    download_file(&api, &s.master, empty_copy, None, &output)
        .await
        .unwrap();
    assert!(tokio::fs::read(&output).await.unwrap().is_empty());
    // Independent edits and source tombstone preserve the copy's old references.
    tokio::fs::write(&input, b"independent edit").await.unwrap();
    upload_file(&api, &s.master, id, Uuid::new_v4(), Some(revision), &input)
        .await
        .unwrap();
    api.delete_file(id).await.unwrap();
    assert_eq!(
        s._db
            .store
            .collect_orphan_chunks(s.account_id, 1, 100)
            .await
            .unwrap(),
        0
    );
    download_file(&api, &s.master, copied, Some(copied_revision), &output)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(output).await.unwrap(), data);
    let protected: i64=sqlx::query_scalar("SELECT count(*) FROM version_chunks vc JOIN file_versions v ON v.id=vc.version_id WHERE v.account_id=$1 AND v.file_id=$2 AND v.references_complete").bind(s.account_id).bind(copied).fetch_one(s._db.store.pool()).await.unwrap();
    assert!(protected > 0);
}

fn base64_decode(s: &str) -> Vec<u8> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(s).unwrap()
}
