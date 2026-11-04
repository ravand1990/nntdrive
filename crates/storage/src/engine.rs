//! Upload/download pipeline and self-healing operations.

use crate::chunker::{hash_hex, Chunk, ChunkStream};
use crate::config::StorageConfig;
use crate::erasure;
use crate::manifest::{ChunkEntry, Compression, FileManifest, StripeEntry};
use crate::store::{NewShard, NewStripe, ShardReplacement, ShardRow, Store, StoreError, StripeRow};
use chrono::{DateTime, Duration, Utc};
use nntdrive_crypto::{CryptoError, Envelope, MasterKey};
use nntdrive_nntp::{new_message_id, Article, NntpError, NntpPool};
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("configuration error: {0}")]
    Config(String),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Crypto(#[from] CryptoError),
    #[error(transparent)]
    Nntp(#[from] NntpError),
    #[error(transparent)]
    Erasure(#[from] erasure::ErasureError),
    #[error("i/o error: {0}")]
    Io(#[from] std::io::Error),
    #[error("manifest error: {0}")]
    Manifest(String),
    #[error("data is unrecoverable: stripe {stripe} has {available}/{needed} required shards")]
    Unrecoverable {
        stripe: Uuid,
        available: usize,
        needed: usize,
    },
    #[error("integrity check failed: {0}")]
    Integrity(String),
    #[error("not found")]
    NotFound,
    #[error("durability threshold not met: {0}")]
    Durability(String),
}

pub type Result<T> = std::result::Result<T, StorageError>;

#[derive(Clone)]
pub struct Context {
    pub account_id: Uuid,
    pub master: MasterKey,
    pub device_id: Option<Uuid>,
}

impl Context {
    pub fn new(account_id: Uuid, master: MasterKey) -> Self {
        Self {
            account_id,
            master,
            device_id: None,
        }
    }
}

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct UploadStats {
    pub bytes_received: u64,
    pub chunks_new: usize,
    pub chunks_reused: usize,
    pub articles_posted: usize,
    pub bytes_posted: u64,
}

pub struct UploadOutcome {
    pub manifest: FileManifest,
    pub sealed_manifest: Vec<u8>,
    pub stats: UploadStats,
}

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct DownloadStats {
    pub bytes_written: u64,
    pub chunks: usize,
    pub shards_fetched: usize,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct StripeHealth {
    pub stripe_id: Uuid,
    pub index: u32,
    pub data_shards: usize,
    pub parity_shards: usize,
    pub available: usize,
    pub required: usize,
    pub recoverable: bool,
    pub degraded: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct FileHealth {
    pub file_id: Uuid,
    pub revision_id: Uuid,
    pub size: u64,
    pub stripes: Vec<StripeHealth>,
    pub recoverable: bool,
    pub degraded: bool,
    pub available_shards: usize,
    pub total_shards: usize,
}

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct RepairReport {
    pub stripes_checked: usize,
    pub stripes_repaired: usize,
    pub stripes_unrecoverable: usize,
    pub shards_reposted: usize,
    pub bytes_posted: u64,
}

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct RefreshReport {
    pub stripes_checked: usize,
    pub stripes_refreshed: usize,
    pub shards_reposted: usize,
    pub bytes_posted: u64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PreparedChunk {
    pub id: Uuid,
    pub index: u32,
    pub offset: u64,
    pub plaintext_len: u64,
    pub plaintext_hash: Vec<u8>,
    pub ciphertext_len: u64,
    pub compression: Compression,
    pub ciphertext: Vec<u8>,
}

impl PreparedChunk {
    pub fn validate(&self) -> Result<()> {
        if self.plaintext_hash.len() != 32 {
            return Err(StorageError::Integrity(
                "chunk hash must be 32 bytes".into(),
            ));
        }
        if self.ciphertext.len() as u64 != self.ciphertext_len {
            return Err(StorageError::Integrity(
                "declared ciphertext length does not match payload".into(),
            ));
        }
        if self.ciphertext.is_empty() {
            return Err(StorageError::Integrity("empty ciphertext".into()));
        }
        Ok(())
    }
}

/// Compresses and encrypts one chunk **on the client**. The backend never sees
/// the inputs to this function.
pub fn prepare_chunk(
    master: &MasterKey,
    chunk: &Chunk,
    compression_level: i32,
) -> Result<PreparedChunk> {
    let (plaintext, compression) = compress(&chunk.data, compression_level);
    let id = Uuid::new_v4();
    let envelope = master.seal_chunk(
        id,
        &chunk.hash,
        chunk.len() as u64,
        compression as u8,
        &plaintext,
    )?;
    let ciphertext = envelope.to_bytes();
    Ok(PreparedChunk {
        id,
        index: chunk.index,
        offset: chunk.offset,
        plaintext_len: chunk.len() as u64,
        plaintext_hash: chunk.hash.to_vec(),
        ciphertext_len: ciphertext.len() as u64,
        compression,
        ciphertext,
    })
}

#[derive(Clone)]
pub struct Storage {
    store: Store,
    nntp: Arc<NntpPool>,
    config: StorageConfig,
}

impl Storage {
    pub fn new(store: Store, nntp: Arc<NntpPool>, config: StorageConfig) -> Result<Self> {
        config.validate().map_err(StorageError::Config)?;
        Ok(Self {
            store,
            nntp,
            config,
        })
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn nntp(&self) -> &NntpPool {
        &self.nntp
    }

    pub fn config(&self) -> &StorageConfig {
        &self.config
    }

    /// Uploads a stream as a new immutable revision. Articles are posted and
    /// verified, then chunk metadata is committed per chunk. The file version
    /// itself is committed by [`Storage::commit`], so a crash never exposes a
    /// partially uploaded file.
    pub async fn upload<R: AsyncRead + Unpin>(
        &self,
        ctx: &Context,
        file_id: Uuid,
        revision_id: Uuid,
        reader: R,
    ) -> Result<UploadOutcome> {
        let mut stream = ChunkStream::new(reader, self.config.chunks.clone());
        let mut entries = Vec::new();
        let mut stats = UploadStats::default();
        while let Some(chunk) = stream.next_chunk().await? {
            stats.bytes_received += chunk.len() as u64;
            if let Some(existing) = self
                .store
                .find_chunk(ctx.account_id, &chunk.hash, chunk.len() as u64)
                .await?
            {
                let entry = self
                    .store
                    .chunk_entry(ctx.account_id, &existing, chunk.index, chunk.offset)
                    .await?;
                stats.chunks_reused += 1;
                entries.push(entry);
                continue;
            }
            let prepared = prepare_chunk(&ctx.master, &chunk, self.config.compression_level)?;
            let (entry, chunk_stats) = self.publish_prepared(ctx.account_id, &prepared).await?;
            stats.chunks_new += 1;
            stats.articles_posted += chunk_stats.articles_posted;
            stats.bytes_posted += chunk_stats.bytes_posted;
            entries.push(entry);
        }
        let size = stream.total_bytes();
        let content_hash = stream.content_hash();
        let mut manifest = FileManifest::new(file_id, revision_id, size, content_hash);
        manifest.chunks = entries;
        manifest.validate().map_err(StorageError::Manifest)?;
        let sealed = ctx
            .master
            .seal_manifest(file_id, revision_id, &manifest.to_bytes())?
            .to_bytes();
        Ok(UploadOutcome {
            manifest,
            sealed_manifest: sealed,
            stats,
        })
    }

    /// Posts a client-prepared (already compressed and encrypted) chunk. This
    /// is the only content path exposed to the backend; it operates on
    /// ciphertext and never needs an encryption key.
    pub async fn publish_prepared(
        &self,
        account_id: Uuid,
        prepared: &PreparedChunk,
    ) -> Result<(ChunkEntry, UploadStats)> {
        prepared.validate()?;
        if let Some(existing) = self
            .store
            .find_chunk(account_id, &prepared.plaintext_hash, prepared.plaintext_len)
            .await?
        {
            let entry = self
                .store
                .chunk_entry(account_id, &existing, prepared.index, prepared.offset)
                .await?;
            return Ok((entry, UploadStats::default()));
        }
        let stripes = erasure::encode(&prepared.ciphertext, &self.config)?;
        let mut new_stripes = Vec::new();
        let mut stats = UploadStats::default();
        for stripe in stripes {
            let stripe_id = Uuid::new_v4();
            let mut new_shards = Vec::new();
            for (shard_index, shard_data) in stripe.shards.iter().enumerate() {
                let shard = self
                    .post_article(prepared.id, stripe.index, shard_index as u32, shard_data)
                    .await?;
                stats.articles_posted += 1;
                stats.bytes_posted += shard.size as u64;
                new_shards.push(shard);
            }
            let verified = self.verify_stripe_posts(&new_shards).await?;
            let required = (stripe.data_shards + self.config.durability_margin)
                .min(stripe.data_shards + stripe.parity_shards);
            if verified < required {
                return Err(StorageError::Durability(format!(
                    "stripe {}: {verified} verified shards, need {required}",
                    stripe.index
                )));
            }
            new_stripes.push(NewStripe {
                id: stripe_id,
                encoded: stripe,
                shards: new_shards,
            });
        }

        let stripe_entries: Vec<StripeEntry> = new_stripes
            .iter()
            .map(|ns| StripeEntry {
                id: ns.id,
                index: ns.encoded.index,
                data_shards: ns.encoded.data_shards,
                parity_shards: ns.encoded.parity_shards,
                shard_len: ns.encoded.shard_len,
                ciphertext_len: ns.encoded.ciphertext_len,
                shard_hashes: ns.shards.iter().map(|s| s.sha256.clone()).collect(),
            })
            .collect();
        self.store
            .insert_chunk(
                account_id,
                prepared.id,
                &prepared.plaintext_hash,
                prepared.plaintext_len,
                prepared.ciphertext_len,
                prepared.compression as u8,
                &new_stripes,
            )
            .await?;

        // A concurrent upload of the same plaintext may have won the dedupe
        // race; in that case the canonical row is the other chunk's.
        let canonical = self
            .store
            .find_chunk(account_id, &prepared.plaintext_hash, prepared.plaintext_len)
            .await?
            .ok_or_else(|| StorageError::Integrity("chunk insert vanished".into()))?;
        let entry = if canonical.id == prepared.id {
            ChunkEntry {
                id: prepared.id,
                index: prepared.index,
                offset: prepared.offset,
                plaintext_len: prepared.plaintext_len,
                plaintext_hash: hash_hex(&prepared.plaintext_hash),
                ciphertext_len: prepared.ciphertext_len,
                compression: prepared.compression,
                stripes: stripe_entries,
            }
        } else {
            self.store
                .chunk_entry(account_id, &canonical, prepared.index, prepared.offset)
                .await?
        };
        Ok((entry, stats))
    }

    async fn post_article(
        &self,
        chunk_id: Uuid,
        stripe_index: u32,
        shard_index: u32,
        shard: &[u8],
    ) -> Result<NewShard> {
        let domain = self.nntp.message_id_domain();
        let groups = self.nntp.posting_groups();
        if groups.is_empty() {
            return Err(StorageError::Config(
                "no posting group configured for NNTP provider".into(),
            ));
        }
        let message_id = new_message_id(&domain);
        let body = nntdrive_nntp::yenc_encode(&message_id, shard);
        let article = Article::new(
            groups,
            format!("[NNTDrive] {chunk_id}/{stripe_index}/{shard_index}"),
            body,
            message_id.clone(),
        );
        let provider = self.nntp.post(&article).await?;
        Ok(NewShard {
            shard_index: shard_index as i32,
            message_id,
            sha256: erasure::sha256_hex(shard),
            size: shard.len() as i64,
            provider: Some(provider),
        })
    }

    async fn verify_stripe_posts(&self, shards: &[NewShard]) -> Result<usize> {
        let mut verified = 0usize;
        for shard in shards {
            match self.nntp.stat(&shard.message_id).await {
                Ok(Some(_)) => {
                    if self.config.verify_after_post {
                        match self.nntp.fetch(&shard.message_id).await {
                            Ok(data) if erasure::sha256_hex(&data) == shard.sha256 => verified += 1,
                            Ok(_) => tracing::error!(
                                message_id = %shard.message_id,
                                "read-back verification failed: article content differs"
                            ),
                            Err(e) => tracing::warn!(
                                message_id = %shard.message_id,
                                error = %e,
                                "read-back verification failed"
                            ),
                        }
                    } else {
                        verified += 1;
                    }
                }
                Ok(None) => tracing::warn!(
                    message_id = %shard.message_id,
                    "article not visible after upload"
                ),
                Err(e) => tracing::warn!(error = %e, "post-upload STAT failed"),
            }
        }
        Ok(verified)
    }

    /// Commits the manifest and makes the new revision visible.
    pub async fn commit(
        &self,
        ctx: &Context,
        outcome: &UploadOutcome,
        parent_revision: Option<Uuid>,
    ) -> Result<()> {
        self.store
            .insert_version(
                ctx.account_id,
                outcome.manifest.file_id,
                &outcome.manifest,
                &outcome.sealed_manifest,
                ctx.device_id,
                parent_revision,
            )
            .await?;
        Ok(())
    }

    pub async fn upload_and_commit<R: AsyncRead + Unpin>(
        &self,
        ctx: &Context,
        file_id: Uuid,
        revision_id: Uuid,
        reader: R,
    ) -> Result<UploadOutcome> {
        let outcome = self.upload(ctx, file_id, revision_id, reader).await?;
        self.commit(ctx, &outcome, None).await?;
        Ok(outcome)
    }

    pub async fn load_manifest(
        &self,
        ctx: &Context,
        file_id: Uuid,
        revision_id: Option<Uuid>,
    ) -> Result<(FileManifest, DateTime<Utc>, Uuid)> {
        let version = self
            .store
            .version(ctx.account_id, file_id, revision_id)
            .await?;
        let envelope = Envelope::from_bytes(&version.manifest)?;
        let plain = ctx
            .master
            .open_manifest(file_id, version.revision_id, &envelope)?;
        let manifest =
            FileManifest::from_bytes(&plain).map_err(|e| StorageError::Manifest(e.to_string()))?;
        manifest.validate().map_err(StorageError::Manifest)?;
        if manifest.file_id != file_id || manifest.revision_id != version.revision_id {
            return Err(StorageError::Integrity(
                "manifest identity does not match its database row".into(),
            ));
        }
        Ok((manifest, version.created_at, version.revision_id))
    }

    /// Downloads and verifies a file, streaming plaintext to `writer`.
    pub async fn download_to<W: AsyncWrite + Unpin>(
        &self,
        ctx: &Context,
        manifest: &FileManifest,
        writer: &mut W,
    ) -> Result<DownloadStats> {
        let mut stats = DownloadStats::default();
        let mut whole = blake3::Hasher::new();
        for chunk in &manifest.chunks {
            let plain = self.reconstruct_chunk(ctx, chunk, &mut stats).await?;
            if plain.len() as u64 != chunk.plaintext_len {
                return Err(StorageError::Integrity(format!(
                    "chunk {} length mismatch",
                    chunk.index
                )));
            }
            if hash_hex(blake3::hash(&plain).as_bytes()) != chunk.plaintext_hash {
                return Err(StorageError::Integrity(format!(
                    "chunk {} hash mismatch",
                    chunk.index
                )));
            }
            whole.update(&plain);
            writer.write_all(&plain).await?;
            stats.bytes_written += plain.len() as u64;
            stats.chunks += 1;
        }
        writer.flush().await?;
        if whole.finalize().to_hex().to_string() != manifest.content_hash {
            return Err(StorageError::Integrity(
                "whole-file hash does not match manifest".into(),
            ));
        }
        Ok(stats)
    }

    async fn reconstruct_chunk(
        &self,
        ctx: &Context,
        chunk: &ChunkEntry,
        stats: &mut DownloadStats,
    ) -> Result<Vec<u8>> {
        let compression = chunk.compression;
        let mut ciphertext = Vec::with_capacity(chunk.ciphertext_len as usize);
        for stripe in &chunk.stripes {
            let shards = self.fetch_stripe_shards(stripe, stats).await?;
            let rec = erasure::reconstruct(
                stripe.data_shards,
                stripe.parity_shards,
                stripe.shard_len,
                stripe.ciphertext_len,
                shards,
            )?;
            ciphertext.extend_from_slice(&rec.ciphertext);
        }
        if ciphertext.len() as u64 != chunk.ciphertext_len {
            return Err(StorageError::Integrity(
                "chunk ciphertext length mismatch".into(),
            ));
        }
        let envelope = Envelope::from_bytes(&ciphertext)?;
        let hash = crate::chunker::hash_from_hex(&chunk.plaintext_hash)
            .ok_or_else(|| StorageError::Manifest("bad chunk hash".into()))?;
        let compressed = ctx.master.open_chunk(
            chunk.id,
            &hash,
            chunk.plaintext_len,
            compression as u8,
            &envelope,
        )?;
        decrypt_compressed(&compressed, chunk.plaintext_len, compression)
    }

    async fn fetch_stripe_shards(
        &self,
        stripe: &StripeEntry,
        stats: &mut DownloadStats,
    ) -> Result<Vec<Option<Vec<u8>>>> {
        let rows = self.store.load_shards(stripe.id).await?;
        let mut shards: Vec<Option<Vec<u8>>> =
            vec![None; stripe.data_shards + stripe.parity_shards];
        let mut provider_errors = 0usize;
        for row in &rows {
            if shards.iter().filter(|s| s.is_some()).count() >= stripe.data_shards {
                break;
            }
            let expected = stripe
                .shard_hashes
                .get(row.shard_index as usize)
                .ok_or_else(|| StorageError::Integrity("manifest shard hash missing".into()))?;
            match self.nntp.fetch(&row.message_id).await {
                Ok(data) => {
                    if erasure::sha256_hex(&data) != *expected {
                        tracing::warn!(
                            shard = %row.id,
                            message_id = %row.message_id,
                            "shard hash mismatch, excluding"
                        );
                        let _ = self.store.set_shard_status(row.id, "corrupt").await;
                        continue;
                    }
                    stats.shards_fetched += 1;
                    shards[row.shard_index as usize] = Some(data);
                    let _ = self.store.set_shard_status(row.id, "ok").await;
                }
                Err(NntpError::NotFound) => {
                    let _ = self.store.set_shard_status(row.id, "missing").await;
                }
                Err(e) => {
                    provider_errors += 1;
                    tracing::warn!(shard = %row.id, error = %e, "shard fetch failed");
                }
            }
        }
        let available = shards.iter().filter(|s| s.is_some()).count();
        if available < stripe.data_shards {
            if provider_errors > 0 && available + provider_errors >= stripe.data_shards {
                return Err(StorageError::Nntp(NntpError::AllProvidersFailed(
                    "provider errors prevented enough shards from being fetched".into(),
                )));
            }
            return Err(StorageError::Unrecoverable {
                stripe: stripe.id,
                available,
                needed: stripe.data_shards,
            });
        }
        Ok(shards)
    }

    /// STATs every article of a file and reports per-stripe recoverability.
    pub async fn check_file(&self, ctx: &Context, manifest: &FileManifest) -> Result<FileHealth> {
        let mut health = FileHealth {
            file_id: manifest.file_id,
            revision_id: manifest.revision_id,
            size: manifest.size,
            stripes: Vec::new(),
            recoverable: true,
            degraded: false,
            available_shards: 0,
            total_shards: 0,
        };
        for chunk in &manifest.chunks {
            for stripe in &chunk.stripes {
                let rows = self.store.load_shards(stripe.id).await?;
                let mut available = 0usize;
                for row in &rows {
                    let status = match self.nntp.stat(&row.message_id).await {
                        Ok(Some(_)) => {
                            available += 1;
                            "ok"
                        }
                        Ok(None) => "missing",
                        Err(e) => {
                            tracing::warn!(shard = %row.id, error = %e, "health STAT failed");
                            "unknown"
                        }
                    };
                    self.store.set_shard_status(row.id, status).await?;
                }
                let total = stripe.data_shards + stripe.parity_shards;
                let recoverable = available >= stripe.data_shards;
                let degraded = recoverable && available < total;
                health.recoverable &= recoverable;
                health.degraded |= degraded;
                health.available_shards += available;
                health.total_shards += total;
                health.stripes.push(StripeHealth {
                    stripe_id: stripe.id,
                    index: stripe.index,
                    data_shards: stripe.data_shards,
                    parity_shards: stripe.parity_shards,
                    available,
                    required: stripe.data_shards,
                    recoverable,
                    degraded,
                });
            }
        }
        let _ = ctx;
        Ok(health)
    }

    /// Repairs every stripe that is degraded but still recoverable. A stripe
    /// that has lost more than `parity_shards` articles is reported as
    /// unrecoverable; nothing is ever claimed repaired without read-back
    /// verification first.
    pub async fn repair_file(
        &self,
        ctx: &Context,
        manifest: &FileManifest,
    ) -> Result<RepairReport> {
        let mut report = RepairReport::default();
        for chunk in &manifest.chunks {
            for stripe in &chunk.stripes {
                report.stripes_checked += 1;
                let rows = self.store.load_shards(stripe.id).await?;
                let mut shards: Vec<Option<Vec<u8>>> =
                    vec![None; stripe.data_shards + stripe.parity_shards];
                for row in &rows {
                    let expected = &stripe.shard_hashes[row.shard_index as usize];
                    match self.nntp.fetch(&row.message_id).await {
                        Ok(data) if erasure::sha256_hex(&data) == *expected => {
                            shards[row.shard_index as usize] = Some(data);
                            self.store.set_shard_status(row.id, "ok").await?;
                        }
                        Ok(_) => {
                            self.store.set_shard_status(row.id, "corrupt").await?;
                        }
                        Err(NntpError::NotFound) => {
                            self.store.set_shard_status(row.id, "missing").await?;
                        }
                        Err(e) => {
                            tracing::warn!(shard = %row.id, error = %e, "repair fetch failed");
                            return Err(StorageError::Nntp(e));
                        }
                    }
                }
                let available = shards.iter().filter(|s| s.is_some()).count();
                if available >= stripe.data_shards + stripe.parity_shards {
                    continue; // healthy, no repost
                }
                if available < stripe.data_shards {
                    report.stripes_unrecoverable += 1;
                    tracing::error!(
                        stripe = %stripe.id,
                        available,
                        required = stripe.data_shards,
                        "stripe is unrecoverable"
                    );
                    continue;
                }
                let present: Vec<bool> = shards.iter().map(|s| s.is_some()).collect();
                let rec = erasure::reconstruct(
                    stripe.data_shards,
                    stripe.parity_shards,
                    stripe.shard_len,
                    stripe.ciphertext_len,
                    shards,
                )?;
                let mut replacements = Vec::new();
                for (index, data) in rec.shards.iter().enumerate() {
                    if present[index] {
                        continue; // verified healthy during this pass
                    }
                    let expected = &stripe.shard_hashes[index];
                    if erasure::sha256_hex(data) != *expected {
                        return Err(StorageError::Integrity(format!(
                            "reconstructed shard {index} does not match manifest hash"
                        )));
                    }
                    let row = rows
                        .iter()
                        .find(|r| r.shard_index as usize == index)
                        .ok_or_else(|| StorageError::Integrity("missing shard row".into()))?;
                    let new_shard = self
                        .post_article(chunk.id, stripe.index, index as u32, data)
                        .await?;
                    let verified = self
                        .nntp
                        .fetch(&new_shard.message_id)
                        .await
                        .map(|d| erasure::sha256_hex(&d) == new_shard.sha256)
                        .unwrap_or(false);
                    if !verified {
                        return Err(StorageError::Durability(format!(
                            "new shard for stripe {} index {index} failed verification",
                            stripe.index
                        )));
                    }
                    report.shards_reposted += 1;
                    report.bytes_posted += new_shard.size as u64;
                    replacements.push(ShardReplacement {
                        shard_id: row.id,
                        message_id: new_shard.message_id,
                        provider: new_shard.provider,
                        sha256: new_shard.sha256,
                        size: new_shard.size,
                        reason: "repair".into(),
                    });
                }
                if !replacements.is_empty() {
                    self.store.replace_shards_bulk(&replacements).await?;
                    report.stripes_repaired += 1;
                }
                let _ = ctx;
            }
        }
        Ok(report)
    }

    /// Reposts stripes whose articles are older than `max_age` days. New
    /// articles are read back and verified before the metadata swap.
    pub async fn refresh_file(
        &self,
        ctx: &Context,
        manifest: &FileManifest,
        max_age_days: u32,
    ) -> Result<RefreshReport> {
        let cutoff = Utc::now() - Duration::days(max_age_days as i64);
        let mut report = RefreshReport::default();
        for chunk in &manifest.chunks {
            for stripe in &chunk.stripes {
                report.stripes_checked += 1;
                let rows = self.store.load_shards(stripe.id).await?;
                if !rows.iter().any(|r| r.posted_at < cutoff) {
                    continue;
                }
                let mut shards: Vec<Option<Vec<u8>>> =
                    vec![None; stripe.data_shards + stripe.parity_shards];
                for row in &rows {
                    let expected = &stripe.shard_hashes[row.shard_index as usize];
                    match self.nntp.fetch(&row.message_id).await {
                        Ok(data) if erasure::sha256_hex(&data) == *expected => {
                            shards[row.shard_index as usize] = Some(data);
                        }
                        Ok(_) | Err(NntpError::NotFound) => {}
                        Err(e) => return Err(StorageError::Nntp(e)),
                    }
                    if shards.iter().filter(|s| s.is_some()).count() >= stripe.data_shards {
                        break;
                    }
                }
                if shards.iter().filter(|s| s.is_some()).count() < stripe.data_shards {
                    tracing::error!(stripe = %stripe.id, "cannot refresh unrecoverable stripe");
                    continue;
                }
                let rec = erasure::reconstruct(
                    stripe.data_shards,
                    stripe.parity_shards,
                    stripe.shard_len,
                    stripe.ciphertext_len,
                    shards,
                )?;
                let mut replacements = Vec::new();
                for (index, data) in rec.shards.iter().enumerate() {
                    let row = rows
                        .iter()
                        .find(|r| r.shard_index as usize == index)
                        .ok_or_else(|| StorageError::Integrity("missing shard row".into()))?;
                    let new_shard = self
                        .post_article(chunk.id, stripe.index, index as u32, data)
                        .await?;
                    let ok = self
                        .nntp
                        .fetch(&new_shard.message_id)
                        .await
                        .map(|d| erasure::sha256_hex(&d) == new_shard.sha256)
                        .unwrap_or(false);
                    if !ok {
                        return Err(StorageError::Durability(format!(
                            "refreshed shard for stripe {} failed read-back verification",
                            stripe.index
                        )));
                    }
                    report.shards_reposted += 1;
                    report.bytes_posted += new_shard.size as u64;
                    replacements.push(ShardReplacement {
                        shard_id: row.id,
                        message_id: new_shard.message_id,
                        provider: new_shard.provider,
                        sha256: new_shard.sha256,
                        size: new_shard.size,
                        reason: "retention_refresh".into(),
                    });
                }
                // Metadata only moves after every new article verified.
                self.store.replace_shards_bulk(&replacements).await?;
                report.stripes_refreshed += 1;
                let _ = ctx;
            }
        }
        Ok(report)
    }

    /// Background-health variant: checks the current shard rows of one stripe
    /// and updates their status. Returns the number of available articles.
    pub async fn check_stripe_rows(&self, rows: &[ShardRow]) -> Result<usize> {
        let mut available = 0;
        for row in rows {
            let status = match self.nntp.stat(&row.message_id).await {
                Ok(Some(_)) => {
                    available += 1;
                    "ok"
                }
                Ok(None) => "missing",
                Err(e) => {
                    tracing::warn!(shard = %row.id, error = %e, "health STAT failed");
                    "unknown"
                }
            };
            self.store.set_shard_status(row.id, status).await?;
        }
        Ok(available)
    }

    /// Repairs one stripe using metadata already in PostgreSQL. Used by the
    /// backend's durable repair jobs; the expected shard hashes come from the
    /// database and are re-verified by clients against their sealed manifest.
    pub async fn repair_stripe_db(
        &self,
        stripe: &StripeRow,
        rows: &[ShardRow],
    ) -> Result<RepairReport> {
        let mut report = RepairReport {
            stripes_checked: 1,
            ..Default::default()
        };
        let total = stripe.data_shards as usize + stripe.parity_shards as usize;
        if rows.len() != total {
            return Err(StorageError::Integrity("shard row count mismatch".into()));
        }
        let mut shards: Vec<Option<Vec<u8>>> = vec![None; total];
        for row in rows {
            let idx = row.shard_index as usize;
            match self.nntp.fetch(&row.message_id).await {
                Ok(data) if erasure::sha256_hex(&data) == row.sha256 => {
                    shards[idx] = Some(data);
                    self.store.set_shard_status(row.id, "ok").await?;
                }
                Ok(_) => {
                    self.store.set_shard_status(row.id, "corrupt").await?;
                }
                Err(NntpError::NotFound) => {
                    self.store.set_shard_status(row.id, "missing").await?;
                }
                Err(e) => {
                    tracing::warn!(shard = %row.id, error = %e, "repair fetch failed");
                    return Err(StorageError::Nntp(e));
                }
            }
        }
        let available = shards.iter().filter(|s| s.is_some()).count();
        if available >= total {
            return Ok(report);
        }
        if available < stripe.data_shards as usize {
            report.stripes_unrecoverable = 1;
            tracing::error!(
                stripe = %stripe.id, available, required = stripe.data_shards,
                "stripe is unrecoverable"
            );
            return Ok(report);
        }
        let present: Vec<bool> = shards.iter().map(|s| s.is_some()).collect();
        let rec = erasure::reconstruct(
            stripe.data_shards as usize,
            stripe.parity_shards as usize,
            stripe.shard_len as usize,
            stripe.ciphertext_len as usize,
            shards,
        )?;
        let mut replacements = Vec::new();
        for (index, data) in rec.shards.iter().enumerate() {
            if present[index] {
                continue;
            }
            let new_shard = self
                .post_article(
                    stripe.chunk_id,
                    stripe.stripe_index as u32,
                    index as u32,
                    data,
                )
                .await?;
            let verified = self
                .nntp
                .fetch(&new_shard.message_id)
                .await
                .map(|d| erasure::sha256_hex(&d) == new_shard.sha256)
                .unwrap_or(false);
            if !verified {
                return Err(StorageError::Durability(
                    "reposted shard failed read-back verification".into(),
                ));
            }
            report.shards_reposted += 1;
            report.bytes_posted += new_shard.size as u64;
            replacements.push(ShardReplacement {
                shard_id: rows[index].id,
                message_id: new_shard.message_id,
                provider: new_shard.provider,
                sha256: new_shard.sha256,
                size: new_shard.size,
                reason: "repair".into(),
            });
        }
        if !replacements.is_empty() {
            self.store.replace_shards_bulk(&replacements).await?;
            report.stripes_repaired = 1;
        }
        Ok(report)
    }

    /// Background retention variant: reposts one whole stripe before its
    /// articles age out.
    pub async fn refresh_stripe_db(
        &self,
        stripe: &StripeRow,
        rows: &[ShardRow],
        cutoff: DateTime<Utc>,
    ) -> Result<RefreshReport> {
        let mut report = RefreshReport {
            stripes_checked: 1,
            ..Default::default()
        };
        if !rows.iter().any(|r| r.posted_at < cutoff) {
            return Ok(report);
        }
        let total = stripe.data_shards as usize + stripe.parity_shards as usize;
        let mut shards: Vec<Option<Vec<u8>>> = vec![None; total];
        for row in rows {
            match self.nntp.fetch(&row.message_id).await {
                Ok(data) if erasure::sha256_hex(&data) == row.sha256 => {
                    shards[row.shard_index as usize] = Some(data);
                }
                Ok(_) | Err(NntpError::NotFound) => {}
                Err(e) => return Err(StorageError::Nntp(e)),
            }
            if shards.iter().filter(|s| s.is_some()).count() >= stripe.data_shards as usize {
                break;
            }
        }
        if shards.iter().filter(|s| s.is_some()).count() < stripe.data_shards as usize {
            tracing::error!(stripe = %stripe.id, "cannot refresh unrecoverable stripe");
            return Ok(report);
        }
        let rec = erasure::reconstruct(
            stripe.data_shards as usize,
            stripe.parity_shards as usize,
            stripe.shard_len as usize,
            stripe.ciphertext_len as usize,
            shards,
        )?;
        let mut replacements = Vec::new();
        for (index, data) in rec.shards.iter().enumerate() {
            let new_shard = self
                .post_article(
                    stripe.chunk_id,
                    stripe.stripe_index as u32,
                    index as u32,
                    data,
                )
                .await?;
            let verified = self
                .nntp
                .fetch(&new_shard.message_id)
                .await
                .map(|d| erasure::sha256_hex(&d) == new_shard.sha256)
                .unwrap_or(false);
            if !verified {
                return Err(StorageError::Durability(
                    "refreshed shard failed read-back verification".into(),
                ));
            }
            let row = rows
                .iter()
                .find(|r| r.shard_index as usize == index)
                .ok_or_else(|| StorageError::Integrity("missing shard row".into()))?;
            report.shards_reposted += 1;
            report.bytes_posted += new_shard.size as u64;
            replacements.push(ShardReplacement {
                shard_id: row.id,
                message_id: new_shard.message_id,
                provider: new_shard.provider,
                sha256: new_shard.sha256,
                size: new_shard.size,
                reason: "retention_refresh".into(),
            });
        }
        self.store.replace_shards_bulk(&replacements).await?;
        report.stripes_refreshed = 1;
        Ok(report)
    }
}

fn compress(data: &[u8], level: i32) -> (Vec<u8>, Compression) {
    if level <= 0 || data.len() < 256 {
        return (data.to_vec(), Compression::None);
    }
    match zstd::bulk::compress(data, level) {
        Ok(c) if c.len() + 32 < data.len() => (c, Compression::Zstd),
        _ => (data.to_vec(), Compression::None),
    }
}

fn decrypt_compressed(
    data: &[u8],
    plaintext_len: u64,
    compression: Compression,
) -> Result<Vec<u8>> {
    match compression {
        Compression::None => Ok(data.to_vec()),
        Compression::Zstd => zstd::bulk::decompress(data, plaintext_len as usize)
            .map_err(|e| StorageError::Integrity(format!("zstd decompression failed: {e}"))),
    }
}
