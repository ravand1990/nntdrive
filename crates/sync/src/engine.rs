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
    /// Stable identities from the most recent snapshot. Transports without
    /// directory IDs retain the conservative path-based behavior.
    fn directory_ids(&self) -> HashMap<String, Uuid> {
        HashMap::new()
    }
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
    /// Resolve an already synchronized conflict pair. Both sides must still
    /// match the journal and the freshly fetched remote revisions; stale review
    /// never overwrites an edit. Recovery files are ordinary encrypted synced
    /// files, not an untracked trash directory.
    #[allow(clippy::too_many_arguments)]
    pub async fn resolve_conflict<R: Remote>(
        &self,
        remote: &mut R,
        root: &Path,
        journal: &Journal,
        original: &str,
        copy: &str,
        choice: &str,
    ) -> Result<SyncReport> {
        let _operation = journal.acquire_operation().await?;
        let marker = copy.rfind(" (conflict ");
        let inferred = marker.and_then(|start| {
            copy[start..]
                .find(')')
                .map(|end| format!("{}{}", &copy[..start], &copy[start + end + 1..]))
        });
        if !matches!(choice, "mine" | "theirs" | "both")
            || original == copy
            || inferred.as_deref() != Some(original)
            || self.is_excluded(original)
            || self.is_excluded(copy)
        {
            return Err(SyncError::Remote("invalid conflict selection".into()));
        }
        let baseline = journal.load().await?;
        let snapshot = remote.snapshot().await?;
        for path in [original, copy] {
            let local = local_path(root, path)?;
            ensure_no_symlinks(root, path).await?;
            let base = baseline.get(path).ok_or_else(|| {
                SyncError::Remote("sync this conflict before resolving it".into())
            })?;
            let current = snapshot
                .iter()
                .find(|entry| entry.path == path && !entry.deleted && !entry.is_dir)
                .ok_or_else(|| {
                    SyncError::Remote("conflict changed remotely; sync and review again".into())
                })?;
            if base.is_dir
                || base.deleted
                || base.revision != current.revision
                || base.revision.is_none()
                || base.content_hash.as_deref() != Some(scanner::hash_file(&local)?.as_str())
            {
                return Err(SyncError::Remote(
                    "conflict changed; sync and review again".into(),
                ));
            }
        }
        let mut report = SyncReport::default();
        // Publish the other version as a separate recoverable file BEFORE
        // replacing the canonical version. A failed operation retains originals.
        if choice == "mine" {
            let recovery = format!("{original}.recovered-{}", Uuid::new_v4());
            let source = local_path(root, original)?;
            let dest = local_path(root, &recovery)?;
            tokio::fs::copy(&source, &dest).await?;
            self.apply(
                remote,
                root,
                journal,
                Action::Upload {
                    path: recovery,
                    base_revision: None,
                },
                "",
                &mut report,
            )
            .await?;
            let source = local_path(root, copy)?;
            let target = local_path(root, original)?;
            let temp = target.with_extension(format!("resolve-{}.nntdrive-part", Uuid::new_v4()));
            let size = tokio::fs::copy(&source, &temp).await?;
            let hash = scanner::hash_file(&temp)?;
            if baseline[copy].content_hash.as_deref() != Some(hash.as_str()) {
                return Err(SyncError::Remote(
                    "conflict copy changed during resolution; sync and review again".into(),
                ));
            }
            // Upload a stable staged copy, not a file an editor can modify
            // halfway through encryption. Keep originals if commit fails.
            let entry = remote
                .upload(original, &temp, baseline[original].revision)
                .await?;
            if baseline[original].content_hash.as_deref()
                != Some(scanner::hash_file(&target)?.as_str())
            {
                return Err(SyncError::Remote(
                    "original changed during resolution; sync and review again".into(),
                ));
            }
            #[cfg(windows)]
            tokio::fs::remove_file(&target).await?;
            tokio::fs::rename(&temp, &target).await?;
            journal
                .upsert(&BaselineEntry {
                    path: original.into(),
                    revision: entry.revision,
                    size,
                    content_hash: Some(hash),
                    is_dir: false,
                    deleted: false,
                })
                .await?;
            report.uploaded += 1;
            report.uploaded_bytes += size;
        }
        let suffix = if choice == "both" {
            "kept"
        } else {
            "recovered"
        };
        let resolved = format!("{original}.{suffix}-{}", Uuid::new_v4());
        // Move only the preserved version; no physical or logical deletion.
        remote.move_path(copy, &resolved).await?;
        tokio::fs::rename(local_path(root, copy)?, local_path(root, &resolved)?).await?;
        let mut base = baseline[copy].clone();
        base.path = resolved;
        journal.upsert(&base).await?;
        journal.remove(copy).await?;
        report.moved += 1;
        Ok(report)
    }

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
        let _operation = journal.acquire_operation().await?;
        // Finish or cancel an interrupted local rename before scanning. The
        // intent survives cancellation between filesystem and SQLite commits.
        if let Some((from, to)) = journal.pending_move().await? {
            let src = local_path(root, &from)?;
            let dst = local_path(root, &to)?;
            ensure_no_symlinks(root, &from).await?;
            ensure_no_symlinks(root, &to).await?;
            match (src.try_exists()?, dst.try_exists()?) {
                (false, true) if dst.is_dir() => journal.remap_subtree(&from, &to).await?,
                (true, false) => journal.cancel_move().await?,
                _ => {
                    return Err(SyncError::Remote(
                        "interrupted folder move needs local reconciliation".into(),
                    ))
                }
            }
        }
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
        let mut scan =
            tokio::task::spawn_blocking(move || scanner::scan(&scan_root, &opts, &previous))
                .await
                .map_err(|e| SyncError::Remote(format!("scan task failed: {e}")))??;

        let remote_entries = remote.snapshot().await?;
        let mut remote_entries: Vec<_> = remote_entries
            .into_iter()
            .filter(|e| !self.is_excluded(&e.path))
            .collect();
        // Resolve directory identity before three-way reconciliation. Remapping
        // both the scan and baseline prevents per-child deletes/downloads and
        // keeps offline edits attached to their original revisions.
        let directory_ids = remote.directory_ids();
        let mut known = journal.directory_ids().await?;
        let mut directories: Vec<_> = directory_ids.iter().collect();
        directories.sort_by_key(|(path, _)| (path.matches('/').count(), *path));
        let mut folder_moves = 0;
        let mut missing_sources: Vec<(String, String)> = Vec::new();
        for (to, id) in directories {
            if missing_sources
                .iter()
                .any(|(from, dest)| in_subtree(to, from) || in_subtree(to, dest))
            {
                continue;
            }
            let Some(from) = known
                .iter()
                .find_map(|(path, old_id)| (old_id == id && path != to).then(|| path.clone()))
            else {
                continue;
            };
            // Never move excluded local content, overwrite a destination, or
            // traverse symlink ancestors. Ambiguity stops the round rather than
            // degrading a known move into destructive delete/recreate actions.
            let touches_exclusion = self
                .excluded_paths
                .iter()
                .map(|path| path.trim().trim_matches('/').replace('\\', "/"))
                .any(|path| in_subtree(&path, &from) || in_subtree(&path, to))
                || self.is_excluded(&from)
                || self.is_excluded(to);
            if touches_exclusion {
                return Err(SyncError::Remote(
                    "folder move intersects selective-sync exclusions".into(),
                ));
            }
            let src = local_path(&root, &from)?;
            let dst = local_path(&root, to)?;
            ensure_no_symlinks(&root, &from).await?;
            ensure_no_symlinks(&root, to).await?;
            if !src.try_exists()? {
                missing_sources.push((from, to.clone()));
                continue;
            }
            if in_subtree(to, &from)
                || !scan.case_collisions.is_empty()
                || scan.entries.iter().any(|entry| {
                    !in_subtree(&entry.path, &from)
                        && in_subtree(&entry.path.to_lowercase(), &to.to_lowercase())
                })
                || tokio::fs::symlink_metadata(&dst).await.is_ok()
                || !tokio::fs::metadata(&src).await?.is_dir()
            {
                return Err(SyncError::Remote(
                    "folder move has a local path collision".into(),
                ));
            }
            if let Some(parent) = dst.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            // SQL conflicts must not strand the filesystem under the new name.
            journal.begin_move(&from, to).await?;
            tokio::fs::rename(&src, &dst).await?;
            if let Err(error) = journal.remap_subtree(&from, to).await {
                tokio::fs::rename(&dst, &src).await?;
                journal.cancel_move().await?;
                return Err(error.into());
            }
            for entry in &mut scan.entries {
                if in_subtree(&entry.path, &from) {
                    entry.path = format!("{to}{}", &entry.path[from.len()..]);
                }
            }
            known = journal.directory_ids().await?;
            folder_moves += 1;
        }
        if folder_moves > 0 {
            baseline = journal.load().await?;
            baseline.retain(|_, entry| !self.is_excluded(&entry.path));
        }
        for (from, to) in &missing_sources {
            baseline.retain(|path, _| !in_subtree(path, from) && !in_subtree(path, to));
            scan.entries
                .retain(|entry| !in_subtree(&entry.path, from) && !in_subtree(&entry.path, to));
            remote_entries
                .retain(|entry| !in_subtree(&entry.path, from) && !in_subtree(&entry.path, to));
        }
        let local_changes = reconcile::detect_local(&baseline, &scan.entries);
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
            moved: folder_moves,
            errors: missing_sources.iter().map(|(from, _)| (from.clone(), "remote folder moved but local source is missing; reconcile this subtree manually".into())).collect(),
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
        let synced = journal.load().await?;
        for (path, id) in remote.directory_ids() {
            if !self.is_excluded(&path)
                && !missing_sources
                    .iter()
                    .any(|(from, to)| in_subtree(&path, from) || in_subtree(&path, to))
                && synced
                    .get(&path)
                    .is_some_and(|entry| entry.is_dir && !entry.deleted)
                && tokio::fs::metadata(local_path(&root, &path)?).await.is_ok()
            {
                journal.remember_directory(&path, id).await?;
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

fn in_subtree(path: &str, root: &str) -> bool {
    path == root
        || path
            .strip_prefix(root)
            .is_some_and(|tail| tail.starts_with('/'))
}

async fn ensure_no_symlinks(root: &Path, relative: &str) -> Result<()> {
    let mut path = root.to_path_buf();
    for component in relative.split('/') {
        path.push(component);
        match tokio::fs::symlink_metadata(&path).await {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(SyncError::UnsafePath(relative.to_string()));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
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
        fail_upload: bool,
        fail_move: bool,
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
            if state.fail_upload {
                return Err(SyncError::Remote("injected upload failure".into()));
            }
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
            if state.fail_move {
                return Err(SyncError::Remote("injected move failure".into()));
            }
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
    async fn whole_operation_excludes_sync_and_conflict_resolution() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        let lease = journal.acquire_operation().await.unwrap();
        let mut remote = FakeRemote::default();
        let engine = SyncEngine::new("device");
        let sync = engine
            .run_once(&mut remote, dir.path(), &journal, "now")
            .await;
        assert!(
            matches!(sync, Err(SyncError::Journal(crate::JournalError::Busy))),
            "sync must reject the competing owner: {sync:?}"
        );
        let conflict = engine
            .resolve_conflict(
                &mut remote,
                dir.path(),
                &journal,
                "a",
                "a (conflict device now)",
                "both",
            )
            .await;
        assert!(
            matches!(conflict, Err(SyncError::Journal(crate::JournalError::Busy))),
            "conflict resolution must reject the competing owner: {conflict:?}"
        );
        assert_eq!(remote.0.lock().await.uploads, 0);
        assert!(journal.load().await.unwrap().is_empty());
        drop(lease);
        run(&engine, &mut remote, dir.path(), &journal).await;
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
    async fn explicit_resolution_preserves_versions_and_rejects_stale_review() {
        for choice in ["mine", "theirs", "both"] {
            let mut remote = FakeRemote::default();
            let a = tempfile::tempdir().unwrap();
            let b = tempfile::tempdir().unwrap();
            let ja = Journal::in_memory().await.unwrap();
            let jb = Journal::in_memory().await.unwrap();
            let engine = SyncEngine::new("dev");
            tokio::fs::write(a.path().join("f.txt"), b"base")
                .await
                .unwrap();
            run(&engine, &mut remote, a.path(), &ja).await;
            run(&engine, &mut remote, b.path(), &jb).await;
            tokio::fs::write(a.path().join("f.txt"), b"theirs")
                .await
                .unwrap();
            run(&engine, &mut remote, a.path(), &ja).await;
            tokio::fs::write(b.path().join("f.txt"), b"mine")
                .await
                .unwrap();
            run(&engine, &mut remote, b.path(), &jb).await;
            let copy = "f (conflict dev 2026-11-04T101500Z).txt";
            // Changes after the review baseline must not be overwritten.
            tokio::fs::write(b.path().join(copy), b"new edit")
                .await
                .unwrap();
            assert!(engine
                .resolve_conflict(&mut remote, b.path(), &jb, "f.txt", copy, choice)
                .await
                .is_err());
            assert_eq!(remote.0.lock().await.files.len(), 2);
            tokio::fs::write(b.path().join(copy), b"mine")
                .await
                .unwrap();
            let rev = remote.0.lock().await.files["f.txt"].1;
            remote.0.lock().await.files.get_mut("f.txt").unwrap().1 = Uuid::new_v4();
            assert!(engine
                .resolve_conflict(&mut remote, b.path(), &jb, "f.txt", copy, choice)
                .await
                .is_err());
            remote.0.lock().await.files.get_mut("f.txt").unwrap().1 = rev;
            engine
                .resolve_conflict(&mut remote, b.path(), &jb, "f.txt", copy, choice)
                .await
                .unwrap();
            let expected: &[u8] = if choice == "mine" { b"mine" } else { b"theirs" };
            assert_eq!(
                tokio::fs::read(b.path().join("f.txt")).await.unwrap(),
                expected
            );
            assert!(!b.path().join(copy).exists());
            run(&engine, &mut remote, a.path(), &ja).await;
            run(&engine, &mut remote, b.path(), &jb).await;
            let state = remote.0.lock().await;
            assert_eq!(state.files["f.txt"].0, expected);
            for bytes in [b"mine".as_slice(), b"theirs".as_slice()] {
                let (path, _) = state
                    .files
                    .iter()
                    .find(|(_, (data, _))| data == bytes)
                    .unwrap();
                assert_eq!(tokio::fs::read(a.path().join(path)).await.unwrap(), bytes);
                assert_eq!(tokio::fs::read(b.path().join(path)).await.unwrap(), bytes);
            }
            assert!(state.files.keys().all(|p| !p.contains(" (conflict ")));
        }
    }

    #[tokio::test]
    async fn resolution_failures_leave_both_versions_recoverable() {
        for failure in ["upload", "move"] {
            let mut remote = FakeRemote::default();
            let dir = tempfile::tempdir().unwrap();
            let journal = Journal::in_memory().await.unwrap();
            let engine = SyncEngine::new("dev");
            let copy = "f (conflict dev T).txt";
            tokio::fs::write(dir.path().join("f.txt"), b"theirs")
                .await
                .unwrap();
            tokio::fs::write(dir.path().join(copy), b"mine")
                .await
                .unwrap();
            run(&engine, &mut remote, dir.path(), &journal).await;
            {
                let mut state = remote.0.lock().await;
                state.fail_upload = failure == "upload";
                state.fail_move = failure == "move";
            }
            assert!(engine
                .resolve_conflict(&mut remote, dir.path(), &journal, "f.txt", copy, "mine")
                .await
                .is_err());
            assert_eq!(
                tokio::fs::read(dir.path().join(copy)).await.unwrap(),
                b"mine"
            );
            {
                let state = remote.0.lock().await;
                for version in [b"mine".as_slice(), b"theirs".as_slice()] {
                    assert!(state.files.values().any(|(data, _)| data == version));
                }
            }
            {
                let mut state = remote.0.lock().await;
                state.fail_upload = false;
                state.fail_move = false;
            }
            run(&engine, &mut remote, dir.path(), &journal).await;
        }
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
