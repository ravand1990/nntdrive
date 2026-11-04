//! Executes one reconciliation round against a remote backend.
//!
//! The engine is transport-agnostic: the desktop/mobile client adapts its API
//! client to [`Remote`], while tests use an in-memory implementation.

use crate::journal::Journal;
use crate::reconcile::{self, Action, BaselineEntry, RemoteEntry};
use crate::scanner::{self, ScanOptions};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("i/o error: {0}")]
    Io(#[from] std::io::Error),
    #[error("journal error: {0}")]
    Journal(#[from] crate::journal::JournalError),
    #[error("remote error: {0}")]
    Remote(String),
    #[error("unsafe path: {0}")]
    UnsafePath(String),
}

pub type Result<T> = std::result::Result<T, SyncError>;

/// Transport used by the sync engine. Implementations must make uploads
/// idempotent for a given `(path, base_revision, content)` when possible.
#[allow(async_fn_in_trait)]
pub trait Remote {
    async fn snapshot(&mut self) -> Result<Vec<RemoteEntry>>;
    async fn upload(
        &mut self,
        path: &str,
        source: &std::path::Path,
        base_revision: Option<Uuid>,
    ) -> Result<RemoteEntry>;
    async fn download(
        &mut self,
        path: &str,
        revision: Uuid,
        destination: &std::path::Path,
    ) -> Result<()>;
    async fn delete(&mut self, path: &str) -> Result<()>;
    async fn mkdir(&mut self, path: &str) -> Result<()>;
    async fn move_path(&mut self, from: &str, to: &str) -> Result<()>;
}

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct SyncReport {
    pub uploaded: usize,
    pub downloaded: usize,
    pub created_dirs: usize,
    pub deleted_local: usize,
    pub deleted_remote: usize,
    pub moved: usize,
    pub conflicts: usize,
    pub downloaded_bytes: u64,
    pub uploaded_bytes: u64,
    pub skipped: Vec<(String, String)>,
    pub errors: Vec<(String, String)>,
}

pub struct SyncEngine {
    pub device_name: String,
    pub scan_options: ScanOptions,
    /// Relative paths excluded from syncing (selective sync).
    pub excluded_paths: Vec<String>,
}

impl SyncEngine {
    pub fn new(device_name: impl Into<String>) -> Self {
        Self {
            device_name: device_name.into(),
            scan_options: ScanOptions::default(),
            excluded_paths: Vec::new(),
        }
    }

    pub fn with_exclusions(mut self, paths: Vec<String>) -> Self {
        self.excluded_paths = paths;
        self
    }

    fn is_excluded(&self, path: &str) -> bool {
        let mut opts = self.scan_options.clone();
        opts.excluded_paths = self.excluded_paths.clone();
        opts.is_excluded(path)
    }

    /// Scans, reconciles and applies changes. `now` is a human-readable stamp
    /// used in conflict filenames (ISO-8601 recommended).
    pub async fn run_once<R: Remote>(
        &self,
        remote: &mut R,
        root: &Path,
        journal: &Journal,
        now: &str,
    ) -> Result<SyncReport> {
        let mut baseline = journal.load().await?;
        // Excluded paths are ignored entirely, including their baseline entries:
        // treating them as deleted would drop history and cause conflicts when
        // they are re-enabled.
        baseline.retain(|_, entry| !self.is_excluded(&entry.path));
        let previous: HashMap<String, scanner::ScannedEntry> = baseline
            .values()
            .filter(|b| !b.deleted)
            .map(|b| {
                (
                    b.path.clone(),
                    scanner::ScannedEntry {
                        path: b.path.clone(),
                        is_dir: b.is_dir,
                        size: b.size,
                        mtime_ms: 0, // force hash reuse only via matching size/hash below
                        content_hash: b.content_hash.clone(),
                        read_only: false,
                    },
                )
            })
            .collect();
        let root = root.to_path_buf();
        let scan_root = root.clone();
        let mut opts = self.scan_options.clone();
        opts.excluded_paths = self.excluded_paths.clone();
        let scan = tokio::task::spawn_blocking(move || scanner::scan(&scan_root, &opts, &previous))
            .await
            .map_err(|e| SyncError::Remote(format!("scan task failed: {e}")))??;

        let local_changes = reconcile::detect_local(&baseline, &scan.entries);
        let remote_entries = remote.snapshot().await?;
        let remote_entries: Vec<_> = remote_entries
            .into_iter()
            .filter(|e| !self.is_excluded(&e.path))
            .collect();
        let remote_changes = reconcile::detect_remote(&baseline, &remote_entries);
        let actions = reconcile::reconcile(
            &baseline,
            &local_changes,
            &remote_changes,
            &self.device_name,
            now,
        );
        if std::env::var("NNTDRIVE_SYNC_DEBUG").is_ok() {
            eprintln!("sync baseline: {:#?}", baseline);
            eprintln!("sync actions: {actions:#?}");
        }

        let mut report = SyncReport {
            skipped: scan.skipped.clone(),
            ..Default::default()
        };
        for (a, b) in &scan.case_collisions {
            report
                .errors
                .push((b.clone(), format!("case-only collision with '{a}'")));
        }
        // Case collisions block the affected paths but not unrelated files.
        let blocked: std::collections::HashSet<&str> = scan
            .case_collisions
            .iter()
            .flat_map(|(a, b)| [a.as_str(), b.as_str()])
            .collect();

        for action in actions {
            if let Action::Upload { path, .. } = &action {
                if blocked.contains(path.as_str()) {
                    continue;
                }
            }
            if let Action::Download { path, .. } = &action {
                if blocked.contains(path.as_str()) {
                    continue;
                }
            }
            let label = action_label(&action);
            if let Err(e) = self
                .apply(remote, root.as_path(), journal, action, now, &mut report)
                .await
            {
                report.errors.push((label, e.to_string()));
            }
        }

        // Directories are tracked as baseline entries even when they produced
        // no action, so a folder present on both sides is not re-detected as a
        // conflict on every run.
        for entry in scan.entries.iter().filter(|e| e.is_dir) {
            let local = local_path(root.as_path(), &entry.path)?;
            if tokio::fs::metadata(&local)
                .await
                .map(|m| m.is_dir())
                .unwrap_or(false)
            {
                journal
                    .upsert(&BaselineEntry {
                        path: entry.path.clone(),
                        is_dir: true,
                        size: 0,
                        content_hash: None,
                        revision: None,
                        deleted: false,
                    })
                    .await?;
            }
        }
        Ok(report)
    }

    #[allow(clippy::too_many_arguments)]
    async fn apply<R: Remote>(
        &self,
        remote: &mut R,
        root: &Path,
        journal: &Journal,
        action: Action,
        _now: &str,
        report: &mut SyncReport,
    ) -> Result<()> {
        match action {
            Action::Upload {
                path,
                base_revision,
            } => {
                let local = local_path(root, &path)?;
                let size = tokio::fs::metadata(&local).await?.len();
                let entry = remote.upload(&path, &local, base_revision).await?;
                let hash = tokio::task::spawn_blocking({
                    let local = local.clone();
                    move || scanner::hash_file(&local)
                })
                .await
                .map_err(|e| SyncError::Remote(format!("hash task failed: {e}")))??;
                journal
                    .upsert(&BaselineEntry {
                        path,
                        is_dir: false,
                        size,
                        content_hash: Some(hash),
                        revision: entry.revision,
                        deleted: false,
                    })
                    .await?;
                report.uploaded += 1;
                report.uploaded_bytes += size;
            }
            Action::Download { path, revision } => {
                let rev = revision.ok_or_else(|| SyncError::Remote("missing revision".into()))?;
                let dest = local_path(root, &path)?;
                let (size, hash) = materialize_download(remote, &path, rev, &dest).await?;
                journal
                    .upsert(&BaselineEntry {
                        path,
                        is_dir: false,
                        size,
                        content_hash: Some(hash),
                        revision: Some(rev),
                        deleted: false,
                    })
                    .await?;
                report.downloaded += 1;
                report.downloaded_bytes += size;
            }
            Action::DeleteRemote {
                path,
                base_revision,
            } => {
                let _ = base_revision;
                remote.delete(&path).await?;
                journal.remove(&path).await?;
                report.deleted_remote += 1;
            }
            Action::DeleteLocal { path } => {
                let p = local_path(root, &path)?;
                match tokio::fs::remove_file(&p).await {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) if e.kind() == std::io::ErrorKind::IsADirectory => {
                        // Remove empty directories only; never recursively delete
                        // local content that a remote deletion may not cover.
                        match tokio::fs::remove_dir(&p).await {
                            Ok(()) => {}
                            Err(e)
                                if matches!(
                                    e.kind(),
                                    std::io::ErrorKind::NotFound
                                        | std::io::ErrorKind::DirectoryNotEmpty
                                ) => {}
                            Err(e) => return Err(e.into()),
                        }
                    }
                    Err(e) => return Err(e.into()),
                }
                journal.remove(&path).await?;
                report.deleted_local += 1;
            }
            Action::CreateLocalDir { path } => {
                let p = local_path(root, &path)?;
                tokio::fs::create_dir_all(&p).await?;
                journal
                    .upsert(&BaselineEntry {
                        path,
                        is_dir: true,
                        size: 0,
                        content_hash: None,
                        revision: None,
                        deleted: false,
                    })
                    .await?;
                report.created_dirs += 1;
            }
            Action::CreateRemoteDir { path } => {
                remote.mkdir(&path).await?;
                journal
                    .upsert(&BaselineEntry {
                        path,
                        is_dir: true,
                        size: 0,
                        content_hash: None,
                        revision: None,
                        deleted: false,
                    })
                    .await?;
                report.created_dirs += 1;
            }
            Action::RenameLocal { from, to } => {
                let src = local_path(root, &from)?;
                let dst = local_path(root, &to)?;
                if let Some(parent) = dst.parent() {
                    tokio::fs::create_dir_all(parent).await?;
                }
                tokio::fs::rename(&src, &dst).await?;
                let mut base = journal
                    .load()
                    .await?
                    .remove(&from)
                    .unwrap_or(BaselineEntry {
                        path: from.clone(),
                        ..Default::default()
                    });
                journal.remove(&from).await?;
                base.path = to;
                journal.upsert(&base).await?;
                report.moved += 1;
            }
            Action::MoveRemote { from, to } => {
                remote.move_path(&from, &to).await?;
                let mut base = journal
                    .load()
                    .await?
                    .remove(&from)
                    .unwrap_or(BaselineEntry {
                        path: from.clone(),
                        ..Default::default()
                    });
                journal.remove(&from).await?;
                base.path = to;
                journal.upsert(&base).await?;
                report.moved += 1;
            }
            Action::Conflict {
                path,
                local_copy,
                remote_revision,
            } => {
                let original = local_path(root, &path)?;
                let copy = local_path(root, &local_copy)?;
                if copy.exists() {
                    return Err(SyncError::Remote(format!(
                        "conflict copy already exists: {local_copy}"
                    )));
                }
                // Preserve local content under the conflict name, then take the
                // remote revision at the original path.
                tokio::fs::rename(&original, &copy).await?;
                let rev = remote_revision
                    .ok_or_else(|| SyncError::Remote("conflict without remote revision".into()))?;
                let (remote_size, remote_hash) =
                    materialize_download(remote, &path, rev, &original).await?;
                journal
                    .upsert(&BaselineEntry {
                        path: path.clone(),
                        is_dir: false,
                        size: remote_size,
                        content_hash: Some(remote_hash),
                        revision: Some(rev),
                        deleted: false,
                    })
                    .await?;
                // Upload the preserved local version as a distinct file.
                let local_size = tokio::fs::metadata(&copy).await?.len();
                let entry = remote.upload(&local_copy, &copy, None).await?;
                let local_hash = tokio::task::spawn_blocking({
                    let copy = copy.clone();
                    move || scanner::hash_file(&copy)
                })
                .await
                .map_err(|e| SyncError::Remote(format!("hash task failed: {e}")))??;
                journal
                    .upsert(&BaselineEntry {
                        path: local_copy,
                        is_dir: false,
                        size: local_size,
                        content_hash: Some(local_hash),
                        revision: entry.revision,
                        deleted: false,
                    })
                    .await?;
                report.conflicts += 1;
                report.uploaded += 1;
                report.uploaded_bytes += local_size;
                report.downloaded += 1;
                report.downloaded_bytes += remote_size;
            }
        }
        Ok(())
    }
}

fn action_label(a: &Action) -> String {
    match a {
        Action::Upload { path, .. } => format!("upload {path}"),
        Action::Download { path, .. } => format!("download {path}"),
        Action::DeleteRemote { path, .. } => format!("delete remote {path}"),
        Action::DeleteLocal { path } => format!("delete local {path}"),
        Action::CreateLocalDir { path } => format!("create folder {path}"),
        Action::CreateRemoteDir { path } => format!("create remote folder {path}"),
        Action::RenameLocal { from, to } | Action::MoveRemote { from, to } => {
            format!("move {from} -> {to}")
        }
        Action::Conflict { path, .. } => format!("conflict {path}"),
    }
}

fn local_path(root: &Path, rel: &str) -> Result<PathBuf> {
    let clean = scanner::validate_relative_path(rel)
        .map_err(|e| SyncError::UnsafePath(format!("{rel}: {e}")))?;
    Ok(root.join(clean))
}

/// Downloads to a temporary file, hashes it, then atomically replaces the
/// destination. Anything interrupted leaves the previous local file intact.
async fn materialize_download<R: Remote>(
    remote: &mut R,
    path: &str,
    revision: Uuid,
    destination: &Path,
) -> Result<(u64, String)> {
    if let Some(parent) = destination.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let tmp = destination.with_extension(format!(
        "{}.nntdrive-part",
        destination
            .extension()
            .map(|e| e.to_string_lossy().to_string())
            .unwrap_or_default()
    ));
    let _ = tokio::fs::remove_file(&tmp).await;
    if let Err(e) = remote.download(path, revision, &tmp).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(e);
    }
    let size = tokio::fs::metadata(&tmp).await?.len();
    let hash = tokio::task::spawn_blocking({
        let tmp = tmp.clone();
        move || scanner::hash_file(&tmp)
    })
    .await
    .map_err(|e| SyncError::Remote(format!("hash task failed: {e}")))??;
    #[cfg(windows)]
    {
        if destination.exists() {
            let _ = tokio::fs::remove_file(destination).await;
        }
    }
    tokio::fs::rename(&tmp, destination).await?;
    Ok((size, hash))
}

/// Writes via a temporary file + rename so an interrupted download never leaves
/// a truncated file that looks synced.
pub async fn atomic_write(path: &Path, data: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let tmp = path.with_extension(format!(
        "{}.nntdrive-part",
        path.extension()
            .map(|e| e.to_string_lossy().to_string())
            .unwrap_or_default()
    ));
    tokio::fs::write(&tmp, data).await?;
    // Windows requires removing the destination before rename in some cases.
    #[cfg(windows)]
    {
        if path.exists() {
            let _ = tokio::fs::remove_file(path).await;
        }
    }
    tokio::fs::rename(&tmp, path).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reconcile::RemoteEntry;
    use std::sync::Arc;
    use tokio::sync::Mutex;

    #[derive(Default)]
    struct FakeState {
        files: HashMap<String, (Vec<u8>, Uuid)>,
        uploads: usize,
    }

    #[derive(Clone, Default)]
    struct FakeRemote(Arc<Mutex<FakeState>>);

    impl Remote for FakeRemote {
        async fn snapshot(&mut self) -> Result<Vec<RemoteEntry>> {
            let state = self.0.lock().await;
            Ok(state
                .files
                .iter()
                .map(|(path, (data, rev))| RemoteEntry {
                    path: path.clone(),
                    revision: Some(*rev),
                    parent_revision: None,
                    is_dir: false,
                    size: data.len() as u64,
                    content_hash: Some(blake3::hash(data).to_hex().to_string()),
                    deleted: false,
                })
                .collect())
        }

        async fn upload(
            &mut self,
            path: &str,
            source: &Path,
            _base_revision: Option<Uuid>,
        ) -> Result<RemoteEntry> {
            let content = tokio::fs::read(source).await?;
            let mut state = self.0.lock().await;
            state.uploads += 1;
            let rev = Uuid::new_v4();
            state.files.insert(path.to_string(), (content.clone(), rev));
            Ok(RemoteEntry {
                path: path.to_string(),
                revision: Some(rev),
                parent_revision: None,
                is_dir: false,
                size: content.len() as u64,
                content_hash: Some(blake3::hash(&content).to_hex().to_string()),
                deleted: false,
            })
        }

        async fn download(
            &mut self,
            path: &str,
            _revision: Uuid,
            destination: &Path,
        ) -> Result<()> {
            let data = self
                .0
                .lock()
                .await
                .files
                .get(path)
                .map(|(d, _)| d.clone())
                .ok_or_else(|| SyncError::Remote("not found".into()))?;
            if let Some(parent) = destination.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            tokio::fs::write(destination, data).await?;
            Ok(())
        }

        async fn delete(&mut self, path: &str) -> Result<()> {
            self.0.lock().await.files.remove(path);
            Ok(())
        }

        async fn mkdir(&mut self, _path: &str) -> Result<()> {
            Ok(())
        }

        async fn move_path(&mut self, from: &str, to: &str) -> Result<()> {
            let mut state = self.0.lock().await;
            if let Some(v) = state.files.remove(from) {
                state.files.insert(to.to_string(), v);
            }
            Ok(())
        }
    }

    async fn run(engine: &SyncEngine, remote: &mut FakeRemote, root: &Path, journal: &Journal) {
        let report = engine
            .run_once(remote, root, journal, "2026-11-04T101500Z")
            .await
            .unwrap();
        assert!(report.errors.is_empty(), "{:?}", report.errors);
    }

    #[tokio::test]
    async fn two_devices_roundtrip_create_modify_delete_and_conflict() {
        let remote = FakeRemote::default();
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let ja = Journal::in_memory().await.unwrap();
        let jb = Journal::in_memory().await.unwrap();
        let engine = SyncEngine::new("device");

        tokio::fs::write(dir_a.path().join("hello.txt"), b"from A")
            .await
            .unwrap();
        run(&engine, &mut remote.clone(), dir_a.path(), &ja).await;
        assert_eq!(remote.0.lock().await.files.len(), 1);

        // B pulls the file.
        run(&engine, &mut remote.clone(), dir_b.path(), &jb).await;
        assert_eq!(
            tokio::fs::read(dir_b.path().join("hello.txt"))
                .await
                .unwrap(),
            b"from A"
        );

        // B modifies and uploads.
        tokio::fs::write(dir_b.path().join("hello.txt"), b"edit by B")
            .await
            .unwrap();
        run(&engine, &mut remote.clone(), dir_b.path(), &jb).await;

        // A pulls B's edit.
        run(&engine, &mut remote.clone(), dir_a.path(), &ja).await;
        assert_eq!(
            tokio::fs::read(dir_a.path().join("hello.txt"))
                .await
                .unwrap(),
            b"edit by B"
        );

        // Concurrent offline edits: A edits and uploads first, B edits too.
        tokio::fs::write(dir_a.path().join("hello.txt"), b"offline A")
            .await
            .unwrap();
        run(&engine, &mut remote.clone(), dir_a.path(), &ja).await;
        tokio::fs::write(dir_b.path().join("hello.txt"), b"offline B")
            .await
            .unwrap();
        let report = engine
            .run_once(&mut remote.clone(), dir_b.path(), &jb, "2026-11-04T120000Z")
            .await
            .unwrap();
        assert_eq!(report.conflicts, 1, "{report:?}");
        assert_eq!(
            tokio::fs::read(dir_b.path().join("hello.txt"))
                .await
                .unwrap(),
            b"offline A"
        );
        let copy = dir_b
            .path()
            .join("hello (conflict device 2026-11-04T120000Z).txt");
        assert_eq!(tokio::fs::read(&copy).await.unwrap(), b"offline B");
        // Conflict copy is itself uploaded.
        assert_eq!(remote.0.lock().await.files.len(), 2);

        // Deletion propagates from A to B.
        tokio::fs::remove_file(dir_a.path().join("hello.txt"))
            .await
            .unwrap();
        run(&engine, &mut remote.clone(), dir_a.path(), &ja).await;
        run(&engine, &mut remote.clone(), dir_b.path(), &jb).await;
        assert!(!dir_b.path().join("hello.txt").exists());
    }

    #[tokio::test]
    async fn rename_propagates_as_a_remote_move() {
        let remote = FakeRemote::default();
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let ja = Journal::in_memory().await.unwrap();
        let jb = Journal::in_memory().await.unwrap();
        let engine = SyncEngine::new("dev");

        tokio::fs::create_dir_all(a.path().join("docs"))
            .await
            .unwrap();
        tokio::fs::write(a.path().join("docs/old.md"), b"content")
            .await
            .unwrap();
        run(&engine, &mut remote.clone(), a.path(), &ja).await;
        run(&engine, &mut remote.clone(), b.path(), &jb).await;

        tokio::fs::rename(a.path().join("docs/old.md"), a.path().join("docs/new.md"))
            .await
            .unwrap();
        run(&engine, &mut remote.clone(), a.path(), &ja).await;
        let state = remote.0.lock().await;
        assert!(state.files.contains_key("docs/new.md"));
        assert!(!state.files.contains_key("docs/old.md"));
        drop(state);

        run(&engine, &mut remote.clone(), b.path(), &jb).await;
        assert!(b.path().join("docs/new.md").exists());
        assert!(!b.path().join("docs/old.md").exists());
    }

    #[tokio::test]
    async fn unsafe_remote_paths_are_rejected() {
        let remote = FakeRemote::default();
        {
            let mut state = remote.0.lock().await;
            state.files.insert(
                "../../escape.txt".into(),
                (b"evil".to_vec(), Uuid::new_v4()),
            );
        }
        let root = tempfile::tempdir().unwrap();
        let j = Journal::in_memory().await.unwrap();
        let engine = SyncEngine::new("dev");
        let report = engine
            .run_once(&mut remote.clone(), root.path(), &j, "t")
            .await
            .unwrap();
        assert!(!report.errors.is_empty());
        assert!(!root.path().parent().unwrap().join("escape.txt").exists());
    }
}
