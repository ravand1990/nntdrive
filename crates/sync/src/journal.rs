//! Local synchronization journal (SQLite). Stores the last synced baseline and
//! the server revision each path was synced at, so restarts do not re-upload or
//! re-download unchanged data.

use crate::reconcile::BaselineEntry;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, Sqlite, SqlitePool, Transaction};
use std::collections::HashMap;

#[derive(Debug, thiserror::Error)]
pub enum JournalError {
    #[error("journal database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("another sync or conflict resolution owns this journal; retry when it finishes")]
    Busy,
}

pub struct Journal {
    pool: SqlitePool,
    operation_pool: SqlitePool,
}

impl Journal {
    pub async fn open(path: impl AsRef<std::path::Path>) -> Result<Self, JournalError> {
        if let Some(parent) = path.as_ref().parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let url = format!("sqlite://{}?mode=rwc", path.as_ref().display());
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect(&url)
            .await?;
        let mut lock_path = path.as_ref().as_os_str().to_os_string();
        lock_path.push(".operation-lock.sqlite");
        let operation_pool = Self::operation_pool(
            SqliteConnectOptions::new().filename(std::path::PathBuf::from(lock_path)),
        )
        .await?;
        Self::init(pool, operation_pool).await
    }

    /// Fresh file equality against an existing journal; never creates or migrates it.
    pub async fn file_matches(
        journal: &std::path::Path,
        root: &std::path::Path,
        relative: &str,
        revision: uuid::Uuid,
        size: u64,
    ) -> bool {
        use sqlx::sqlite::SqliteConnectOptions;
        // A missing/old/corrupt journal is unknown, not a reason to initialize it.
        let options = SqliteConnectOptions::new()
            .filename(journal)
            .read_only(true);
        let Ok(pool) = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
        else {
            return false;
        };
        let row = sqlx::query(
            "SELECT content_hash FROM baseline WHERE path = $1 AND is_dir = 0
             AND deleted = 0 AND revision = $2 AND size = $3
             AND NOT EXISTS (SELECT 1 FROM pending_move)",
        )
        .bind(relative)
        .bind(revision.to_string())
        .bind(i64::try_from(size).unwrap_or(-1))
        .fetch_optional(&pool)
        .await;
        pool.close().await;
        let Ok(Some(row)) = row else { return false };
        let Ok(Some(expected)) = row.try_get::<Option<String>, _>("content_hash") else {
            return false;
        };
        let root = root.to_path_buf();
        let relative = relative.to_owned();
        // Never reuse the scanner's size/mtime hash cache for a browser claim.
        tokio::task::spawn_blocking(move || {
            let inspect = || -> Option<(std::path::PathBuf, std::fs::Metadata)> {
                if !root.is_absolute()
                    || root
                        .components()
                        .any(|c| matches!(c, std::path::Component::ParentDir))
                {
                    return None;
                }
                for ancestor in root.ancestors() {
                    let meta = std::fs::symlink_metadata(ancestor).ok()?;
                    if !meta.is_dir() || meta.file_type().is_symlink() {
                        return None;
                    }
                }
                // Canonical root retains Windows' verbatim prefix for comparisons.
                let root = std::fs::canonicalize(&root).ok()?;
                let mut path = root.clone();
                let parts: Vec<_> = relative.split('/').collect();
                if parts.is_empty() {
                    return None;
                }
                for (i, part) in parts.iter().enumerate() {
                    if part.is_empty() || *part == "." || *part == ".." || part.contains('\\') {
                        return None;
                    }
                    path.push(part);
                    if !path.starts_with(&root) {
                        return None;
                    }
                    let meta = std::fs::symlink_metadata(&path).ok()?;
                    if meta.file_type().is_symlink()
                        || (i + 1 < parts.len() && !meta.is_dir())
                        || std::fs::canonicalize(&path).ok()? != path
                    {
                        return None;
                    }
                }
                let meta = std::fs::symlink_metadata(&path).ok()?;
                (meta.is_file() && meta.len() == size).then_some((path, meta))
            };
            let Some((path, before)) = inspect() else {
                return false;
            };
            let Ok(hash) = crate::scanner::hash_file(&path) else {
                return false;
            };
            let Some((_, after)) = inspect() else {
                return false;
            };
            hash == expected
                && before
                    .modified()
                    .ok()
                    .zip(after.modified().ok())
                    .is_some_and(|(a, b)| a == b)
        })
        .await
        .unwrap_or(false)
    }

    pub async fn in_memory() -> Result<Self, JournalError> {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await?;
        let operation_pool =
            Self::operation_pool(SqliteConnectOptions::new().in_memory(true)).await?;
        Self::init(pool, operation_pool).await
    }

    async fn operation_pool(options: SqliteConnectOptions) -> Result<SqlitePool, JournalError> {
        Ok(SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(
                options
                    .create_if_missing(true)
                    .busy_timeout(std::time::Duration::from_millis(100)),
            )
            .await?)
    }

    /// Holds a SQLite OS-backed write reservation for the entire operation,
    /// independently of baseline transactions. Drop/cancellation rolls it back;
    /// process death releases the OS lock. Never remove the sidecar to unlock it.
    /// All owners must use the same journal path on a local filesystem.
    pub async fn acquire_operation(&self) -> Result<Transaction<'static, Sqlite>, JournalError> {
        match tokio::time::timeout(
            std::time::Duration::from_millis(250),
            self.operation_pool.begin_with("BEGIN IMMEDIATE"),
        )
        .await
        {
            Ok(Ok(lease)) => Ok(lease),
            Err(_) => Err(JournalError::Busy),
            Ok(Err(sqlx::Error::Database(e)))
                if e.code()
                    .and_then(|code| code.parse::<u32>().ok())
                    .is_some_and(|code| matches!(code & 0xff, 5 | 6)) =>
            {
                Err(JournalError::Busy)
            }
            Ok(Err(e)) => Err(e.into()),
        }
    }

    async fn init(pool: SqlitePool, operation_pool: SqlitePool) -> Result<Self, JournalError> {
        sqlx::query(
            "CREATE TABLE IF NOT EXISTS baseline (
                path TEXT PRIMARY KEY,
                is_dir INTEGER NOT NULL,
                size INTEGER NOT NULL,
                content_hash TEXT,
                revision TEXT,
                deleted INTEGER NOT NULL DEFAULT 0
            )",
        )
        .execute(&pool)
        .await?;
        sqlx::query("CREATE TABLE IF NOT EXISTS directory_ids (path TEXT PRIMARY KEY, node_id TEXT NOT NULL UNIQUE)")
            .execute(&pool)
            .await?;
        sqlx::query("CREATE TABLE IF NOT EXISTS pending_move (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), source TEXT NOT NULL, destination TEXT NOT NULL)")
            .execute(&pool)
            .await?;
        Ok(Self {
            pool,
            operation_pool,
        })
    }

    pub async fn load(&self) -> Result<HashMap<String, BaselineEntry>, JournalError> {
        let rows =
            sqlx::query("SELECT path, is_dir, size, content_hash, revision, deleted FROM baseline")
                .fetch_all(&self.pool)
                .await?;
        let mut out = HashMap::new();
        for row in rows {
            let mut entry = BaselineEntry {
                path: row.get("path"),
                is_dir: row.get::<i64, _>("is_dir") != 0,
                size: row.get::<i64, _>("size") as u64,
                content_hash: row.get("content_hash"),
                revision: row
                    .get::<Option<String>, _>("revision")
                    .and_then(|s| s.parse().ok()),
                deleted: row.get::<i64, _>("deleted") != 0,
            };
            if entry.deleted {
                entry.content_hash = None;
            }
            out.insert(entry.path.clone(), entry);
        }
        Ok(out)
    }

    pub async fn upsert(&self, entry: &BaselineEntry) -> Result<(), JournalError> {
        sqlx::query(
            "INSERT INTO baseline (path, is_dir, size, content_hash, revision, deleted)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT(path) DO UPDATE SET
               is_dir = excluded.is_dir, size = excluded.size,
               content_hash = excluded.content_hash, revision = excluded.revision,
               deleted = excluded.deleted",
        )
        .bind(&entry.path)
        .bind(entry.is_dir as i64)
        .bind(entry.size as i64)
        .bind(&entry.content_hash)
        .bind(entry.revision.map(|r| r.to_string()))
        .bind(entry.deleted as i64)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn upsert_many(&self, entries: &[BaselineEntry]) -> Result<(), JournalError> {
        let mut tx = self.pool.begin().await?;
        for entry in entries {
            sqlx::query(
                "INSERT INTO baseline (path, is_dir, size, content_hash, revision, deleted)
                 VALUES ($1, $2, $3, $4, $5, $6)
                 ON CONFLICT(path) DO UPDATE SET
                   is_dir = excluded.is_dir, size = excluded.size,
                   content_hash = excluded.content_hash, revision = excluded.revision,
                   deleted = excluded.deleted",
            )
            .bind(&entry.path)
            .bind(entry.is_dir as i64)
            .bind(entry.size as i64)
            .bind(&entry.content_hash)
            .bind(entry.revision.map(|r| r.to_string()))
            .bind(entry.deleted as i64)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Stable remote directory identities, separate from the path-keyed baseline.
    /// Added independently so existing journals upgrade without losing history.
    pub async fn directory_ids(&self) -> Result<HashMap<String, uuid::Uuid>, JournalError> {
        let rows = sqlx::query("SELECT path, node_id FROM directory_ids")
            .fetch_all(&self.pool)
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| {
                let id: String = row.get("node_id");
                id.parse().ok().map(|id| (row.get("path"), id))
            })
            .collect())
    }

    pub async fn remember_directory(&self, path: &str, id: uuid::Uuid) -> Result<(), JournalError> {
        sqlx::query("INSERT OR REPLACE INTO directory_ids (path, node_id) VALUES ($1, $2)")
            .bind(path)
            .bind(id.to_string())
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn begin_move(&self, from: &str, to: &str) -> Result<(), JournalError> {
        sqlx::query("INSERT INTO pending_move (singleton, source, destination) VALUES (1, $1, $2)")
            .bind(from)
            .bind(to)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn pending_move(&self) -> Result<Option<(String, String)>, JournalError> {
        Ok(
            sqlx::query("SELECT source, destination FROM pending_move WHERE singleton = 1")
                .fetch_optional(&self.pool)
                .await?
                .map(|row| (row.get("source"), row.get("destination"))),
        )
    }

    pub async fn cancel_move(&self) -> Result<(), JournalError> {
        sqlx::query("DELETE FROM pending_move WHERE singleton = 1")
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Remap the whole subtree atomically, using component boundaries rather
    /// than SQL LIKE (names may contain literal '%' and '_'). Never overwrite
    /// destination history. Filesystem moves are checked separately by engine.
    pub async fn remap_subtree(&self, from: &str, to: &str) -> Result<(), JournalError> {
        let mut tx = self.pool.begin().await?;
        for table in ["baseline", "directory_ids"] {
            let rows = sqlx::query(&format!("SELECT path FROM {table}"))
                .fetch_all(&mut *tx)
                .await?;
            let prefix = format!("{from}/");
            for row in rows {
                let path: String = row.get("path");
                let new_path = if path == from {
                    to.to_string()
                } else if let Some(suffix) = path.strip_prefix(&prefix) {
                    format!("{to}/{suffix}")
                } else {
                    continue;
                };
                sqlx::query(&format!("UPDATE {table} SET path = $1 WHERE path = $2"))
                    .bind(new_path)
                    .bind(path)
                    .execute(&mut *tx)
                    .await?;
            }
        }
        sqlx::query("DELETE FROM pending_move WHERE source = $1 AND destination = $2")
            .bind(from)
            .bind(to)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn remove(&self, path: &str) -> Result<(), JournalError> {
        sqlx::query("DELETE FROM baseline WHERE path = $1")
            .bind(path)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[tokio::test]
    async fn operation_excludes_other_instances_and_preserves_baseline() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("journal.sqlite");
        let first = Journal::open(&path).await.unwrap();
        let second = Journal::open(&path).await.unwrap();
        let lease = first.acquire_operation().await.unwrap();
        assert!(matches!(
            first.acquire_operation().await,
            Err(JournalError::Busy)
        ));
        assert!(matches!(
            second.acquire_operation().await,
            Err(JournalError::Busy)
        ));
        first
            .upsert(&BaselineEntry {
                path: "preserved".into(),
                ..Default::default()
            })
            .await
            .unwrap();
        drop(lease);
        let _next = second.acquire_operation().await.unwrap();
        assert!(second.load().await.unwrap().contains_key("preserved"));
        // An unrelated journal must not be blocked globally.
        let other = Journal::open(dir.path().join("other.sqlite"))
            .await
            .unwrap();
        let _independent = other.acquire_operation().await.unwrap();
    }

    #[tokio::test]
    async fn operation_is_released_after_task_cancellation() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("journal.sqlite");
        let first = Journal::open(&path).await.unwrap();
        let second = Journal::open(&path).await.unwrap();
        let (ready, started) = tokio::sync::oneshot::channel();
        let owner = tokio::spawn(async move {
            let _lease = first.acquire_operation().await.unwrap();
            ready.send(()).unwrap();
            std::future::pending::<()>().await;
        });
        started.await.unwrap();
        assert!(matches!(
            second.acquire_operation().await,
            Err(JournalError::Busy)
        ));
        owner.abort();
        assert!(owner.await.unwrap_err().is_cancelled());
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                match second.acquire_operation().await {
                    Ok(lease) => break lease,
                    Err(JournalError::Busy) => {
                        tokio::time::sleep(std::time::Duration::from_millis(10)).await
                    }
                    Err(e) => panic!("unexpected lease failure: {e}"),
                }
            }
        })
        .await
        .unwrap();
    }

    // Invoked only by the process-death regression below, never the normal suite.
    #[tokio::test]
    #[ignore]
    async fn operation_lock_subprocess_helper() {
        let path = std::env::var_os("NNTDRIVE_TEST_OPERATION_JOURNAL").unwrap();
        let journal = Journal::open(&path).await.unwrap();
        let _lease = journal.acquire_operation().await.unwrap();
        std::fs::write(
            std::env::var_os("NNTDRIVE_TEST_OPERATION_READY").unwrap(),
            b"ready",
        )
        .unwrap();
        std::future::pending::<()>().await;
    }

    #[tokio::test]
    async fn operation_excludes_another_process_and_recovers_after_kill() {
        struct Child(std::process::Child);
        impl Drop for Child {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("journal.sqlite");
        let ready = dir.path().join("ready");
        let journal = Journal::open(&path).await.unwrap();
        journal
            .upsert(&BaselineEntry {
                path: "preserved".into(),
                ..Default::default()
            })
            .await
            .unwrap();
        let mut child = Child(
            std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--ignored",
                    "--exact",
                    "journal::tests::operation_lock_subprocess_helper",
                ])
                .env("NNTDRIVE_TEST_OPERATION_JOURNAL", &path)
                .env("NNTDRIVE_TEST_OPERATION_READY", &ready)
                .stdout(std::process::Stdio::null())
                .spawn()
                .unwrap(),
        );
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            while !ready.exists() {
                assert!(
                    child.0.try_wait().unwrap().is_none(),
                    "child exited before acquiring lock"
                );
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert!(matches!(
            journal.acquire_operation().await,
            Err(JournalError::Busy)
        ));
        child.0.kill().unwrap();
        child.0.wait().unwrap();
        let _lease = journal.acquire_operation().await.unwrap();
        assert!(journal.load().await.unwrap().contains_key("preserved"));
    }

    #[tokio::test]
    async fn browser_equality_requires_fresh_bytes_revision_and_safe_path() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("file"), b"same").unwrap();
        let path = dir.path().join("journal.sqlite");
        let revision = Uuid::new_v4();
        assert!(!Journal::file_matches(&path, &root, "file", revision, 4).await);
        assert!(!path.exists(), "inspection must not create a journal");
        let corrupt = dir.path().join("corrupt.sqlite");
        std::fs::write(&corrupt, b"not a database").unwrap();
        assert!(!Journal::file_matches(&corrupt, &root, "file", revision, 4).await);
        assert_eq!(std::fs::read(&corrupt).unwrap(), b"not a database");
        let j = Journal::open(&path).await.unwrap();
        let mut entry = BaselineEntry {
            path: "file".into(),
            is_dir: false,
            size: 4,
            content_hash: Some(crate::scanner::hash_file(&root.join("file")).unwrap()),
            revision: Some(revision),
            deleted: false,
        };
        j.upsert(&entry).await.unwrap();
        assert!(Journal::file_matches(&path, &root, "file", revision, 4).await);
        assert!(!Journal::file_matches(&path, &root, "file", Uuid::new_v4(), 4).await);
        assert!(!Journal::file_matches(&path, &root, "file", revision, 5).await);
        j.upsert(&BaselineEntry {
            path: "../root/file".into(),
            ..entry.clone()
        })
        .await
        .unwrap();
        assert!(!Journal::file_matches(&path, &root, "../root/file", revision, 4).await);
        j.remove("../root/file").await.unwrap();
        std::fs::write(root.join("file"), b"edit").unwrap();
        assert!(!Journal::file_matches(&path, &root, "file", revision, 4).await);
        std::fs::write(root.join("file"), b"same").unwrap();
        for state in 0..4 {
            entry.deleted = state == 0;
            entry.is_dir = state == 1;
            entry.content_hash = if state == 2 {
                None
            } else {
                Some(crate::scanner::hash_file(&root.join("file")).unwrap())
            };
            entry.revision = if state == 3 { None } else { Some(revision) };
            j.upsert(&entry).await.unwrap();
            assert!(!Journal::file_matches(&path, &root, "file", revision, 4).await);
        }
        entry.revision = Some(revision);
        j.upsert(&entry).await.unwrap();
        j.begin_move("file", "other").await.unwrap();
        assert!(!Journal::file_matches(&path, &root, "file", revision, 4).await);
        j.cancel_move().await.unwrap();
        #[cfg(unix)]
        {
            std::fs::rename(root.join("file"), dir.path().join("outside")).unwrap();
            std::os::unix::fs::symlink(dir.path().join("outside"), root.join("file")).unwrap();
            assert!(!Journal::file_matches(&path, &root, "file", revision, 4).await);
            std::fs::remove_file(root.join("file")).unwrap();
            std::fs::copy(dir.path().join("outside"), root.join("file")).unwrap();
            assert!(Journal::file_matches(&path, &root, "file", revision, 4).await);
            std::os::unix::fs::symlink(&root, dir.path().join("linked-root")).unwrap();
            assert!(
                !Journal::file_matches(&path, &dir.path().join("linked-root"), "file", revision, 4)
                    .await
            );
        }
        assert_eq!(j.load().await.unwrap().get("file"), Some(&entry));
    }

    #[tokio::test]
    async fn baseline_roundtrip() {
        let j = Journal::in_memory().await.unwrap();
        let entry = BaselineEntry {
            path: "dir/file.txt".into(),
            is_dir: false,
            size: 123,
            content_hash: Some("abc".into()),
            revision: Some(Uuid::new_v4()),
            deleted: false,
        };
        j.upsert(&entry).await.unwrap();
        let loaded = j.load().await.unwrap();
        assert_eq!(loaded.get("dir/file.txt"), Some(&entry));
        j.remove("dir/file.txt").await.unwrap();
        assert!(j.load().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn subtree_remap_is_atomic_and_component_aware() {
        let j = Journal::in_memory().await.unwrap();
        let id = Uuid::new_v4();
        for path in ["a_%", "a_%/file", "a_%other/file", "target/file"] {
            j.upsert(&BaselineEntry {
                path: path.into(),
                ..Default::default()
            })
            .await
            .unwrap();
        }
        j.remember_directory("a_%", id).await.unwrap();
        j.begin_move("a_%", "target").await.unwrap();
        assert!(j.remap_subtree("a_%", "target").await.is_err());
        assert!(j.load().await.unwrap().contains_key("a_%/file"));
        assert_eq!(j.directory_ids().await.unwrap().get("a_%"), Some(&id));
        assert!(j.pending_move().await.unwrap().is_some());
        j.cancel_move().await.unwrap();
        j.begin_move("a_%", "renamed").await.unwrap();
        j.remap_subtree("a_%", "renamed").await.unwrap();
        let baseline = j.load().await.unwrap();
        assert!(baseline.contains_key("renamed/file"));
        assert!(baseline.contains_key("a_%other/file"));
        assert_eq!(j.directory_ids().await.unwrap().get("renamed"), Some(&id));
        assert!(j.pending_move().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn journal_survives_file_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state/journal.sqlite");
        {
            let j = Journal::open(&path).await.unwrap();
            j.upsert(&BaselineEntry {
                path: "a".into(),
                ..Default::default()
            })
            .await
            .unwrap();
        }
        let j = Journal::open(&path).await.unwrap();
        assert_eq!(j.load().await.unwrap().len(), 1);
    }
}
