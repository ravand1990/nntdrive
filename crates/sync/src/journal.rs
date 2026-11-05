//! Local synchronization journal (SQLite). Stores the last synced baseline and
//! the server revision each path was synced at, so restarts do not re-upload or
//! re-download unchanged data.

use crate::reconcile::BaselineEntry;
use sqlx::sqlite::SqlitePoolOptions;
use sqlx::{Row, SqlitePool};
use std::collections::HashMap;

#[derive(Debug, thiserror::Error)]
pub enum JournalError {
    #[error("journal database error: {0}")]
    Db(#[from] sqlx::Error),
}

pub struct Journal {
    pool: SqlitePool,
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
        Self::init(pool).await
    }

    pub async fn in_memory() -> Result<Self, JournalError> {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await?;
        Self::init(pool).await
    }

    async fn init(pool: SqlitePool) -> Result<Self, JournalError> {
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
        Ok(Self { pool })
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
