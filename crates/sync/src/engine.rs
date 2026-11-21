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
    /// Snapshot that may report the remote paths it lists through `observer`,
    /// in bounded batches. Transports that cannot report progress keep the
    /// plain [`Remote::snapshot`] behavior.
    async fn snapshot_observed(
        &mut self,
        _observer: Option<SnapshotObserver>,
    ) -> Result<Vec<RemoteEntry>> {
        self.snapshot().await
    }
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

/// Client-local attribution, never sent to the backend. No raw diagnostics are
/// included: paths come from the action itself, not a formatted error message.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ItemError {
    pub paths: Vec<String>,
    pub operation: &'static str,
    pub code: &'static str,
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
    pub item_errors: Vec<ItemError>,
}

/// Client-local notification of the reconciliation plan for a running sync.
///
/// Each call carries one bounded batch of queued items and the complete number
/// of planned items. Observers are invoked before the first action is applied,
/// so a client can list every queued path instead of only the transfer that
/// happens to be active. The callback must not block and never receives file
/// content, names of other devices or account secrets beyond the local relative
/// paths the client already owns.
pub type PlanObserver = std::sync::Arc<dyn Fn(&[InspectItem], usize) + Send + Sync>;

/// Bound on plan notifications for one run: at most this many queued items are
/// reported. The observer still receives the complete total.
const PLAN_BATCH: usize = 256;
const PLAN_LIMIT: usize = 4096;

/// Client-local notification of local paths as the scan examines them.
///
/// Batches arrive in walk order before reconciliation, so a client can list
/// what the device is looking at instead of one opaque "sync is running" row.
/// The engine forwards at most [`SCAN_NOTIFY_LIMIT`] paths per run; the scan
/// itself still covers the whole tree.
pub type ScanObserver = scanner::ScanObserver;

/// Bound on how many scanned paths are forwarded to a [`ScanObserver`] per run.
const SCAN_NOTIFY_LIMIT: usize = 4096;

/// Client-local notification of remote paths as a snapshot lists them.
///
/// A snapshot lists the remote tree over many requests, so batches arrive while
/// the run is still comparing instead of after it finishes. Paths are the
/// relative, locally decrypted names the client already owns; nothing is sent
/// to the backend. The batch type is [`scanner::ScannedPath`] because it is
/// exactly a relative path plus a directory flag.
pub type SnapshotObserver = scanner::ScanObserver;

/// Bound on how many remote paths are forwarded to a [`SnapshotObserver`] per
/// run. The snapshot itself still covers the whole remote tree.
const SNAPSHOT_NOTIFY_LIMIT: usize = 4096;

/// Maximum number of remote paths in one [`SnapshotObserver`] batch.
pub const SNAPSHOT_PROGRESS_BATCH: usize = 64;

/// Forwards at most `limit` paths to `observer` across all of a run's batches.
fn capped_observer(observer: ScanObserver, limit: usize) -> ScanObserver {
    let reported = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    std::sync::Arc::new(move |paths: &[scanner::ScannedPath]| {
        let before = reported.fetch_add(paths.len(), std::sync::atomic::Ordering::Relaxed);
        if before >= limit {
            return;
        }
        let room = limit - before;
        if paths.len() <= room {
            observer(paths);
        } else {
            observer(&paths[..room]);
        }
    })
}

pub struct SyncEngine {
    pub device_name: String,
    pub scan_options: ScanOptions,
    /// Relative paths excluded from syncing (selective sync).
    pub excluded_paths: Vec<String>,
    plan_observer: Option<PlanObserver>,
    scan_observer: Option<ScanObserver>,
    snapshot_observer: Option<SnapshotObserver>,
}

/// One planned difference between this device and the account. `kind` is a
/// stable snake_case identifier; `path_to` carries the destination of a pending
/// move and `size` the local or remote content size when known.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct InspectItem {
    pub kind: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path_to: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    pub is_dir: bool,
}

/// Diagnostic-free local filesystem failure. Never includes an OS message or
/// a path; a failed scan cannot safely produce per-item reconciliation results.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FilesystemBlock {
    PermissionDenied,
    NotFound,
    NotADirectory,
    Io,
}

impl From<std::io::Error> for FilesystemBlock {
    fn from(error: std::io::Error) -> Self {
        match error.kind() {
            std::io::ErrorKind::PermissionDenied => Self::PermissionDenied,
            std::io::ErrorKind::NotFound => Self::NotFound,
            std::io::ErrorKind::NotADirectory => Self::NotADirectory,
            _ => Self::Io,
        }
    }
}

/// Read-only result: no upload, download, journal write or remote mutation.
/// `folder_moves_pending` means a plain comparison would be misleading until a
/// real sync applies the directory move, so no items are reported then.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct SyncInspection {
    /// Present only when the complete local scan failed. All plan lists are
    /// empty and the remote snapshot has not been requested.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filesystem_blocked: Option<FilesystemBlock>,
    pub items: Vec<InspectItem>,
    pub skipped: Vec<(String, String)>,
    pub case_collisions: Vec<(String, String)>,
    pub folder_moves_pending: bool,
    pub journal_available: bool,
    pub truncated: bool,
}

/// Upper bound on reported items so one pathological tree cannot exhaust RAM.
pub const INSPECT_ITEM_LIMIT: usize = 10_000;

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
            plan_observer: None,
            scan_observer: None,
            snapshot_observer: None,
        }
    }

    pub fn with_exclusions(mut self, paths: Vec<String>) -> Self {
        self.excluded_paths = paths;
        self
    }

    /// Report the bounded reconciliation plan before the first action is
    /// applied. Callers use this for a live "queued items" view; it never
    /// changes what the run does.
    pub fn with_plan_observer(mut self, observer: PlanObserver) -> Self {
        self.plan_observer = Some(observer);
        self
    }

    /// Report the bounded batches of local paths the scan examines. Callers use
    /// this for a live "scanning" view before any plan exists; it never changes
    /// what the scan or the run does.
    pub fn with_scan_observer(mut self, observer: ScanObserver) -> Self {
        self.scan_observer = Some(observer);
        self
    }

    /// Report the bounded batches of remote paths a snapshot lists while it is
    /// still running. Callers use this for a live "comparing" view after the
    /// scan and before the plan; it never changes what the snapshot or the run
    /// does, and excluded paths are never reported.
    pub fn with_snapshot_observer(mut self, observer: SnapshotObserver) -> Self {
        self.snapshot_observer = Some(observer);
        self
    }

    /// Wrap the caller's snapshot observer with selective-sync filtering and
    /// the per-run notification bound.
    fn limited_snapshot_observer(&self) -> Option<SnapshotObserver> {
        let observer = self.snapshot_observer.clone()?;
        let mut opts = self.scan_options.clone();
        opts.excluded_paths = self.excluded_paths.clone();
        let filtered: ScanObserver = std::sync::Arc::new(move |paths| {
            let kept: Vec<scanner::ScannedPath> = paths
                .iter()
                .filter(|path| !opts.is_excluded(&path.path))
                .cloned()
                .collect();
            if !kept.is_empty() {
                observer(&kept);
            }
        });
        Some(capped_observer(filtered, SNAPSHOT_NOTIFY_LIMIT))
    }

    fn is_excluded(&self, path: &str) -> bool {
        let mut opts = self.scan_options.clone();
        opts.excluded_paths = self.excluded_paths.clone();
        opts.is_excluded(path)
    }

    /// Emit the bounded reconciliation plan once, before the first action is
    /// applied. Only paths this device already owns are reported; nothing is
    /// invented for an unfinished scan or a failed comparison.
    fn notify_plan(
        &self,
        actions: &[Action],
        scanned: &[scanner::ScannedEntry],
        remote: &[RemoteEntry],
    ) {
        let Some(observer) = &self.plan_observer else {
            return;
        };
        let local: HashMap<&str, (u64, bool)> = scanned
            .iter()
            .map(|entry| (entry.path.as_str(), (entry.size, entry.is_dir)))
            .collect();
        let remote_state: HashMap<&str, (u64, bool)> = remote
            .iter()
            .filter(|entry| !entry.deleted)
            .map(|entry| (entry.path.as_str(), (entry.size, entry.is_dir)))
            .collect();
        let size_of = |path: &str| {
            local
                .get(path)
                .or_else(|| remote_state.get(path))
                .map(|(size, _)| *size)
        };
        let dir_of = |path: &str| {
            local
                .get(path)
                .or_else(|| remote_state.get(path))
                .map(|(_, is_dir)| *is_dir)
                .unwrap_or(false)
        };
        let items: Vec<InspectItem> = actions
            .iter()
            .map(|action| action_item(action, &size_of, &dir_of))
            .collect();
        let total = items.len();
        let mut batches = items
            .chunks(PLAN_BATCH)
            .take(PLAN_LIMIT / PLAN_BATCH)
            .peekable();
        if batches.peek().is_none() {
            // An empty plan is still evidence: the run has nothing queued left.
            observer(&[], total);
            return;
        }
        for batch in batches {
            observer(batch, total);
        }
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
        // The scan can examine far more paths than a client view needs, so the
        // observer is capped per run while the scan itself stays complete.
        let scan_observer = self
            .scan_observer
            .clone()
            .map(|observer| capped_observer(observer, SCAN_NOTIFY_LIMIT));
        let mut scan = tokio::task::spawn_blocking(move || {
            scanner::scan_with_observer(&scan_root, &opts, &previous, scan_observer.as_ref())
        })
        .await
        .map_err(|e| SyncError::Remote(format!("scan task failed: {e}")))??;

        // Listing the remote tree is the slow part of a large account, so the
        // snapshot reports the paths it has compared while it is still listing.
        let snapshot_observer = self.limited_snapshot_observer();
        let remote_entries = remote.snapshot_observed(snapshot_observer).await?;
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
        for (from, to) in &missing_sources {
            report.item_errors.push(ItemError {
                paths: vec![from.clone(), to.clone()],
                operation: "move_local",
                code: "missing_source",
            });
        }
        for (a, b) in &scan.case_collisions {
            report.item_errors.push(ItemError {
                paths: vec![a.clone(), b.clone()],
                operation: "scan",
                code: "case_collision",
            });
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

        // Paths that a running client may list as queued work. Blocked
        // case-collision paths are never attempted, so they stay out of it.
        let planned: Vec<Action> = actions
            .into_iter()
            .filter(|action| match action {
                Action::Upload { path, .. }
                | Action::Download { path, .. }
                | Action::AdoptRevision { path, .. } => !blocked.contains(path.as_str()),
                _ => true,
            })
            .collect();
        self.notify_plan(&planned, &scan.entries, &remote_entries);

        for action in planned {
            let label = action_label(&action);
            let mut item_error = action_item_error(&action);
            if let Action::AdoptRevision {
                path,
                revision,
                size,
                hash,
            } = &action
            {
                // detect_remote historically synthesizes IDs for unversioned
                // entries. Such an ID must never become an acknowledged base.
                if !remote_entries.iter().any(|entry| {
                    entry.path == *path
                        && !entry.deleted
                        && !entry.is_dir
                        && entry.revision == Some(*revision)
                        && entry.size == *size
                        && entry.content_hash.as_ref() == Some(hash)
                }) {
                    item_error.code = "unverified_revision";
                    report.item_errors.push(item_error);
                    report
                        .errors
                        .push((label, "remote revision is not verified".into()));
                    continue;
                }
            }
            if let Err(e) = self
                .apply(remote, root.as_path(), journal, action, now, &mut report)
                .await
            {
                item_error.code = match &e {
                    SyncError::Io(_) => "io",
                    SyncError::Journal(_) => "journal",
                    SyncError::Remote(_) => "remote",
                    SyncError::UnsafePath(_) => "unsafe_path",
                };
                report.item_errors.push(item_error);
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

    /// Computes the differences a real sync run would apply, without touching
    /// local files, the journal or the account. An interrupted or id-based
    /// folder move is reported as pending instead of a misleading file plan.
    /// The transport may refresh its own local content-hash cache while it
    /// builds the snapshot, exactly as a real sync would.
    pub async fn inspect<R: Remote>(
        &self,
        remote: &mut R,
        root: &Path,
        journal_path: &Path,
        now: &str,
    ) -> Result<SyncInspection> {
        self.inspect_with_limit(remote, root, journal_path, now, INSPECT_ITEM_LIMIT)
            .await
    }

    /// Complete, owned read-only overview snapshot. Comparison prerequisites
    /// finish before any page can be read; paging never rescans the filesystem
    /// or remote. Total snapshot RAM remains proportional to the whole tree.
    pub async fn inspect_overview<R: Remote>(
        &self,
        remote: &mut R,
        root: &Path,
        journal_path: &Path,
        now: &str,
    ) -> Result<crate::inspection_pages::InspectionCursor> {
        let inspection = self
            .inspect_with_limit(remote, root, journal_path, now, usize::MAX)
            .await?;
        Ok(crate::inspection_pages::InspectionCursor::new(inspection))
    }

    async fn inspect_with_limit<R: Remote>(
        &self,
        remote: &mut R,
        root: &Path,
        journal_path: &Path,
        now: &str,
        item_limit: usize,
    ) -> Result<SyncInspection> {
        let root_error = match tokio::fs::metadata(root).await {
            Ok(metadata) if metadata.is_dir() => None,
            Ok(_) => Some(FilesystemBlock::NotADirectory),
            Err(error) => Some(error.into()),
        };
        if let Some(blocked) = root_error {
            return Ok(SyncInspection {
                filesystem_blocked: Some(blocked),
                ..Default::default()
            });
        }
        let snapshot = Journal::inspect_read_only(journal_path).await?;
        let journal_available = snapshot.is_some();
        let snapshot = snapshot.unwrap_or_default();
        let mut baseline = snapshot.baseline;
        baseline.retain(|_, entry| !self.is_excluded(&entry.path));
        let previous: HashMap<String, scanner::ScannedEntry> = baseline
            .values()
            .filter(|entry| !entry.deleted)
            .map(|entry| {
                (
                    entry.path.clone(),
                    scanner::ScannedEntry {
                        path: entry.path.clone(),
                        is_dir: entry.is_dir,
                        size: entry.size,
                        mtime_ms: 0,
                        content_hash: entry.content_hash.clone(),
                        read_only: false,
                    },
                )
            })
            .collect();
        let scan_root = root.to_path_buf();
        let mut opts = self.scan_options.clone();
        opts.excluded_paths = self.excluded_paths.clone();
        let scan = tokio::task::spawn_blocking(move || scanner::scan(&scan_root, &opts, &previous))
            .await
            .map_err(|e| SyncError::Remote(format!("scan task failed: {e}")))?;
        let scan = match scan {
            Ok(scan) => scan,
            Err(error) => {
                return Ok(SyncInspection {
                    filesystem_blocked: Some(error.into()),
                    journal_available,
                    ..Default::default()
                });
            }
        };
        let remote_entries = remote.snapshot().await?;
        let remote_entries: Vec<_> = remote_entries
            .into_iter()
            .filter(|entry| !self.is_excluded(&entry.path))
            .collect();
        // A directory that keeps its remote identity but changed path is applied
        // by a real sync as a local rename. Without that step a plain comparison
        // would report a bogus delete/download pair.
        let remote_ids = remote.directory_ids();
        let folder_moves_pending = snapshot.pending_move.is_some()
            || remote_ids.iter().any(|(path, id)| {
                snapshot
                    .directory_ids
                    .iter()
                    .any(|(old_path, old_id)| old_id == id && old_path != path)
            });
        if folder_moves_pending {
            return Ok(SyncInspection {
                filesystem_blocked: None,
                skipped: scan.skipped,
                case_collisions: scan.case_collisions,
                folder_moves_pending: true,
                journal_available,
                truncated: false,
                items: Vec::new(),
            });
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
        let local: HashMap<&str, (u64, bool)> = scan
            .entries
            .iter()
            .map(|entry| (entry.path.as_str(), (entry.size, entry.is_dir)))
            .collect();
        let remote_state: HashMap<&str, (u64, bool)> = remote_entries
            .iter()
            .filter(|entry| !entry.deleted)
            .map(|entry| (entry.path.as_str(), (entry.size, entry.is_dir)))
            .collect();
        let mut items = Vec::new();
        let mut truncated = false;
        for action in &actions {
            if items.len() >= item_limit {
                truncated = true;
                break;
            }
            let size_of = |path: &str| {
                local
                    .get(path)
                    .or_else(|| remote_state.get(path))
                    .map(|(size, _)| *size)
            };
            let dir_of = |path: &str| {
                local
                    .get(path)
                    .or_else(|| remote_state.get(path))
                    .map(|(_, is_dir)| *is_dir)
                    .unwrap_or(false)
            };
            let item = action_item(action, &size_of, &dir_of);
            items.push(item);
        }
        Ok(SyncInspection {
            filesystem_blocked: None,
            items,
            skipped: scan.skipped,
            case_collisions: scan.case_collisions,
            folder_moves_pending: false,
            journal_available,
            truncated,
        })
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
            Action::AdoptRevision {
                path,
                revision,
                size,
                hash,
            } => {
                let local = local_path(root, &path)?;
                ensure_no_symlinks(root, &path).await?;
                if !tokio::fs::symlink_metadata(root).await?.is_dir() {
                    return Err(SyncError::UnsafePath(path));
                }
                let metadata = tokio::fs::symlink_metadata(&local).await?;
                if !metadata.is_file() || metadata.len() != size {
                    return Err(SyncError::Remote(
                        "local content changed before convergence".into(),
                    ));
                }
                let actual = tokio::task::spawn_blocking({
                    let local = local.clone();
                    move || scanner::hash_file(&local)
                })
                .await
                .map_err(|e| SyncError::Remote(format!("hash task failed: {e}")))??;
                ensure_no_symlinks(root, &path).await?;
                if actual != hash {
                    return Err(SyncError::Remote(
                        "local content changed before convergence".into(),
                    ));
                }
                journal
                    .upsert(&BaselineEntry {
                        path,
                        is_dir: false,
                        size,
                        content_hash: Some(hash),
                        revision: Some(revision),
                        deleted: false,
                    })
                    .await?;
                // No transferred bytes or completed upload/download to report.
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

/// Maps one planned action to the client-facing item shape. Shared by the
/// read-only comparison and the live plan notification so both describe a
/// queued path identically.
fn action_item(
    action: &Action,
    size_of: &dyn Fn(&str) -> Option<u64>,
    dir_of: &dyn Fn(&str) -> bool,
) -> InspectItem {
    match action {
        Action::Upload { path, .. } => InspectItem {
            kind: "upload".into(),
            path: path.clone(),
            path_to: None,
            size: size_of(path),
            is_dir: false,
        },
        Action::AdoptRevision { path, size, .. } => InspectItem {
            kind: "adopt_revision".into(),
            path: path.clone(),
            path_to: None,
            size: Some(*size),
            is_dir: false,
        },
        Action::Download { path, .. } => InspectItem {
            kind: "download".into(),
            path: path.clone(),
            path_to: None,
            size: size_of(path),
            is_dir: false,
        },
        Action::DeleteRemote { path, .. } => InspectItem {
            kind: "delete_remote".into(),
            path: path.clone(),
            path_to: None,
            size: size_of(path),
            is_dir: dir_of(path),
        },
        Action::DeleteLocal { path } => InspectItem {
            kind: "delete_local".into(),
            path: path.clone(),
            path_to: None,
            size: size_of(path),
            is_dir: dir_of(path),
        },
        Action::CreateLocalDir { path } => InspectItem {
            kind: "create_local_dir".into(),
            path: path.clone(),
            path_to: None,
            size: None,
            is_dir: true,
        },
        Action::CreateRemoteDir { path } => InspectItem {
            kind: "create_remote_dir".into(),
            path: path.clone(),
            path_to: None,
            size: None,
            is_dir: true,
        },
        Action::RenameLocal { from, to } => InspectItem {
            kind: "rename_local".into(),
            path: from.clone(),
            path_to: Some(to.clone()),
            size: size_of(from),
            is_dir: false,
        },
        Action::MoveRemote { from, to } => InspectItem {
            kind: "move_remote".into(),
            path: from.clone(),
            path_to: Some(to.clone()),
            size: size_of(from),
            is_dir: false,
        },
        Action::Conflict {
            path, local_copy, ..
        } => InspectItem {
            kind: "conflict".into(),
            path: path.clone(),
            path_to: Some(local_copy.clone()),
            size: size_of(path),
            is_dir: false,
        },
    }
}

fn action_item_error(a: &Action) -> ItemError {
    let (operation, paths) = match a {
        Action::Upload { path, .. } => ("upload", vec![path.clone()]),
        Action::AdoptRevision { path, .. } => ("adopt_revision", vec![path.clone()]),
        Action::Download { path, .. } => ("download", vec![path.clone()]),
        Action::DeleteRemote { path, .. } => ("delete_remote", vec![path.clone()]),
        Action::DeleteLocal { path } => ("delete_local", vec![path.clone()]),
        Action::CreateLocalDir { path } => ("mkdir_local", vec![path.clone()]),
        Action::CreateRemoteDir { path } => ("mkdir_remote", vec![path.clone()]),
        Action::RenameLocal { from, to } => ("move_local", vec![from.clone(), to.clone()]),
        Action::MoveRemote { from, to } => ("move_remote", vec![from.clone(), to.clone()]),
        Action::Conflict {
            path, local_copy, ..
        } => ("conflict", vec![path.clone(), local_copy.clone()]),
    };
    ItemError {
        paths,
        operation,
        code: "unknown",
    }
}

fn action_label(a: &Action) -> String {
    match a {
        Action::Upload { path, .. } => format!("upload {path}"),
        Action::AdoptRevision { path, .. } => format!("adopt revision {path}"),
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
        snapshots: usize,
        fail_snapshot: bool,
        fail_upload: bool,
        fail_move: bool,
        omit_revision: bool,
    }

    #[derive(Clone, Default)]
    struct FakeRemote(Arc<Mutex<FakeState>>);

    impl Remote for FakeRemote {
        async fn snapshot(&mut self) -> Result<Vec<RemoteEntry>> {
            let mut state = self.0.lock().await;
            state.snapshots += 1;
            if state.fail_snapshot {
                return Err(SyncError::Remote("private remote diagnostic".into()));
            }
            Ok(state
                .files
                .iter()
                .map(|(path, (data, rev))| RemoteEntry {
                    path: path.clone(),
                    revision: (!state.omit_revision).then_some(*rev),
                    parent_revision: None,
                    is_dir: false,
                    size: data.len() as u64,
                    content_hash: Some(blake3::hash(data).to_hex().to_string()),
                    deleted: false,
                })
                .collect())
        }

        async fn snapshot_observed(
            &mut self,
            observer: Option<SnapshotObserver>,
        ) -> Result<Vec<RemoteEntry>> {
            // Model a transport that lists the remote tree over many requests:
            // the paths leave before the complete snapshot is available.
            if let Some(observer) = observer {
                let mut paths: Vec<scanner::ScannedPath> = {
                    let state = self.0.lock().await;
                    state
                        .files
                        .keys()
                        .map(|path| scanner::ScannedPath {
                            path: path.clone(),
                            is_dir: false,
                        })
                        .collect()
                };
                paths.sort_by(|a, b| a.path.cmp(&b.path));
                if !paths.is_empty() {
                    observer(&paths);
                }
            }
            self.snapshot().await
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
    async fn identical_edits_record_revision_and_survive_restart() {
        // Both initial additions and concurrent edits must establish a baseline.
        for existing_baseline in [false, true] {
            let mut remote = FakeRemote::default();
            let a = tempfile::tempdir().unwrap();
            let b = tempfile::tempdir().unwrap();
            let state = tempfile::tempdir().unwrap();
            let journal_path = state.path().join("journal.sqlite");
            let ja = Journal::in_memory().await.unwrap();
            let jb = Journal::open(&journal_path).await.unwrap();
            let engine = SyncEngine::new("device");
            if existing_baseline {
                tokio::fs::write(a.path().join("f.txt"), b"base")
                    .await
                    .unwrap();
                run(&engine, &mut remote, a.path(), &ja).await;
                run(&engine, &mut remote, b.path(), &jb).await;
            }
            for dir in [&a, &b] {
                tokio::fs::write(dir.path().join("f.txt"), b"identical edit")
                    .await
                    .unwrap();
            }
            run(&engine, &mut remote, a.path(), &ja).await;
            let expected = ja.load().await.unwrap()["f.txt"].clone();
            let report = engine
                .run_once(&mut remote, b.path(), &jb, "T")
                .await
                .unwrap();
            assert!(report.errors.is_empty(), "{report:?}");
            assert_eq!(
                (report.uploaded, report.downloaded, report.conflicts),
                (0, 0, 0)
            );
            assert_eq!(jb.load().await.unwrap().get("f.txt"), Some(&expected));
            drop(jb);
            let jb = Journal::open(&journal_path).await.unwrap();
            assert_eq!(jb.load().await.unwrap().get("f.txt"), Some(&expected));
            let uploads = remote.0.lock().await.uploads;
            run(&engine, &mut remote, b.path(), &jb).await;
            assert_eq!(remote.0.lock().await.uploads, uploads);
            // A later edit on B is based on the adopted revision, not a false
            // conflict against the pre-convergence revision (or missing base).
            tokio::fs::write(b.path().join("f.txt"), b"later B edit")
                .await
                .unwrap();
            let report = engine
                .run_once(&mut remote, b.path(), &jb, "T2")
                .await
                .unwrap();
            assert!(report.errors.is_empty(), "{report:?}");
            assert_eq!(
                (report.uploaded, report.downloaded, report.conflicts),
                (1, 0, 0)
            );
            assert_eq!(remote.0.lock().await.files.len(), 1);
        }
    }

    #[tokio::test]
    async fn unversioned_snapshot_cannot_establish_convergence() {
        let root = tempfile::tempdir().unwrap();
        tokio::fs::write(root.path().join("f"), b"same")
            .await
            .unwrap();
        let journal = Journal::in_memory().await.unwrap();
        let mut remote = FakeRemote::default();
        {
            let mut state = remote.0.lock().await;
            state
                .files
                .insert("f".into(), (b"same".to_vec(), Uuid::new_v4()));
            state.omit_revision = true;
        }
        let report = SyncEngine::new("device")
            .run_once(&mut remote, root.path(), &journal, "T")
            .await
            .unwrap();
        assert!(journal.load().await.unwrap().is_empty());
        assert_eq!(report.errors.len(), 1);
        assert_eq!(report.item_errors[0].operation, "adopt_revision");
        assert_eq!(report.item_errors[0].code, "unverified_revision");
        assert_eq!(report.item_errors[0].paths, vec!["f"]);
        assert_eq!(
            (report.uploaded, report.downloaded, report.conflicts),
            (0, 0, 0)
        );
        remote.0.lock().await.omit_revision = false;
        run(
            &SyncEngine::new("device"),
            &mut remote,
            root.path(),
            &journal,
        )
        .await;
        assert!(journal.load().await.unwrap()["f"].revision.is_some());
    }

    #[tokio::test]
    async fn adoption_revalidates_content_and_preserves_baseline_on_failure() {
        let root = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        let base = BaselineEntry {
            path: "f".into(),
            revision: Some(Uuid::new_v4()),
            content_hash: Some("old".into()),
            size: 3,
            ..Default::default()
        };
        journal.upsert(&base).await.unwrap();
        let action = Action::AdoptRevision {
            path: "f".into(),
            revision: Uuid::new_v4(),
            size: 4,
            hash: blake3::hash(b"same").to_hex().to_string(),
        };
        let engine = SyncEngine::new("device");
        let mut remote = FakeRemote::default();
        // Changed content of the same size, changed size, missing file and type
        // replacement must not commit the planned remote revision.
        for content in [b"edit".as_slice(), b"long edit".as_slice()] {
            tokio::fs::write(root.path().join("f"), content)
                .await
                .unwrap();
            assert!(engine
                .apply(
                    &mut remote,
                    root.path(),
                    &journal,
                    action.clone(),
                    "T",
                    &mut SyncReport::default()
                )
                .await
                .is_err());
            assert_eq!(journal.load().await.unwrap()["f"], base);
        }
        tokio::fs::remove_file(root.path().join("f")).await.unwrap();
        assert!(engine
            .apply(
                &mut remote,
                root.path(),
                &journal,
                action.clone(),
                "T",
                &mut SyncReport::default()
            )
            .await
            .is_err());
        tokio::fs::create_dir(root.path().join("f")).await.unwrap();
        assert!(engine
            .apply(
                &mut remote,
                root.path(),
                &journal,
                action.clone(),
                "T",
                &mut SyncReport::default()
            )
            .await
            .is_err());
        assert_eq!(journal.load().await.unwrap()["f"], base);
        // Unconfined paths must also fail before touching journal state.
        let unsafe_action = Action::AdoptRevision {
            path: "../outside".into(),
            revision: Uuid::new_v4(),
            size: 0,
            hash: String::new(),
        };
        assert!(engine
            .apply(
                &mut remote,
                root.path(),
                &journal,
                unsafe_action,
                "T",
                &mut SyncReport::default()
            )
            .await
            .is_err());
        #[cfg(unix)]
        {
            let outside = tempfile::tempdir().unwrap();
            tokio::fs::write(outside.path().join("f"), b"same")
                .await
                .unwrap();
            tokio::fs::remove_dir(root.path().join("f")).await.unwrap();
            std::os::unix::fs::symlink(outside.path().join("f"), root.path().join("f")).unwrap();
            assert!(engine
                .apply(
                    &mut remote,
                    root.path(),
                    &journal,
                    action.clone(),
                    "T",
                    &mut SyncReport::default()
                )
                .await
                .is_err());
            std::os::unix::fs::symlink(outside.path(), root.path().join("linked-root")).unwrap();
            assert!(engine
                .apply(
                    &mut remote,
                    &root.path().join("linked-root"),
                    &journal,
                    action,
                    "T",
                    &mut SyncReport::default()
                )
                .await
                .is_err());
            assert_eq!(journal.load().await.unwrap()["f"], base);
        }
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

    #[test]
    fn structured_action_errors_include_all_involved_paths() {
        let from = "upload x -> y".to_string();
        let to = "nested/final.txt".to_string();
        let cases = [
            (
                Action::Upload {
                    path: from.clone(),
                    base_revision: None,
                },
                "upload",
                false,
            ),
            (
                Action::Download {
                    path: from.clone(),
                    revision: None,
                },
                "download",
                false,
            ),
            (
                Action::DeleteRemote {
                    path: from.clone(),
                    base_revision: None,
                },
                "delete_remote",
                false,
            ),
            (
                Action::DeleteLocal { path: from.clone() },
                "delete_local",
                false,
            ),
            (
                Action::CreateLocalDir { path: from.clone() },
                "mkdir_local",
                false,
            ),
            (
                Action::CreateRemoteDir { path: from.clone() },
                "mkdir_remote",
                false,
            ),
            (
                Action::RenameLocal {
                    from: from.clone(),
                    to: to.clone(),
                },
                "move_local",
                true,
            ),
            (
                Action::MoveRemote {
                    from: from.clone(),
                    to: to.clone(),
                },
                "move_remote",
                true,
            ),
            (
                Action::Conflict {
                    path: from.clone(),
                    local_copy: to.clone(),
                    remote_revision: None,
                },
                "conflict",
                true,
            ),
        ];
        for (action, operation, pair) in cases {
            let error = action_item_error(&action);
            assert_eq!(error.operation, operation);
            assert_eq!(
                error.paths,
                if pair {
                    vec![from.clone(), to.clone()]
                } else {
                    vec![from.clone()]
                }
            );
        }
    }

    #[tokio::test]
    async fn item_errors_preserve_exact_paths_without_diagnostic_parsing() {
        let mut remote = FakeRemote::default();
        let root = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        let engine = SyncEngine::new("dev");
        let path = "upload report -> final.txt";
        tokio::fs::write(root.path().join(path), b"keep me")
            .await
            .unwrap();
        remote.0.lock().await.fail_upload = true;
        let report = engine
            .run_once(&mut remote, root.path(), &journal, "t")
            .await
            .unwrap();
        let json = serde_json::to_value(&report).unwrap();
        assert_eq!(
            json["item_errors"],
            serde_json::json!([{
                "paths": [path], "operation": "upload", "code": "remote"
            }])
        );
        assert_eq!(report.errors.len(), 1); // Legacy diagnostics remain compatible.
        assert!(journal.load().await.unwrap().is_empty());
        remote.0.lock().await.fail_upload = false;
        let retried = engine
            .run_once(&mut remote, root.path(), &journal, "t")
            .await
            .unwrap();
        assert_eq!(
            serde_json::to_value(retried).unwrap()["item_errors"],
            serde_json::json!([])
        );
        assert_eq!(
            tokio::fs::read(root.path().join(path)).await.unwrap(),
            b"keep me"
        );
    }

    #[tokio::test]
    async fn case_collision_errors_identify_both_paths_without_messages() {
        let mut remote = FakeRemote::default();
        let root = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        tokio::fs::write(root.path().join("A.txt"), b"one")
            .await
            .unwrap();
        tokio::fs::write(root.path().join("a.txt"), b"two")
            .await
            .unwrap();
        let report = SyncEngine::new("dev")
            .run_once(&mut remote, root.path(), &journal, "t")
            .await
            .unwrap();
        assert_eq!(report.item_errors.len(), 1);
        let error = &report.item_errors[0];
        assert_eq!(error.operation, "scan");
        assert_eq!(error.code, "case_collision");
        let mut paths = error.paths.clone();
        paths.sort();
        assert_eq!(paths, vec!["A.txt", "a.txt"]);
        assert_eq!(report.uploaded, 0);
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

    #[tokio::test]
    async fn overview_pages_reach_every_action_after_one_complete_comparison() {
        let root = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let journal = state.path().join("never-created.sqlite");
        let mut remote = FakeRemote::default();
        for i in 0..20_017 {
            remote
                .0
                .lock()
                .await
                .files
                .insert(format!("file-{i:05}.txt"), (Vec::new(), Uuid::new_v4()));
        }
        let engine = SyncEngine::new("fixture");
        let legacy = engine
            .inspect(&mut remote, root.path(), &journal, "now")
            .await
            .unwrap();
        assert_eq!(legacy.items.len(), INSPECT_ITEM_LIMIT);
        assert!(legacy.truncated);
        let mut cursor = engine
            .inspect_overview(&mut remote, root.path(), &journal, "now")
            .await
            .unwrap();
        // Freeze proof: subsequent remote changes do not alter the owned result.
        remote.0.lock().await.files.clear();
        let mut seen = std::collections::HashSet::new();
        loop {
            let page = cursor.next_page(256).unwrap();
            assert!(page.items.len() <= 256);
            assert_eq!(page.totals.items, 20_017);
            for row in page.items {
                assert_eq!(row.item.kind, "download");
                assert!(seen.insert(row.item.path));
            }
            if page.done {
                break;
            }
        }
        assert_eq!(seen.len(), 20_017);
        let state = remote.0.lock().await;
        assert_eq!(
            state.snapshots, 2,
            "one legacy call plus one cursor construction, never per-page scans"
        );
        assert_eq!(state.uploads, 0);
        assert!(!journal.exists());
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }

    #[tokio::test]
    async fn inspect_invalid_roots_are_structured_and_do_not_create_journals() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("private-root");
        std::fs::write(&file, b"not a directory").unwrap();
        for (root, code) in [
            (dir.path().join("missing-private-root"), "not_found"),
            (file, "not_a_directory"),
        ] {
            let journal_path = dir.path().join("absent.sqlite");
            let mut remote = FakeRemote::default();
            let result = SyncEngine::new("device")
                .inspect(&mut remote, &root, &journal_path, "now")
                .await
                .expect("filesystem failures are structured inspection outcomes");
            let json = serde_json::to_value(result).unwrap();
            assert_eq!(json["filesystem_blocked"], code);
            assert_eq!(json["items"], serde_json::json!([]));
            assert_eq!(json["skipped"], serde_json::json!([]));
            assert!(!json.to_string().contains("private-root"));
            assert!(!journal_path.exists());
            assert_eq!(remote.0.lock().await.snapshots, 0);
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn inspect_unreadable_tree_is_blocked_before_reconciliation() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        use std::os::unix::process::CommandExt;
        let effective = std::fs::read_to_string("/proc/self/status")
            .unwrap()
            .lines()
            .find_map(|line| {
                line.strip_prefix("CapEff:")
                    .map(|v| u64::from_str_radix(v.trim(), 16).unwrap())
            })
            .unwrap();
        if std::fs::metadata("/proc/self").unwrap().uid() == 0 && effective & 0b110 != 0 {
            assert!(std::env::var_os("NNTDRIVE_INSPECT_PERMISSION_CHILD").is_none());
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "engine::tests::inspect_unreadable_tree_is_blocked_before_reconciliation",
                    "--nocapture",
                ])
                .env("NNTDRIVE_INSPECT_PERMISSION_CHILD", "1")
                .uid(65534)
                .gid(65534)
                .status()
                .unwrap();
            assert!(status.success());
            return;
        }
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            for blocked in ["", "nested", "nested/private-file.txt"] {
                let root = tempfile::tempdir().unwrap();
                let state = tempfile::tempdir().unwrap();
                let journal_path = state.path().join("journal.sqlite");
                std::fs::create_dir(root.path().join("nested")).unwrap();
                std::fs::write(root.path().join("nested/private-file.txt"), b"preserve").unwrap();
                let mut remote = FakeRemote::default();
                let engine = SyncEngine::new("device");
                let journal = Journal::open(&journal_path).await.unwrap();
                run(&engine, &mut remote, root.path(), &journal).await;
                let baseline = serde_json::to_value(journal.load().await.unwrap()).unwrap();
                let files = remote.0.lock().await.files.clone();
                let snapshots = remote.0.lock().await.snapshots;
                let denied = root.path().join(blocked);
                let permissions = std::fs::metadata(&denied).unwrap().permissions();
                std::fs::set_permissions(&denied, std::fs::Permissions::from_mode(0o0)).unwrap();
                let inspection = engine
                    .inspect(&mut remote, root.path(), &journal_path, "now")
                    .await;
                // Real synchronization must still fail closed, not reconcile a partial tree.
                let sync = engine
                    .run_once(&mut remote, root.path(), &journal, "now")
                    .await;
                std::fs::set_permissions(&denied, permissions).unwrap();
                let json =
                    serde_json::to_value(inspection.expect("structured filesystem block")).unwrap();
                assert_eq!(json["filesystem_blocked"], "permission_denied");
                assert_eq!(json["items"], serde_json::json!([]));
                assert_eq!(json["skipped"], serde_json::json!([]));
                assert!(!json.to_string().contains("private-file"));
                assert!(matches!(sync, Err(SyncError::Io(_))));
                assert_eq!(
                    baseline,
                    serde_json::to_value(journal.load().await.unwrap()).unwrap()
                );
                let after = remote.0.lock().await;
                assert_eq!(after.files, files);
                assert_eq!(after.uploads, 1);
                assert_eq!(after.snapshots, snapshots);
                drop(after);
                assert_eq!(
                    std::fs::read(root.path().join("nested/private-file.txt")).unwrap(),
                    b"preserve"
                );
            }
        });
    }

    #[tokio::test]
    async fn inspect_journal_and_remote_errors_are_not_filesystem_blocks() {
        let root = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let journal_path = state.path().join("broken.sqlite");
        std::fs::write(&journal_path, b"not sqlite").unwrap();
        let mut remote = FakeRemote::default();
        let engine = SyncEngine::new("device");
        assert!(matches!(
            engine
                .inspect(&mut remote, root.path(), &journal_path, "now")
                .await,
            Err(SyncError::Journal(_))
        ));
        assert_eq!(remote.0.lock().await.snapshots, 0);
        remote.0.lock().await.fail_snapshot = true;
        assert!(matches!(
            engine
                .inspect(
                    &mut remote,
                    root.path(),
                    &state.path().join("missing.sqlite"),
                    "now"
                )
                .await,
            Err(SyncError::Remote(_))
        ));
    }

    #[tokio::test]
    async fn inspect_plans_without_touching_local_or_remote_state() {
        let root = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let journal_path = state.path().join("journal.sqlite");
        std::fs::write(root.path().join("local.txt"), b"local data").unwrap();
        let mut remote = FakeRemote::default();
        remote.0.lock().await.files.insert(
            "remote.txt".into(),
            (b"remote data".to_vec(), Uuid::new_v4()),
        );
        let engine = SyncEngine::new("device");
        let inspection = engine
            .inspect(
                &mut remote,
                root.path(),
                &journal_path,
                "2026-11-13T000000Z",
            )
            .await
            .unwrap();
        assert!(!inspection.folder_moves_pending);
        assert!(!inspection.journal_available);
        assert!(!inspection.truncated);
        let kinds: Vec<(&str, &str)> = inspection
            .items
            .iter()
            .map(|item| (item.kind.as_str(), item.path.as_str()))
            .collect();
        assert!(kinds.contains(&("upload", "local.txt")), "{kinds:?}");
        assert!(kinds.contains(&("download", "remote.txt")), "{kinds:?}");
        // Nothing was applied and no journal was created by the inspection.
        assert!(!journal_path.exists());
        assert_eq!(remote.0.lock().await.uploads, 0);
        assert_eq!(
            std::fs::read(root.path().join("local.txt")).unwrap(),
            b"local data"
        );
        assert!(!root.path().join("remote.txt").exists());
    }

    #[tokio::test]
    async fn inspect_reflects_pending_changes_after_a_real_sync() {
        let root = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let journal_path = state.path().join("journal.sqlite");
        std::fs::write(root.path().join("note.txt"), b"v1").unwrap();
        let mut remote = FakeRemote::default();
        let engine = SyncEngine::new("device");
        let journal = Journal::open(&journal_path).await.unwrap();
        let report = engine
            .run_once(&mut remote, root.path(), &journal, "2026-11-13T000000Z")
            .await
            .unwrap();
        assert_eq!(report.uploaded, 1);
        drop(journal);

        let clean = engine
            .inspect(
                &mut remote,
                root.path(),
                &journal_path,
                "2026-11-13T000100Z",
            )
            .await
            .unwrap();
        assert!(clean.journal_available);
        assert!(clean.items.is_empty(), "{:?}", clean.items);

        std::fs::write(root.path().join("note.txt"), b"v2").unwrap();
        let edited = engine
            .inspect(
                &mut remote,
                root.path(),
                &journal_path,
                "2026-11-13T000200Z",
            )
            .await
            .unwrap();
        assert_eq!(edited.items.len(), 1, "{:?}", edited.items);
        assert_eq!(edited.items[0].kind, "upload");
        assert_eq!(edited.items[0].path, "note.txt");
        assert_eq!(edited.items[0].size, Some(2));
    }

    #[tokio::test]
    async fn inspect_defers_to_a_pending_folder_move() {
        let root = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let journal_path = state.path().join("journal.sqlite");
        let journal = Journal::open(&journal_path).await.unwrap();
        journal.begin_move("old", "new").await.unwrap();
        drop(journal);
        let mut remote = FakeRemote::default();
        let engine = SyncEngine::new("device");
        let inspection = engine
            .inspect(&mut remote, root.path(), &journal_path, "now")
            .await
            .unwrap();
        assert!(inspection.folder_moves_pending);
        assert!(inspection.items.is_empty());
    }

    #[tokio::test]
    async fn inspect_reports_a_deep_conflict_as_a_conflict_item() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let journal_path = state.path().join("journal.sqlite");
        let journal_a = Journal::in_memory().await.unwrap();
        let journal_b = Journal::open(&journal_path).await.unwrap();
        let mut remote = FakeRemote::default();
        let engine = SyncEngine::new("device");
        std::fs::write(a.path().join("shared.txt"), b"base").unwrap();
        engine
            .run_once(&mut remote, a.path(), &journal_a, "t1")
            .await
            .unwrap();
        engine
            .run_once(&mut remote, b.path(), &journal_b, "t2")
            .await
            .unwrap();
        std::fs::write(a.path().join("shared.txt"), b"from-a").unwrap();
        engine
            .run_once(&mut remote, a.path(), &journal_a, "t3")
            .await
            .unwrap();
        std::fs::write(b.path().join("shared.txt"), b"from-b").unwrap();
        drop(journal_b);
        let inspection = engine
            .inspect(&mut remote, b.path(), &journal_path, "t4")
            .await
            .unwrap();
        let conflict = inspection
            .items
            .iter()
            .find(|item| item.kind == "conflict")
            .expect("conflict item");
        assert_eq!(conflict.path, "shared.txt");
        assert!(conflict.path_to.is_some());
    }

    type PlanCalls = Arc<std::sync::Mutex<Vec<(Vec<InspectItem>, usize)>>>;

    fn plan_engine(calls: PlanCalls) -> SyncEngine {
        SyncEngine::new("device").with_plan_observer(Arc::new(move |items, total| {
            calls.lock().unwrap().push((items.to_vec(), total));
        }))
    }

    #[tokio::test]
    async fn plan_observer_lists_every_queued_path_before_transferring() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        for (name, data) in [("a.txt", &b"a"[..]), ("b.txt", b"bb")] {
            tokio::fs::write(dir.path().join(name), data).await.unwrap();
        }
        let mut remote = FakeRemote::default();
        let calls: PlanCalls = Arc::default();
        let engine = plan_engine(calls.clone());
        run(&engine, &mut remote, dir.path(), &journal).await;

        let calls = calls.lock().unwrap().clone();
        assert_eq!(calls.len(), 1, "one bounded batch for two actions");
        assert_eq!(calls[0].1, 2, "total reports the complete plan");
        let mut queued: Vec<(String, String)> = calls[0]
            .0
            .iter()
            .map(|item| (item.kind.clone(), item.path.clone()))
            .collect();
        queued.sort();
        assert_eq!(
            queued,
            vec![
                ("upload".to_string(), "a.txt".to_string()),
                ("upload".to_string(), "b.txt".to_string()),
            ]
        );
        assert_eq!(remote.0.lock().await.uploads, 2);
    }

    #[tokio::test]
    async fn plan_observer_batches_a_large_plan_without_losing_the_total() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        for index in 0..300 {
            tokio::fs::write(dir.path().join(format!("{index}.txt")), b"x")
                .await
                .unwrap();
        }
        let mut remote = FakeRemote::default();
        let calls: PlanCalls = Arc::default();
        let engine = plan_engine(calls.clone());
        run(&engine, &mut remote, dir.path(), &journal).await;

        let calls = calls.lock().unwrap().clone();
        assert_eq!(calls.len(), 2, "256 then 44");
        assert!(calls.iter().all(|(_, total)| *total == 300));
        assert_eq!(calls[0].0.len(), 256);
        assert_eq!(calls[1].0.len(), 44);
        let unique: std::collections::HashSet<String> = calls
            .iter()
            .flat_map(|(items, _)| items.iter().map(|item| item.path.clone()))
            .collect();
        assert_eq!(unique.len(), 300);
    }

    #[tokio::test]
    async fn plan_observer_skips_blocked_case_collisions() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        for name in ["Readme.md", "README.md", "plain.txt"] {
            tokio::fs::write(dir.path().join(name), b"x").await.unwrap();
        }
        let mut remote = FakeRemote::default();
        let calls: PlanCalls = Arc::default();
        let engine = plan_engine(calls.clone());
        // Case collisions are reported as errors, so run directly rather than
        // through the no-error helper.
        engine
            .run_once(&mut remote, dir.path(), &journal, "t")
            .await
            .unwrap();
        let calls = calls.lock().unwrap().clone();
        let queued: Vec<String> = calls
            .iter()
            .flat_map(|(items, _)| items.iter().map(|item| item.path.clone()))
            .collect();
        assert_eq!(queued, vec!["plain.txt".to_string()]);
        assert_eq!(calls[0].1, 1);
    }

    #[tokio::test]
    async fn plan_observer_reports_an_empty_plan() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        let mut remote = FakeRemote::default();
        let calls: PlanCalls = Arc::default();
        let engine = plan_engine(calls.clone());
        run(&engine, &mut remote, dir.path(), &journal).await;

        let calls = calls.lock().unwrap().clone();
        assert_eq!(calls.len(), 1);
        assert!(calls[0].0.is_empty());
        assert_eq!(calls[0].1, 0);
    }

    type ScanCalls = Arc<std::sync::Mutex<Vec<Vec<scanner::ScannedPath>>>>;

    #[tokio::test]
    async fn scan_observer_reports_local_paths_before_the_plan() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        std::fs::create_dir(dir.path().join("nested")).unwrap();
        std::fs::write(dir.path().join("a.txt"), b"a").unwrap();
        std::fs::write(dir.path().join("nested/b.txt"), b"b").unwrap();

        let order: Arc<std::sync::Mutex<Vec<String>>> = Arc::default();
        let scan_log = order.clone();
        let plan_log = order.clone();
        let engine = SyncEngine::new("device")
            .with_scan_observer(Arc::new(move |paths: &[scanner::ScannedPath]| {
                let mut log = scan_log.lock().unwrap();
                for path in paths {
                    log.push(format!("scan:{}:{}", path.path, path.is_dir));
                }
            }))
            .with_plan_observer(Arc::new(move |items, _| {
                let mut log = plan_log.lock().unwrap();
                for item in items {
                    log.push(format!("plan:{}", item.path));
                }
            }));
        let mut remote = FakeRemote::default();
        run(&engine, &mut remote, dir.path(), &journal).await;

        let log = order.lock().unwrap().clone();
        let first_plan = log
            .iter()
            .position(|entry| entry.starts_with("plan:"))
            .expect("the run reports its plan");
        let scanned = &log[..first_plan];
        assert!(
            scanned.iter().all(|entry| entry.starts_with("scan:")),
            "every scan batch precedes the plan: {scanned:?}"
        );
        for expected in [
            "scan:a.txt:false",
            "scan:nested:true",
            "scan:nested/b.txt:false",
        ] {
            assert!(scanned.iter().any(|entry| entry == expected), "{expected}");
        }
        let queued: Vec<String> = log[first_plan..].to_vec();
        for expected in ["plan:a.txt", "plan:nested/b.txt"] {
            assert!(queued.iter().any(|entry| entry == expected), "{expected}");
        }
        assert_eq!(remote.0.lock().await.uploads, 2);
    }

    #[tokio::test]
    async fn scan_observer_caps_reported_paths_without_stopping_the_scan() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        let total = SCAN_NOTIFY_LIMIT + 100;
        for index in 0..total {
            std::fs::write(dir.path().join(format!("{index}.txt")), b"x").unwrap();
        }
        let mut remote = FakeRemote::default();
        // Stop after the scan: the cap is a notification bound, so the failing
        // snapshot keeps the test focused and fast.
        remote.0.lock().await.fail_snapshot = true;
        let calls: ScanCalls = Arc::default();
        let sink = calls.clone();
        let engine = SyncEngine::new("device").with_scan_observer(Arc::new(move |paths| {
            sink.lock().unwrap().push(paths.to_vec());
        }));
        let error = engine
            .run_once(&mut remote, dir.path(), &journal, "t")
            .await
            .expect_err("the snapshot failure ends the run");
        assert!(matches!(error, SyncError::Remote(_)));

        let batches = calls.lock().unwrap().clone();
        assert!(batches
            .iter()
            .all(|batch| batch.len() <= scanner::SCAN_PROGRESS_BATCH));
        let reported: Vec<String> = batches
            .iter()
            .flat_map(|batch| batch.iter().map(|entry| entry.path.clone()))
            .collect();
        assert_eq!(reported.len(), SCAN_NOTIFY_LIMIT);
        let unique: std::collections::HashSet<&String> = reported.iter().collect();
        assert_eq!(unique.len(), SCAN_NOTIFY_LIMIT, "no repeated paths");
    }

    #[tokio::test]
    async fn scan_observer_never_reports_excluded_paths() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        std::fs::create_dir(dir.path().join("private")).unwrap();
        std::fs::write(dir.path().join("private/secret.txt"), b"s").unwrap();
        std::fs::write(dir.path().join("shared.txt"), b"x").unwrap();
        let mut remote = FakeRemote::default();
        let calls: ScanCalls = Arc::default();
        let sink = calls.clone();
        let engine = SyncEngine::new("device")
            .with_exclusions(vec!["private".into()])
            .with_scan_observer(Arc::new(move |paths| {
                sink.lock().unwrap().push(paths.to_vec());
            }));
        run(&engine, &mut remote, dir.path(), &journal).await;

        let reported: Vec<String> = calls
            .lock()
            .unwrap()
            .iter()
            .flat_map(|batch| batch.iter().map(|entry| entry.path.clone()))
            .collect();
        assert_eq!(reported, vec!["shared.txt".to_string()]);
        assert_eq!(remote.0.lock().await.uploads, 1);
    }

    #[tokio::test]
    async fn snapshot_observer_reports_remote_paths_between_scan_and_plan() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        std::fs::write(dir.path().join("local.txt"), b"local").unwrap();
        let mut remote = FakeRemote::default();
        remote
            .0
            .lock()
            .await
            .files
            .insert("remote.txt".into(), (b"remote".to_vec(), Uuid::new_v4()));

        let log: Arc<std::sync::Mutex<Vec<String>>> = Arc::default();
        let scan_log = log.clone();
        let snapshot_log = log.clone();
        let plan_log = log.clone();
        let engine = SyncEngine::new("device")
            .with_scan_observer(Arc::new(move |paths: &[scanner::ScannedPath]| {
                let mut log = scan_log.lock().unwrap();
                for path in paths {
                    log.push(format!("scan:{}", path.path));
                }
            }))
            .with_snapshot_observer(Arc::new(move |paths: &[scanner::ScannedPath]| {
                let mut log = snapshot_log.lock().unwrap();
                for path in paths {
                    log.push(format!("snapshot:{}", path.path));
                }
            }))
            .with_plan_observer(Arc::new(move |items, _| {
                let mut log = plan_log.lock().unwrap();
                for item in items {
                    log.push(format!("plan:{}", item.path));
                }
            }));
        run(&engine, &mut remote, dir.path(), &journal).await;

        let log = log.lock().unwrap().clone();
        let first_snapshot = log
            .iter()
            .position(|entry| entry.starts_with("snapshot:"))
            .expect("the snapshot reports the remote paths it compared");
        let first_plan = log
            .iter()
            .position(|entry| entry.starts_with("plan:"))
            .expect("the run reports its plan");
        assert!(
            first_snapshot < first_plan,
            "compared remote paths precede the plan: {log:?}"
        );
        assert!(
            log[..first_snapshot]
                .iter()
                .all(|entry| entry.starts_with("scan:")),
            "the scan reports first: {log:?}"
        );
        assert!(log.contains(&"snapshot:remote.txt".to_string()), "{log:?}");
    }

    #[tokio::test]
    async fn snapshot_observer_never_reports_excluded_remote_paths() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::in_memory().await.unwrap();
        let mut remote = FakeRemote::default();
        {
            let mut state = remote.0.lock().await;
            state
                .files
                .insert("private/secret.txt".into(), (b"s".to_vec(), Uuid::new_v4()));
            state
                .files
                .insert("shared.txt".into(), (b"x".to_vec(), Uuid::new_v4()));
        }
        let calls: ScanCalls = Arc::default();
        let sink = calls.clone();
        let engine = SyncEngine::new("device")
            .with_exclusions(vec!["private".into()])
            .with_snapshot_observer(Arc::new(move |paths| {
                sink.lock().unwrap().push(paths.to_vec());
            }));
        run(&engine, &mut remote, dir.path(), &journal).await;

        let reported: Vec<String> = calls
            .lock()
            .unwrap()
            .iter()
            .flat_map(|batch| batch.iter().map(|entry| entry.path.clone()))
            .collect();
        assert_eq!(reported, vec!["shared.txt".to_string()]);
    }

    #[test]
    fn capped_observer_stops_at_its_limit_without_truncating_the_source() {
        let seen: Arc<std::sync::Mutex<Vec<usize>>> = Arc::default();
        let sink = seen.clone();
        let observer: ScanObserver = Arc::new(move |paths: &[scanner::ScannedPath]| {
            sink.lock().unwrap().push(paths.len());
        });
        let capped = capped_observer(observer, 5);
        let batch = |count: usize| -> Vec<scanner::ScannedPath> {
            (0..count)
                .map(|index| scanner::ScannedPath {
                    path: format!("p{index}"),
                    is_dir: false,
                })
                .collect()
        };
        capped(&batch(3));
        capped(&batch(3));
        capped(&batch(4));
        assert_eq!(seen.lock().unwrap().clone(), vec![3, 2]);
    }
}
