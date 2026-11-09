//! PostgreSQL metadata store for chunks, stripes, article locations, file
//! versions and the change log. All queries are parameterised; account scoping
//! is enforced in every statement.

use crate::erasure::EncodedStripe;
use crate::manifest::{ChunkEntry, Compression, FileManifest, StripeEntry};
use chrono::{DateTime, Utc};
use sqlx::{PgPool, Row};
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("not found")]
    NotFound,
    #[error("invalid stored data: {0}")]
    Invalid(String),
}

pub type Result<T> = std::result::Result<T, StoreError>;

#[derive(Debug, Clone)]
pub struct ChunkRow {
    pub id: Uuid,
    pub plaintext_hash: Vec<u8>,
    pub plaintext_len: i64,
    pub ciphertext_len: i64,
    pub compression: i16,
}

#[derive(Debug, Clone)]
pub struct StripeRow {
    pub id: Uuid,
    pub chunk_id: Uuid,
    pub stripe_index: i32,
    pub data_shards: i32,
    pub parity_shards: i32,
    pub shard_len: i32,
    pub ciphertext_len: i32,
}

#[derive(Debug, Clone)]
pub struct ShardRow {
    pub id: Uuid,
    pub stripe_id: Uuid,
    pub shard_index: i32,
    pub message_id: String,
    pub sha256: String,
    pub size: i64,
    pub provider: Option<String>,
    pub generation: i32,
    pub status: String,
    pub posted_at: DateTime<Utc>,
    pub checked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone)]
pub struct NewShard {
    pub shard_index: i32,
    pub message_id: String,
    pub sha256: String,
    pub size: i64,
    pub provider: Option<String>,
}

#[derive(Debug, Clone)]
pub struct NewStripe {
    pub id: Uuid,
    pub encoded: EncodedStripe,
    pub shards: Vec<NewShard>,
}

#[derive(Debug, Clone)]
pub struct ShardReplacement {
    pub shard_id: Uuid,
    pub message_id: String,
    pub provider: Option<String>,
    pub sha256: String,
    pub size: i64,
    pub reason: String,
}

#[derive(Debug, Clone)]
pub struct StoredVersion {
    pub revision_id: Uuid,
    pub parent_revision: Option<Uuid>,
    pub size: i64,
    pub manifest: Vec<u8>,
    pub created_at: DateTime<Utc>,
    pub deleted: bool,
}

#[derive(Clone)]
pub struct Store {
    pool: PgPool,
}

impl Store {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn find_chunk(
        &self,
        account_id: Uuid,
        plaintext_hash: &[u8],
        plaintext_len: u64,
    ) -> Result<Option<ChunkRow>> {
        let row = sqlx::query(
            "SELECT id, plaintext_hash, plaintext_len, ciphertext_len, compression
             FROM chunks WHERE account_id = $1 AND plaintext_hash = $2 AND plaintext_len = $3",
        )
        .bind(account_id)
        .bind(plaintext_hash)
        .bind(plaintext_len as i64)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| ChunkRow {
            id: r.get("id"),
            plaintext_hash: r.get("plaintext_hash"),
            plaintext_len: r.get("plaintext_len"),
            ciphertext_len: r.get("ciphertext_len"),
            compression: r.get("compression"),
        }))
    }

    /// Loads the chunk plus its stripes and current shard locations.
    pub async fn load_chunk(
        &self,
        account_id: Uuid,
        chunk_id: Uuid,
    ) -> Result<(ChunkRow, Vec<(StripeRow, Vec<ShardRow>)>)> {
        let row = sqlx::query(
            "SELECT id, plaintext_hash, plaintext_len, ciphertext_len, compression
             FROM chunks WHERE account_id = $1 AND id = $2",
        )
        .bind(account_id)
        .bind(chunk_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or(StoreError::NotFound)?;
        let chunk = ChunkRow {
            id: row.get("id"),
            plaintext_hash: row.get("plaintext_hash"),
            plaintext_len: row.get("plaintext_len"),
            ciphertext_len: row.get("ciphertext_len"),
            compression: row.get("compression"),
        };
        let stripes = self.load_stripes(chunk_id).await?;
        Ok((chunk, stripes))
    }

    pub async fn load_stripes(&self, chunk_id: Uuid) -> Result<Vec<(StripeRow, Vec<ShardRow>)>> {
        let rows = sqlx::query(
            "SELECT id, chunk_id, stripe_index, data_shards, parity_shards, shard_len, ciphertext_len
             FROM stripes WHERE chunk_id = $1 ORDER BY stripe_index",
        )
        .bind(chunk_id)
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        for r in rows {
            let stripe = StripeRow {
                id: r.get("id"),
                chunk_id: r.get("chunk_id"),
                stripe_index: r.get("stripe_index"),
                data_shards: r.get("data_shards"),
                parity_shards: r.get("parity_shards"),
                shard_len: r.get("shard_len"),
                ciphertext_len: r.get("ciphertext_len"),
            };
            let shards = self.load_shards(stripe.id).await?;
            out.push((stripe, shards));
        }
        Ok(out)
    }

    pub async fn load_shards(&self, stripe_id: Uuid) -> Result<Vec<ShardRow>> {
        let rows = sqlx::query(
            "SELECT id, stripe_id, shard_index, message_id, sha256, size, provider, generation,
                    status, posted_at, checked_at
             FROM shards WHERE stripe_id = $1 ORDER BY shard_index",
        )
        .bind(stripe_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| ShardRow {
                id: r.get("id"),
                stripe_id: r.get("stripe_id"),
                shard_index: r.get("shard_index"),
                message_id: r.get("message_id"),
                sha256: r.get("sha256"),
                size: r.get("size"),
                provider: r.get("provider"),
                generation: r.get("generation"),
                status: r.get("status"),
                posted_at: r.get("posted_at"),
                checked_at: r.get("checked_at"),
            })
            .collect())
    }

    pub async fn load_shards_for_stripes(&self, stripe_ids: &[Uuid]) -> Result<Vec<ShardRow>> {
        if stripe_ids.is_empty() {
            return Ok(Vec::new());
        }
        let rows = sqlx::query(
            "SELECT id, stripe_id, shard_index, message_id, sha256, size, provider, generation,
                    status, posted_at, checked_at
             FROM shards WHERE stripe_id = ANY($1) ORDER BY stripe_id, shard_index",
        )
        .bind(stripe_ids)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| ShardRow {
                id: r.get("id"),
                stripe_id: r.get("stripe_id"),
                shard_index: r.get("shard_index"),
                message_id: r.get("message_id"),
                sha256: r.get("sha256"),
                size: r.get("size"),
                provider: r.get("provider"),
                generation: r.get("generation"),
                status: r.get("status"),
                posted_at: r.get("posted_at"),
                checked_at: r.get("checked_at"),
            })
            .collect())
    }

    /// Inserts a chunk and all of its article locations atomically.
    #[allow(clippy::too_many_arguments)]
    pub async fn insert_chunk(
        &self,
        account_id: Uuid,
        chunk_id: Uuid,
        plaintext_hash: &[u8],
        plaintext_len: u64,
        ciphertext_len: u64,
        compression: u8,
        stripes: &[NewStripe],
    ) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "INSERT INTO chunks (id, account_id, plaintext_hash, plaintext_len, ciphertext_len, compression)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (account_id, plaintext_hash, plaintext_len) DO NOTHING",
        )
        .bind(chunk_id)
        .bind(account_id)
        .bind(plaintext_hash)
        .bind(plaintext_len as i64)
        .bind(ciphertext_len as i64)
        .bind(compression as i16)
        .execute(&mut *tx)
        .await?;

        // If another upload won the dedupe race, keep that chunk and discard ours.
        let actual_id: Uuid = sqlx::query_scalar(
            "SELECT id FROM chunks WHERE account_id = $1 AND plaintext_hash = $2 AND plaintext_len = $3",
        )
        .bind(account_id)
        .bind(plaintext_hash)
        .bind(plaintext_len as i64)
        .fetch_one(&mut *tx)
        .await?;
        if actual_id != chunk_id {
            tx.rollback().await?;
            return Ok(());
        }

        for new_stripe in stripes {
            let stripe = &new_stripe.encoded;
            let stripe_id = new_stripe.id;
            sqlx::query(
                "INSERT INTO stripes (id, chunk_id, stripe_index, data_shards, parity_shards, shard_len, ciphertext_len)
                 VALUES ($1, $2, $3, $4, $5, $6, $7)",
            )
            .bind(stripe_id)
            .bind(chunk_id)
            .bind(stripe.index as i32)
            .bind(stripe.data_shards as i32)
            .bind(stripe.parity_shards as i32)
            .bind(stripe.shard_len as i32)
            .bind(stripe.ciphertext_len as i32)
            .execute(&mut *tx)
            .await?;
            for shard in &new_stripe.shards {
                sqlx::query(
                    "INSERT INTO shards (id, stripe_id, shard_index, message_id, sha256, size, provider, status, checked_at)
                     VALUES ($1, $2, $3, $4, $5, $6, $7, 'ok', now())",
                )
                .bind(Uuid::new_v4())
                .bind(stripe_id)
                .bind(shard.shard_index)
                .bind(&shard.message_id)
                .bind(&shard.sha256)
                .bind(shard.size)
                .bind(&shard.provider)
                .execute(&mut *tx)
                .await?;
            }
        }
        tx.commit().await?;
        Ok(())
    }

    /// Builds the manifest representation of a stored chunk (used on dedupe).
    pub async fn chunk_entry(
        &self,
        account_id: Uuid,
        chunk: &ChunkRow,
        index: u32,
        offset: u64,
    ) -> Result<ChunkEntry> {
        let (_, stripes) = self.load_chunk(account_id, chunk.id).await?;
        let compression = Compression::from_u8(chunk.compression as u8)
            .ok_or_else(|| StoreError::Invalid("unknown compression".into()))?;
        let mut out = Vec::new();
        for (stripe, shards) in stripes {
            let mut hashes: Vec<String> = Vec::with_capacity(shards.len());
            for i in 0..(stripe.data_shards + stripe.parity_shards) {
                let s = shards
                    .iter()
                    .find(|s| s.shard_index == i)
                    .ok_or_else(|| StoreError::Invalid("missing shard row".into()))?;
                hashes.push(s.sha256.clone());
            }
            out.push(StripeEntry {
                id: stripe.id,
                index: stripe.stripe_index as u32,
                data_shards: stripe.data_shards as usize,
                parity_shards: stripe.parity_shards as usize,
                shard_len: stripe.shard_len as usize,
                ciphertext_len: stripe.ciphertext_len as usize,
                shard_hashes: hashes,
            });
        }
        Ok(ChunkEntry {
            id: chunk.id,
            index,
            offset,
            plaintext_len: chunk.plaintext_len as u64,
            plaintext_hash: hex(&chunk.plaintext_hash),
            ciphertext_len: chunk.ciphertext_len as u64,
            compression,
            stripes: out,
        })
    }

    pub async fn set_shard_status(&self, shard_id: Uuid, status: &str) -> Result<()> {
        sqlx::query("UPDATE shards SET status = $2, checked_at = now() WHERE id = $1")
            .bind(shard_id)
            .bind(status)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn set_shard_statuses(&self, ids: &[Uuid], status: &str) -> Result<()> {
        if ids.is_empty() {
            return Ok(());
        }
        sqlx::query("UPDATE shards SET status = $2, checked_at = now() WHERE id = ANY($1)")
            .bind(ids)
            .bind(status)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Applies several verified shard replacements in one transaction (repair
    /// and retention refresh use this so metadata never points at a half-swap).
    pub async fn replace_shards_bulk(&self, replacements: &[ShardReplacement]) -> Result<()> {
        if replacements.is_empty() {
            return Ok(());
        }
        let mut tx = self.pool.begin().await?;
        for r in replacements {
            let row = sqlx::query(
                "SELECT message_id, provider, generation FROM shards WHERE id = $1 FOR UPDATE",
            )
            .bind(r.shard_id)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or(StoreError::NotFound)?;
            let old_id: String = row.get("message_id");
            let old_provider: Option<String> = row.get("provider");
            let generation: i32 = row.get("generation");
            sqlx::query(
                "INSERT INTO shard_history (shard_id, message_id, provider, generation, reason)
                 VALUES ($1, $2, $3, $4, $5)",
            )
            .bind(r.shard_id)
            .bind(&old_id)
            .bind(&old_provider)
            .bind(generation)
            .bind(&r.reason)
            .execute(&mut *tx)
            .await?;
            sqlx::query(
                "UPDATE shards SET message_id = $2, provider = $3, sha256 = $4, size = $5,
                        generation = generation + 1, status = 'ok', posted_at = now(), checked_at = now()
                 WHERE id = $1",
            )
            .bind(r.shard_id)
            .bind(&r.message_id)
            .bind(&r.provider)
            .bind(&r.sha256)
            .bind(r.size)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Atomically points a shard at a new article after a verified repair or
    /// refresh. The old Message-ID is preserved in `shard_history`.
    pub async fn replace_shard(
        &self,
        shard_id: Uuid,
        message_id: &str,
        provider: Option<&str>,
        sha256: &str,
        size: i64,
        reason: &str,
    ) -> Result<()> {
        self.replace_shards_bulk(&[ShardReplacement {
            shard_id,
            message_id: message_id.to_string(),
            provider: provider.map(|s| s.to_string()),
            sha256: sha256.to_string(),
            size,
            reason: reason.to_string(),
        }])
        .await
    }

    pub async fn insert_version(
        &self,
        account_id: Uuid,
        file_id: Uuid,
        manifest: &FileManifest,
        sealed_manifest: &[u8],
        device_id: Option<Uuid>,
        parent_revision: Option<Uuid>,
    ) -> Result<()> {
        let chunk_ids: Vec<Uuid> = manifest.chunks.iter().map(|c| c.id).collect();
        self.insert_version_with_references(
            account_id,
            file_id,
            manifest,
            sealed_manifest,
            device_id,
            parent_revision,
            Some(&chunk_ids),
        )
        .await
    }

    /// `None` is a legacy opaque manifest, NOT an empty reference set.
    /// The caller must derive `Some` from the complete decrypted manifest.
    #[allow(clippy::too_many_arguments)]
    pub async fn insert_version_with_references(
        &self,
        account_id: Uuid,
        file_id: Uuid,
        manifest: &FileManifest,
        sealed_manifest: &[u8],
        device_id: Option<Uuid>,
        parent_revision: Option<Uuid>,
        chunk_ids: Option<&[Uuid]>,
    ) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
            .bind(account_id.to_string())
            .execute(&mut *tx)
            .await?;
        let required: bool =
            sqlx::query_scalar("SELECT reference_commits_required FROM accounts WHERE id = $1")
                .bind(account_id)
                .fetch_one(&mut *tx)
                .await?;
        if required && chunk_ids.is_none() {
            return Err(StoreError::Invalid(
                "complete chunk references required; upgrade client".into(),
            ));
        }
        let version_id = Uuid::new_v4();
        let inserted = sqlx::query(
            "INSERT INTO file_versions (id, account_id, file_id, revision_id, parent_revision, device_id, size, manifest, created_at, references_complete)
             SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
             FROM files WHERE account_id = $2 AND id = $3",
        )
        .bind(version_id)
        .bind(account_id)
        .bind(file_id)
        .bind(manifest.revision_id)
        .bind(parent_revision)
        .bind(device_id)
        .bind(manifest.size as i64)
        .bind(sealed_manifest)
        .bind(manifest.created_at)
        .bind(chunk_ids.is_some())
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if inserted != 1 {
            return Err(StoreError::NotFound);
        }
        if let Some(ids) = chunk_ids {
            Self::write_references(&mut tx, account_id, version_id, ids).await?;
        }
        sqlx::query(
            "UPDATE files SET current_version = $3, size = $4, revision = revision + 1, updated_at = now()
             WHERE account_id = $1 AND id = $2",
        )
        .bind(account_id)
        .bind(file_id)
        .bind(manifest.revision_id)
        .bind(manifest.size as i64)
        .execute(&mut *tx)
        .await?;
        let seq: i64 = sqlx::query_scalar(
            "SELECT COALESCE(MAX(seq), 0) + 1 FROM sync_events WHERE account_id = $1",
        )
        .bind(account_id)
        .fetch_one(&mut *tx)
        .await?;
        sqlx::query(
            "INSERT INTO sync_events (account_id, seq, device_id, file_id, revision_id, kind, payload)
             VALUES ($1, $2, $3, $4, $5, 'version', jsonb_build_object('size', $6::bigint))",
        )
        .bind(account_id)
        .bind(seq)
        .bind(device_id)
        .bind(file_id)
        .bind(manifest.revision_id)
        .bind(manifest.size as i64)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// Insert validated tenant references in a caller-owned GC-locked transaction.
    pub async fn write_references(
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        account_id: Uuid,
        version_id: Uuid,
        chunk_ids: &[Uuid],
    ) -> Result<()> {
        let size: i64 =
            sqlx::query_scalar("SELECT size FROM file_versions WHERE account_id = $1 AND id = $2")
                .bind(account_id)
                .bind(version_id)
                .fetch_one(&mut **tx)
                .await?;
        if (size == 0) != chunk_ids.is_empty() {
            return Err(StoreError::Invalid(
                "chunk references do not match empty/nonempty version".into(),
            ));
        }
        // FK NO ACTION is a second line of defence against concurrent deletion.
        // Composite FKs forbid cross-account references even for direct callers.
        let mut ids = chunk_ids.to_vec();
        ids.sort_unstable();
        ids.dedup();
        let found: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM chunks WHERE account_id = $1 AND id = ANY($2)",
        )
        .bind(account_id)
        .bind(&ids)
        .fetch_one(&mut **tx)
        .await?;
        if found != ids.len() as i64 {
            return Err(StoreError::Invalid(
                "missing account chunk reference".into(),
            ));
        }
        sqlx::query("INSERT INTO version_chunks(account_id, version_id, chunk_id) SELECT $1, $2, unnest($3::uuid[])")
            .bind(account_id).bind(version_id).bind(ids).execute(&mut **tx).await?;
        Ok(())
    }

    /// One-time authenticated-client backfill. Never replace a complete set:
    /// historical, conflict and tombstoned versions all remain protected.
    pub async fn backfill_references(
        &self,
        account_id: Uuid,
        file_id: Uuid,
        revision_id: Uuid,
        chunk_ids: &[Uuid],
    ) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
            .bind(account_id.to_string())
            .execute(&mut *tx)
            .await?;
        let row = sqlx::query("SELECT id, references_complete FROM file_versions WHERE account_id = $1 AND file_id = $2 AND revision_id = $3")
            .bind(account_id).bind(file_id).bind(revision_id).fetch_optional(&mut *tx).await?.ok_or(StoreError::NotFound)?;
        let id: Uuid = row.get("id");
        if row.get::<bool, _>("references_complete") {
            let existing: Vec<Uuid> = sqlx::query_scalar("SELECT chunk_id FROM version_chunks WHERE account_id = $1 AND version_id = $2 ORDER BY chunk_id")
                .bind(account_id).bind(id).fetch_all(&mut *tx).await?;
            let mut supplied = chunk_ids.to_vec();
            supplied.sort_unstable();
            supplied.dedup();
            if existing != supplied {
                return Err(StoreError::Invalid("references already complete".into()));
            }
        } else {
            Self::write_references(&mut tx, account_id, id, chunk_ids).await?;
            sqlx::query("UPDATE file_versions SET references_complete = TRUE WHERE account_id = $1 AND id = $2")
                .bind(account_id).bind(id).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Explicit per-account opt-in, metadata only; never contacts NNTP.
    /// Serializes with commits/backfills across backend processes. After first
    /// successful collection legacy opaque commits are permanently refused.
    /// A reuse/upload racing collection either commits first and is protected,
    /// or fails reference validation without publishing an invalid version.
    pub async fn collect_orphan_chunks(
        &self,
        account_id: Uuid,
        grace_days: u32,
        limit: i64,
    ) -> Result<u64> {
        if !(1..=3650).contains(&grace_days) || !(1..=1000).contains(&limit) {
            return Err(StoreError::Invalid(
                "invalid GC grace or batch limit".into(),
            ));
        }
        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
            .bind(account_id.to_string())
            .execute(&mut *tx)
            .await?;
        let incomplete: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM file_versions WHERE account_id = $1 AND NOT references_complete)")
            .bind(account_id).fetch_one(&mut *tx).await?;
        if incomplete {
            return Err(StoreError::Invalid(
                "GC blocked: incomplete version references".into(),
            ));
        }
        let updated =
            sqlx::query("UPDATE accounts SET reference_commits_required = TRUE WHERE id = $1")
                .bind(account_id)
                .execute(&mut *tx)
                .await?
                .rows_affected();
        if updated != 1 {
            return Err(StoreError::NotFound);
        }
        let deleted = sqlx::query("DELETE FROM chunks WHERE account_id = $1 AND id IN (
            SELECT c.id FROM chunks c WHERE c.account_id = $1
            AND c.created_at < transaction_timestamp() - make_interval(days => $2)
            AND NOT EXISTS(SELECT 1 FROM version_chunks r WHERE r.account_id = $1 AND r.chunk_id = c.id)
            ORDER BY c.created_at, c.id LIMIT $3)")
            .bind(account_id).bind(grace_days as i32).bind(limit).execute(&mut *tx).await?.rows_affected();
        tx.commit().await?;
        Ok(deleted)
    }

    /// Latest committed version, or a specific revision.
    pub async fn version(
        &self,
        account_id: Uuid,
        file_id: Uuid,
        revision_id: Option<Uuid>,
    ) -> Result<StoredVersion> {
        let row = match revision_id {
            Some(rev) => {
                sqlx::query(
                    "SELECT revision_id, parent_revision, size, manifest, created_at, deleted
                     FROM file_versions WHERE account_id = $1 AND file_id = $2 AND revision_id = $3",
                )
                .bind(account_id)
                .bind(file_id)
                .bind(rev)
                .fetch_optional(&self.pool)
                .await?
            }
            None => {
                sqlx::query(
                    "SELECT v.revision_id, v.parent_revision, v.size, v.manifest, v.created_at, v.deleted
                     FROM file_versions v
                     JOIN files f ON f.account_id = v.account_id AND f.id = v.file_id
                     WHERE v.account_id = $1 AND v.file_id = $2 AND v.revision_id = f.current_version",
                )
                .bind(account_id)
                .bind(file_id)
                .fetch_optional(&self.pool)
                .await?
            }
        }
        .ok_or(StoreError::NotFound)?;
        Ok(StoredVersion {
            revision_id: row.get("revision_id"),
            parent_revision: row.get("parent_revision"),
            size: row.get("size"),
            manifest: row.get("manifest"),
            created_at: row.get("created_at"),
            deleted: row.get("deleted"),
        })
    }

    pub async fn list_versions(
        &self,
        account_id: Uuid,
        file_id: Uuid,
        limit: i64,
    ) -> Result<Vec<StoredVersion>> {
        let rows = sqlx::query(
            "SELECT revision_id, parent_revision, size, manifest, created_at, deleted
             FROM file_versions WHERE account_id = $1 AND file_id = $2
             ORDER BY created_at DESC LIMIT $3",
        )
        .bind(account_id)
        .bind(file_id)
        .bind(limit.clamp(1, 500))
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredVersion {
                revision_id: row.get("revision_id"),
                parent_revision: row.get("parent_revision"),
                size: row.get("size"),
                manifest: row.get("manifest"),
                created_at: row.get("created_at"),
                deleted: row.get("deleted"),
            })
            .collect())
    }

    /// Files whose newest version is older than `cutoff`, oldest first, for
    /// retention refresh selection.
    pub async fn aged_files(&self, limit: i64) -> Result<Vec<(Uuid, Uuid, Uuid)>> {
        let rows = sqlx::query(
            "SELECT f.account_id, f.id AS file_id, v.revision_id
             FROM files f
             JOIN file_versions v ON v.account_id = f.account_id AND v.file_id = f.id
                  AND v.revision_id = f.current_version
             WHERE f.deleted = FALSE
             ORDER BY v.created_at ASC LIMIT $1",
        )
        .bind(limit.clamp(1, 1000))
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| (r.get("account_id"), r.get("file_id"), r.get("revision_id")))
            .collect())
    }

    /// Iterates stripes for background health checks, keyset-paginated.
    pub async fn list_stripe_specs(
        &self,
        after: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<(StripeRow, Vec<ShardRow>)>> {
        let rows = sqlx::query(
            "SELECT id, chunk_id, stripe_index, data_shards, parity_shards, shard_len, ciphertext_len
             FROM stripes WHERE ($1::uuid IS NULL OR id > $1)
             ORDER BY id LIMIT $2",
        )
        .bind(after)
        .bind(limit.clamp(1, 1000))
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::new();
        for r in rows {
            let stripe = StripeRow {
                id: r.get("id"),
                chunk_id: r.get("chunk_id"),
                stripe_index: r.get("stripe_index"),
                data_shards: r.get("data_shards"),
                parity_shards: r.get("parity_shards"),
                shard_len: r.get("shard_len"),
                ciphertext_len: r.get("ciphertext_len"),
            };
            let shards = self.load_shards(stripe.id).await?;
            out.push((stripe, shards));
        }
        Ok(out)
    }

    /// Chunk and article aggregates for the admin dashboard.
    pub async fn platform_totals(&self) -> Result<PlatformTotals> {
        let row = sqlx::query(
            "SELECT
                (SELECT count(*) FROM accounts) AS accounts,
                (SELECT count(*) FROM accounts WHERE disabled = FALSE) AS active_accounts,
                (SELECT count(*) FROM devices WHERE revoked_at IS NULL) AS devices,
                (SELECT count(*) FROM files WHERE deleted = FALSE) AS files,
                (SELECT count(*) FROM stripes) AS stripes,
                (SELECT count(*) FROM shards) AS shards,
                (SELECT count(*) FROM shards WHERE status = 'missing') AS missing_shards,
                (SELECT count(*) FROM shards WHERE status = 'corrupt') AS corrupt_shards,
                (SELECT COALESCE(SUM(plaintext_len),0)::bigint FROM chunks) AS logical_bytes,
                (SELECT COALESCE(SUM(ciphertext_len),0)::bigint FROM chunks) AS ciphertext_bytes,
                (SELECT COALESCE(SUM(size),0)::bigint FROM shards) AS usenet_bytes,
                (SELECT count(*) FROM file_versions) AS versions,
                (SELECT count(*) FROM jobs WHERE state IN ('pending','running')) AS pending_jobs,
                (SELECT count(*) FROM jobs WHERE state = 'failed') AS failed_jobs",
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(PlatformTotals {
            accounts: row.get("accounts"),
            active_accounts: row.get("active_accounts"),
            devices: row.get("devices"),
            files: row.get("files"),
            stripes: row.get("stripes"),
            shards: row.get("shards"),
            missing_shards: row.get("missing_shards"),
            corrupt_shards: row.get("corrupt_shards"),
            logical_bytes: row.get("logical_bytes"),
            ciphertext_bytes: row.get("ciphertext_bytes"),
            usenet_bytes: row.get("usenet_bytes"),
            versions: row.get("versions"),
            pending_jobs: row.get("pending_jobs"),
            failed_jobs: row.get("failed_jobs"),
        })
    }

    pub async fn count_storage(&self, account_id: Uuid) -> Result<(i64, i64)> {
        let row = sqlx::query(
            "SELECT COALESCE(SUM(plaintext_len), 0)::bigint AS logical,
                    COALESCE(SUM(ciphertext_len), 0)::bigint AS ciphertext
             FROM chunks WHERE account_id = $1",
        )
        .bind(account_id)
        .fetch_one(&self.pool)
        .await?;
        Ok((row.get("logical"), row.get("ciphertext")))
    }

    /// Loads one stripe with its shard rows (used by repair jobs).
    pub async fn stripe_with_shards(
        &self,
        stripe_id: Uuid,
    ) -> Result<Option<(StripeRow, Vec<ShardRow>)>> {
        let row = sqlx::query(
            "SELECT id, chunk_id, stripe_index, data_shards, parity_shards, shard_len, ciphertext_len
             FROM stripes WHERE id = $1",
        )
        .bind(stripe_id)
        .fetch_optional(&self.pool)
        .await?;
        let Some(r) = row else {
            return Ok(None);
        };
        let stripe = StripeRow {
            id: r.get("id"),
            chunk_id: r.get("chunk_id"),
            stripe_index: r.get("stripe_index"),
            data_shards: r.get("data_shards"),
            parity_shards: r.get("parity_shards"),
            shard_len: r.get("shard_len"),
            ciphertext_len: r.get("ciphertext_len"),
        };
        let shards = self.load_shards(stripe_id).await?;
        Ok(Some((stripe, shards)))
    }

    /// Finds an article only if it belongs to the given account. The article
    /// proxy uses this to enforce tenant isolation.
    pub async fn find_article(
        &self,
        account_id: Uuid,
        message_id: &str,
    ) -> Result<Option<ShardRow>> {
        let row = sqlx::query(
            "SELECT s.id, s.stripe_id, s.shard_index, s.message_id, s.sha256, s.size,
                    s.provider, s.generation, s.status, s.posted_at, s.checked_at
             FROM shards s
             JOIN stripes st ON st.id = s.stripe_id
             JOIN chunks c ON c.id = st.chunk_id
             WHERE c.account_id = $1 AND s.message_id = $2",
        )
        .bind(account_id)
        .bind(message_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| ShardRow {
            id: r.get("id"),
            stripe_id: r.get("stripe_id"),
            shard_index: r.get("shard_index"),
            message_id: r.get("message_id"),
            sha256: r.get("sha256"),
            size: r.get("size"),
            provider: r.get("provider"),
            generation: r.get("generation"),
            status: r.get("status"),
            posted_at: r.get("posted_at"),
            checked_at: r.get("checked_at"),
        }))
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlatformTotals {
    pub accounts: i64,
    pub active_accounts: i64,
    pub devices: i64,
    pub files: i64,
    pub stripes: i64,
    pub shards: i64,
    pub missing_shards: i64,
    pub corrupt_shards: i64,
    pub logical_bytes: i64,
    pub ciphertext_bytes: i64,
    pub usenet_bytes: i64,
    pub versions: i64,
    pub pending_jobs: i64,
    pub failed_jobs: i64,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Test database helper. Uses `TEST_DATABASE_URL` (or a local default) and an
/// isolated schema per test, so tests can run in parallel.
pub struct TestDb {
    pub store: Store,
    pub schema: String,
    pub admin: PgPool,
}

impl TestDb {
    pub async fn create() -> Option<Self> {
        let url = std::env::var("TEST_DATABASE_URL").unwrap_or_else(|_| {
            "postgres://postgres:nntdrive_dev@127.0.0.1:5432/nntdrive_test".to_string()
        });
        let admin = match PgPool::connect(&url).await {
            Ok(p) => p,
            Err(e) => {
                eprintln!("skipping PostgreSQL-backed test: {e}");
                return None;
            }
        };
        let schema = format!("t_{}", Uuid::new_v4().simple());
        sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&admin)
            .await
            .unwrap();
        let schema_set = schema.clone();
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(8)
            .after_connect(move |conn, _meta| {
                let sql = format!("SET search_path TO \"{schema_set}\"");
                Box::pin(async move {
                    sqlx::query(&sql).execute(conn).await?;
                    Ok(())
                })
            })
            .connect(&url)
            .await
            .unwrap();
        MIGRATOR.run(&pool).await.unwrap();
        Some(Self {
            store: Store::new(pool),
            schema,
            admin,
        })
    }

    pub async fn create_account(&self, email: &str) -> Uuid {
        let id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO accounts (id, email, password_hash, display_name) VALUES ($1, $2, 'x', 'Test')",
        )
        .bind(id)
        .bind(email)
        .execute(self.store.pool())
        .await
        .unwrap();
        id
    }

    pub async fn create_file(
        &self,
        account: Uuid,
        parent: Option<Uuid>,
        name_enc: Vec<u8>,
    ) -> Uuid {
        let id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO files (id, account_id, parent_id, name_enc) VALUES ($1, $2, $3, $4)",
        )
        .bind(id)
        .bind(account)
        .bind(parent)
        .bind(name_enc)
        .execute(self.store.pool())
        .await
        .unwrap();
        id
    }
}

impl Drop for TestDb {
    fn drop(&mut self) {
        let admin = self.admin.clone();
        let schema = self.schema.clone();
        tokio::spawn(async move {
            let _ = sqlx::query(&format!("DROP SCHEMA \"{schema}\" CASCADE"))
                .execute(&admin)
                .await;
        });
    }
}

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");
