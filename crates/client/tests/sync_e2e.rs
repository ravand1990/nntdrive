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

async fn sync_cached(
    s: &Stack,
    root: Uuid,
    local: &Path,
    journal: &Path,
    cache: &Path,
    device: &str,
) -> nntdrive_sync::SyncReport {
    let mut remote = HttpRemote::with_cache(api(s), s.master.clone(), root, cache.to_path_buf());
    let journal = Journal::open(journal).await.unwrap();
    SyncEngine::new(device)
        .run_once(&mut remote, local, &journal, "2026-11-04T120000Z")
        .await
        .unwrap()
}

async fn sync_excluded(
    s: &Stack,
    root: Uuid,
    local: &Path,
    journal: &Path,
    device: &str,
    excluded: Vec<String>,
) -> nntdrive_sync::SyncReport {
    let mut remote = HttpRemote::new(api(s), s.master.clone(), root);
    let journal = Journal::open(journal).await.unwrap();
    SyncEngine::new(device)
        .with_exclusions(excluded)
        .run_once(&mut remote, local, &journal, "2026-11-04T120000Z")
        .await
        .unwrap()
}

#[tokio::test]
async fn real_byte_progress_and_all_conflict_choices_converge() {
    let Some(s) = stack().await else { return };
    for choice in ["mine", "theirs", "both"] {
        let root = make_root(&s, &api(&s), choice).await;
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let journals = tempfile::tempdir().unwrap();
        let ja = journals.path().join("a.sqlite");
        let jb = journals.path().join("b.sqlite");
        // Exceeds FastCDC's maximum chunk size, guaranteeing incremental events.
        let data = vec![42u8; nntdrive_storage::ChunkConfig::default().max_size as usize + 123];
        tokio::fs::write(a.path().join("f.txt"), &data)
            .await
            .unwrap();
        tokio::fs::write(a.path().join("empty"), []).await.unwrap();
        let events = Arc::new(std::sync::Mutex::new(Vec::new()));
        for (dir, journal, direction) in [(a.path(), &ja, "upload"), (b.path(), &jb, "download")] {
            let observed = events.clone();
            let mut remote = HttpRemote::new(api(&s), s.master.clone(), root).with_progress(
                move |path, dir, done, total, complete| {
                    observed.lock().unwrap().push((
                        path.to_string(),
                        dir.to_string(),
                        done,
                        total,
                        complete,
                    ));
                },
            );
            let journal = Journal::open(journal).await.unwrap();
            let r = SyncEngine::new("dev")
                .run_once(&mut remote, dir, &journal, "T")
                .await
                .unwrap();
            assert!(r.errors.is_empty(), "{r:?}");
            let events = events.lock().unwrap();
            let file: Vec<_> = events
                .iter()
                .filter(|(p, d, _, _, _)| p == "f.txt" && d == direction)
                .collect();
            assert_eq!(file.first().unwrap().2, 0);
            assert_eq!(file.last().unwrap().2, data.len() as u64);
            assert!(file.last().unwrap().4);
            assert!(file.iter().any(|e| e.2 > 0 && e.2 < e.3 && !e.4));
            assert!(file.windows(2).all(|w| w[0].2 <= w[1].2));
            assert!(file.iter().all(|e| e.3 == data.len() as u64));
            assert!(events.iter().any(|(p, d, n, t, c)| p == "empty"
                && d == direction
                && *n == 0
                && *t == 0
                && *c));
        }
        tokio::fs::write(a.path().join("f.txt"), b"theirs")
            .await
            .unwrap();
        assert!(sync(&s, root, a.path(), &ja, "a").await.errors.is_empty());
        tokio::fs::write(b.path().join("f.txt"), b"mine")
            .await
            .unwrap();
        let r = sync(&s, root, b.path(), &jb, "b").await;
        assert!(r.errors.is_empty(), "{r:?}");
        assert_eq!(r.conflicts, 1);
        let copy = "f (conflict b 2026-11-04T120000Z).txt";
        let mut remote = HttpRemote::new(api(&s), s.master.clone(), root);
        let journal = Journal::open(&jb).await.unwrap();
        SyncEngine::new("b")
            .resolve_conflict(&mut remote, b.path(), &journal, "f.txt", copy, choice)
            .await
            .unwrap();
        assert!(sync(&s, root, a.path(), &ja, "a").await.errors.is_empty());
        assert!(sync(&s, root, b.path(), &jb, "b").await.errors.is_empty());
        let expected: &[u8] = if choice == "mine" { b"mine" } else { b"theirs" };
        for dir in [a.path(), b.path()] {
            assert_eq!(tokio::fs::read(dir.join("f.txt")).await.unwrap(), expected);
            let files: Vec<_> = std::fs::read_dir(dir)
                .unwrap()
                .map(|e| e.unwrap().path())
                .collect();
            assert!(files
                .iter()
                .all(|p| !p.to_string_lossy().contains(" (conflict ")));
            for version in [b"mine".as_slice(), b"theirs".as_slice()] {
                assert!(files.iter().any(|p| std::fs::read(p).unwrap() == version));
            }
        }
        assert_eq!(sync(&s, root, b.path(), &jb, "b").await.uploaded, 0);
    }
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

#[tokio::test]
async fn remote_rename_is_detected_through_cached_hashes() {
    let Some(s) = stack().await else { return };
    let api = api(&s);
    let root = make_root(&s, &api, "RenameRoot").await;
    let dir = tempfile::tempdir().unwrap();
    let dir_b = tempfile::tempdir().unwrap();
    let journals = tempfile::tempdir().unwrap();
    let ja = journals.path().join("a.sqlite");
    let jb = journals.path().join("b.sqlite");
    let ca = journals.path().join("a.hashes.json");
    let cb = journals.path().join("b.hashes.json");

    tokio::fs::write(dir.path().join("old.txt"), b"rename me")
        .await
        .unwrap();
    sync_cached(&s, root, dir.path(), &ja, &ca, "a").await;
    sync_cached(&s, root, dir_b.path(), &jb, &cb, "b").await;
    assert_eq!(
        tokio::fs::read(dir_b.path().join("old.txt")).await.unwrap(),
        b"rename me"
    );

    // Rename the remote file directly (simulating another client).
    let node = api.list_files(Some(root)).await.unwrap().remove(0);
    let sealed = s.master.seal_name(node.id, "new.txt").unwrap().to_bytes();
    api.rename_file(node.id, &b64(&sealed)).await.unwrap();

    let report = sync_cached(&s, root, dir_b.path(), &jb, &cb, "b").await;
    assert_eq!(report.moved, 1, "{report:?}");
    assert_eq!(report.downloaded, 0, "{report:?}");
    assert!(!dir_b.path().join("old.txt").exists());
    assert_eq!(
        tokio::fs::read(dir_b.path().join("new.txt")).await.unwrap(),
        b"rename me"
    );
}

#[tokio::test]
async fn excluded_paths_are_skipped_in_both_directions() {
    let Some(s) = stack().await else { return };
    let root = make_root(&s, &api(&s), "SelectiveRoot").await;
    let dir_a = tempfile::tempdir().unwrap();
    let dir_b = tempfile::tempdir().unwrap();
    let journals = tempfile::tempdir().unwrap();
    let ja = journals.path().join("a.sqlite");
    let jb = journals.path().join("b.sqlite");
    std::fs::create_dir_all(dir_a.path().join("keep")).unwrap();
    std::fs::create_dir_all(dir_a.path().join("skip")).unwrap();
    std::fs::write(dir_a.path().join("keep/a.txt"), b"a").unwrap();
    std::fs::write(dir_a.path().join("skip/local.txt"), b"local").unwrap();

    // Full first sync, so `skip/` has baseline entries before it is excluded.
    let report = sync(&s, root, dir_a.path(), &ja, "a").await;
    assert_eq!(report.uploaded, 2, "{report:?}");
    let report = sync(&s, root, dir_b.path(), &jb, "b").await;
    assert_eq!(report.downloaded, 2, "{report:?}");

    // Excluding the folder must not delete anything, and a remote addition
    // inside it must not be downloaded.
    std::fs::write(dir_b.path().join("skip/b.txt"), b"remote").unwrap();
    let report = sync(&s, root, dir_b.path(), &jb, "b").await;
    assert_eq!(report.uploaded, 1, "{report:?}");
    let report = sync_excluded(&s, root, dir_a.path(), &ja, "a", vec!["skip".into()]).await;
    assert_eq!(report.downloaded, 0, "{report:?}");
    assert!(!dir_a.path().join("skip/b.txt").exists());
    assert!(dir_a.path().join("skip/local.txt").exists());

    // Re-enabling the folder resumes normally, with no conflict copies.
    let report = sync(&s, root, dir_a.path(), &ja, "a").await;
    assert_eq!(report.conflicts, 0, "{report:?}");
    assert_eq!(report.downloaded, 1, "{report:?}");
    assert_eq!(
        std::fs::read(dir_a.path().join("skip/b.txt")).unwrap(),
        b"remote"
    );
    assert!(dir_a.path().join("skip/local.txt").exists());
    assert!(!dir_a.path().join("skip/local.txt (conflict").exists());
}

#[tokio::test]
async fn browser_equality_tracks_real_synced_journal_and_remote_revision() {
    let Some(s) = stack().await else { return };
    let api = api(&s);
    let root = make_root(&s, &api, "EqualityRoot").await;
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let journals = tempfile::tempdir().unwrap();
    let ja = journals.path().join("a.sqlite");
    let jb = journals.path().join("b.sqlite");
    std::fs::write(a.path().join("file"), b"same").unwrap();
    assert!(sync(&s, root, a.path(), &ja, "a").await.errors.is_empty());
    assert!(sync(&s, root, b.path(), &jb, "b").await.errors.is_empty());
    let node = api.list_files(Some(root)).await.unwrap().remove(0);
    let revision = node.current_version.unwrap();
    assert!(Journal::file_matches(&jb, b.path(), "file", revision, 4).await);
    // A same-sized local edit cannot inherit the previously synced indication.
    std::fs::write(b.path().join("file"), b"edit").unwrap();
    assert!(!Journal::file_matches(&jb, b.path(), "file", revision, 4).await);
    std::fs::write(b.path().join("file"), b"same").unwrap();
    std::fs::write(a.path().join("file"), b"next").unwrap();
    assert!(sync(&s, root, a.path(), &ja, "a").await.errors.is_empty());
    let changed = api.list_files(Some(root)).await.unwrap().remove(0);
    let next = changed.current_version.unwrap();
    assert_ne!(revision, next);
    assert!(!Journal::file_matches(&jb, b.path(), "file", next, 4).await);
    assert!(sync(&s, root, b.path(), &jb, "b").await.errors.is_empty());
    assert!(Journal::file_matches(&jb, b.path(), "file", next, 4).await);
}

#[tokio::test]
async fn remote_folder_rename_moves_subtree_without_transfers() {
    let Some(s) = stack().await else { return };
    let api = api(&s);
    let root = make_root(&s, &api, "FolderRenameRoot").await;
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let journals = tempfile::tempdir().unwrap();
    let ja = journals.path().join("a.sqlite");
    let jb = journals.path().join("b.sqlite");
    std::fs::create_dir_all(a.path().join("old/nested/empty")).unwrap();
    std::fs::write(a.path().join("old/nested/file.txt"), b"preserve me").unwrap();
    assert!(sync(&s, root, a.path(), &ja, "a").await.errors.is_empty());
    assert!(sync(&s, root, b.path(), &jb, "b").await.errors.is_empty());
    let node = api.list_files(Some(root)).await.unwrap().remove(0);
    let sealed = s.master.seal_name(node.id, "new").unwrap().to_bytes();
    api.rename_file(node.id, &b64(&sealed)).await.unwrap();
    let report_a = sync(&s, root, a.path(), &ja, "a").await;
    assert!(report_a.errors.is_empty(), "{report_a:?}");
    assert_eq!(report_a.moved, 1, "{report_a:?}");
    assert_eq!(
        report_a.deleted_local + report_a.downloaded + report_a.uploaded,
        0,
        "{report_a:?}"
    );
    let report = sync(&s, root, b.path(), &jb, "b").await;
    assert!(report.errors.is_empty(), "{report:?}");
    assert_eq!(report.moved, 1, "{report:?}");
    assert_eq!(report.downloaded, 0, "{report:?}");
    assert_eq!(report.uploaded, 0, "{report:?}");
    assert_eq!(report.deleted_local, 0, "{report:?}");
    assert_eq!(report.deleted_remote, 0, "{report:?}");
    assert_eq!(report.conflicts, 0, "{report:?}");
    assert!(!b.path().join("old").exists());
    assert!(b.path().join("new/nested/empty").is_dir());
    assert_eq!(
        std::fs::read(b.path().join("new/nested/file.txt")).unwrap(),
        b"preserve me"
    );
    let baseline = Journal::open(&jb).await.unwrap().load().await.unwrap();
    assert!(baseline.contains_key("new/nested/file.txt"));
    assert!(!baseline.keys().any(|p| p == "old" || p.starts_with("old/")));
    let report = sync(&s, root, b.path(), &jb, "b").await;
    assert!(report.errors.is_empty(), "{report:?}");
    assert_eq!(
        report.moved
            + report.uploaded
            + report.downloaded
            + report.deleted_local
            + report.deleted_remote
            + report.conflicts,
        0,
        "{report:?}"
    );
}

#[tokio::test]
async fn folder_move_recovers_interruption_and_preserves_offline_conflicts() {
    let Some(s) = stack().await else { return };
    let api = api(&s);
    let root = make_root(&s, &api, "RecoveryRoot").await;
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let journals = tempfile::tempdir().unwrap();
    let ja = journals.path().join("a.sqlite");
    let jb = journals.path().join("b.sqlite");
    std::fs::create_dir(a.path().join("old")).unwrap();
    std::fs::write(a.path().join("old/file.txt"), b"baseline").unwrap();
    sync(&s, root, a.path(), &ja, "a").await;
    sync(&s, root, b.path(), &jb, "b").await;
    std::fs::write(a.path().join("old/file.txt"), b"remote edit").unwrap();
    sync(&s, root, a.path(), &ja, "a").await;
    std::fs::write(b.path().join("old/file.txt"), b"offline edit").unwrap();
    let node = api.list_files(Some(root)).await.unwrap().remove(0);
    let sealed = s.master.seal_name(node.id, "new").unwrap().to_bytes();
    api.rename_file(node.id, &b64(&sealed)).await.unwrap();
    // Simulate cancellation after the filesystem rename, before SQLite remap.
    Journal::open(&jb)
        .await
        .unwrap()
        .begin_move("old", "new")
        .await
        .unwrap();
    std::fs::rename(b.path().join("old"), b.path().join("new")).unwrap();
    let report = sync(&s, root, b.path(), &jb, "b").await;
    assert!(report.errors.is_empty(), "{report:?}");
    assert_eq!(report.conflicts, 1, "{report:?}");
    assert_eq!(
        std::fs::read(b.path().join("new/file.txt")).unwrap(),
        b"remote edit"
    );
    assert_eq!(
        std::fs::read(
            b.path()
                .join("new/file (conflict b 2026-11-04T120000Z).txt")
        )
        .unwrap(),
        b"offline edit"
    );
    assert!(Journal::open(&jb)
        .await
        .unwrap()
        .pending_move()
        .await
        .unwrap()
        .is_none());
}

#[tokio::test]
async fn folder_move_blocks_exclusions_and_collisions_without_losing_content() {
    let Some(s) = stack().await else { return };
    let api = api(&s);
    let root = make_root(&s, &api, "SafetyRoot").await;
    let local = tempfile::tempdir().unwrap();
    let journals = tempfile::tempdir().unwrap();
    let jp = journals.path().join("journal.sqlite");
    std::fs::create_dir_all(local.path().join("old/private")).unwrap();
    std::fs::write(local.path().join("old/private/file"), b"preserve").unwrap();
    sync(&s, root, local.path(), &jp, "a").await;
    let node = api.list_files(Some(root)).await.unwrap().remove(0);
    let sealed = s.master.seal_name(node.id, "new").unwrap().to_bytes();
    api.rename_file(node.id, &b64(&sealed)).await.unwrap();
    let journal = Journal::open(&jp).await.unwrap();
    let mut remote = HttpRemote::new(api, s.master.clone(), root);
    let error = SyncEngine::new("a")
        .with_exclusions(vec![" old\\private ".into()])
        .run_once(&mut remote, local.path(), &journal, "now")
        .await
        .unwrap_err();
    assert!(error.to_string().contains("exclusions"), "{error}");
    assert!(local.path().join("old/private/file").exists());
    std::fs::create_dir(local.path().join("new")).unwrap();
    std::fs::write(local.path().join("new/local"), b"destination").unwrap();
    let error = SyncEngine::new("a")
        .run_once(&mut remote, local.path(), &journal, "now")
        .await
        .unwrap_err();
    assert!(error.to_string().contains("collision"), "{error}");
    assert_eq!(
        std::fs::read(local.path().join("new/local")).unwrap(),
        b"destination"
    );
    // A concurrent local rename needs manual subtree reconciliation but must
    // not block unrelated work or turn the remote move into child deletions.
    std::fs::rename(local.path().join("old"), local.path().join("saved")).unwrap();
    std::fs::write(local.path().join("unrelated.txt"), b"unrelated").unwrap();
    let report = SyncEngine::new("a")
        .run_once(&mut remote, local.path(), &journal, "now")
        .await
        .unwrap();
    assert_eq!(report.errors.len(), 1, "{report:?}");
    assert_eq!(report.item_errors.len(), 1);
    assert_eq!(report.item_errors[0].paths, vec!["old", "new"]);
    assert_eq!(report.item_errors[0].operation, "move_local");
    assert_eq!(report.item_errors[0].code, "missing_source");
    assert!(report.uploaded >= 1, "{report:?}");
    assert_eq!(
        report.deleted_remote + report.deleted_local,
        0,
        "{report:?}"
    );
    assert!(local.path().join("saved/private/file").exists());
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}
