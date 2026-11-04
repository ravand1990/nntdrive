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
