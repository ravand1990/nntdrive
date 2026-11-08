//! Client SDK for NNTDrive.
//!
//! This is the code the Flutter app calls through FFI. It performs chunking,
//! compression, encryption and manifest sealing locally, and only uploads
//! ciphertext to the backend. Downloads fetch ciphertext shards through the
//! backend proxy, verify hashes, reconstruct, decrypt and write atomically.

use base64::Engine;
use nntdrive_crypto::{CryptoError, Envelope, MasterKey};
use nntdrive_storage::chunker::{hash_hex, ChunkStream};
use nntdrive_storage::erasure;
use nntdrive_storage::manifest::{ChunkEntry, Compression, FileManifest};
use nntdrive_storage::prepare_chunk;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::path::{Path, PathBuf};
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

const COMPRESSION_LEVEL: i32 = 3;

pub mod copy;
pub mod sync_remote;
pub use sync_remote::HttpRemote;

#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("network error: {0}")]
    Network(#[from] reqwest::Error),
    #[error("i/o error: {0}")]
    Io(#[from] std::io::Error),
    #[error("crypto error: {0}")]
    Crypto(#[from] CryptoError),
    #[error("storage error: {0}")]
    Storage(String),
    #[error("api error {status}: {message}")]
    Api { status: u16, message: String },
    #[error("invalid server response: {0}")]
    Protocol(String),
    #[error("integrity check failed: {0}")]
    Integrity(String),
    #[error("not found")]
    NotFound,
}

pub type Result<T> = std::result::Result<T, ClientError>;

#[derive(Debug, Clone, Deserialize)]
pub struct FileDto {
    pub id: Uuid,
    pub parent_id: Option<Uuid>,
    pub name_enc: String,
    pub is_dir: bool,
    pub size: i64,
    pub favorite: bool,
    pub revision: i64,
    pub current_version: Option<Uuid>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VersionDto {
    pub revision_id: Uuid,
    pub parent_revision: Option<Uuid>,
    pub size: i64,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Deserialize)]
struct ShardLocation {
    index: i32,
    message_id: String,
    sha256: String,
}

#[derive(Debug, Clone, Deserialize)]
struct StripeLocations {
    id: Uuid,
    shards: Vec<ShardLocation>,
}

#[derive(Debug, Clone, Deserialize)]
struct ChunkLocations {
    stripes: Vec<StripeLocations>,
}

#[derive(Debug, Clone, Serialize)]
pub struct UploadResult {
    pub revision_id: Uuid,
    pub size: u64,
    pub chunks_new: usize,
    pub chunks_reused: usize,
    pub articles_posted: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct DownloadResult {
    pub revision_id: Uuid,
    pub size: u64,
    pub chunks: usize,
    pub shards_fetched: usize,
}

pub struct ApiClient {
    base_url: String,
    token: Option<String>,
    http: reqwest::Client,
}

impl ApiClient {
    pub fn new(base_url: impl Into<String>) -> Result<Self> {
        // Explicit provider selection: the dependency graph can enable more than
        // one rustls crypto backend.
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        let http = reqwest::Client::builder()
            .user_agent("NNTDrive/0.1")
            .build()?;
        Ok(Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            token: None,
            http,
        })
    }

    pub fn set_token(&mut self, token: impl Into<String>) {
        self.token = Some(token.into());
    }

    fn url(&self, path: &str) -> String {
        format!("{}/api/v1{}", self.base_url, path)
    }

    async fn check(&self, res: reqwest::Response) -> Result<reqwest::Response> {
        let status = res.status();
        if status.is_success() {
            return Ok(res);
        }
        let body = res.text().await.unwrap_or_default();
        let message = serde_json::from_str::<serde_json::Value>(&body)
            .ok()
            .and_then(|v| v.get("message").and_then(|m| m.as_str()).map(String::from))
            .unwrap_or(body);
        if status.as_u16() == 404 {
            return Err(ClientError::NotFound);
        }
        Err(ClientError::Api {
            status: status.as_u16(),
            message,
        })
    }

    fn auth(&self, req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        match &self.token {
            Some(token) => req.bearer_auth(token),
            None => req,
        }
    }

    pub async fn list_files(&self, parent: Option<Uuid>) -> Result<Vec<FileDto>> {
        let mut req = self.http.get(self.url("/files"));
        if let Some(parent) = parent {
            req = req.query(&[("parent_id", parent.to_string())]);
        }
        let res = self.check(self.auth(req).send().await?).await?;
        let value: serde_json::Value = res.json().await?;
        let files = value.get("files").cloned().unwrap_or_else(|| json!([]));
        serde_json::from_value(files).map_err(|e| ClientError::Protocol(e.to_string()))
    }

    pub async fn create_file(
        &self,
        id: Uuid,
        parent: Option<Uuid>,
        name_enc: Vec<u8>,
        is_dir: bool,
    ) -> Result<()> {
        let res = self
            .auth(self.http.post(self.url("/files")))
            .json(&json!({
                "id": id,
                "parent_id": parent,
                "name_enc": b64(&name_enc),
                "is_dir": is_dir,
            }))
            .send()
            .await?;
        self.check(res).await?;
        Ok(())
    }

    pub async fn delete_file(&self, id: Uuid) -> Result<()> {
        let res = self
            .auth(self.http.patch(self.url(&format!("/files/{id}"))))
            .json(&json!({ "deleted": true }))
            .send()
            .await?;
        self.check(res).await?;
        Ok(())
    }

    pub async fn rename_file(&self, id: Uuid, name_enc_b64: &str) -> Result<()> {
        let res = self
            .auth(self.http.patch(self.url(&format!("/files/{id}"))))
            .json(&json!({ "name_enc": name_enc_b64 }))
            .send()
            .await?;
        self.check(res).await?;
        Ok(())
    }

    pub async fn move_file(&self, id: Uuid, parent: Option<Uuid>) -> Result<()> {
        let res = self
            .auth(self.http.post(self.url(&format!("/files/{id}/move"))))
            .json(&json!({ "parent_id": parent }))
            .send()
            .await?;
        self.check(res).await?;
        Ok(())
    }

    pub async fn versions(&self, id: Uuid) -> Result<Vec<VersionDto>> {
        let res = self
            .auth(self.http.get(self.url(&format!("/files/{id}/versions"))))
            .send()
            .await?;
        let value: serde_json::Value = self.check(res).await?.json().await?;
        let versions = value.get("versions").cloned().unwrap_or_else(|| json!([]));
        serde_json::from_value(versions).map_err(|e| ClientError::Protocol(e.to_string()))
    }

    pub async fn manifest(&self, file_id: Uuid, revision: Option<Uuid>) -> Result<(Vec<u8>, Uuid)> {
        let mut req = self
            .http
            .get(self.url(&format!("/files/{file_id}/manifest")));
        if let Some(rev) = revision {
            req = req.query(&[("revision", rev.to_string())]);
        }
        let res = self.check(self.auth(req).send().await?).await?;
        let revision_id = res
            .headers()
            .get("x-nntdrive-revision")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| ClientError::Protocol("manifest revision header missing".into()))?;
        Ok((res.bytes().await?.to_vec(), revision_id))
    }

    pub async fn lookup_chunk(&self, hash_hex: &str, len: u64) -> Result<Option<ChunkEntry>> {
        let res = self
            .auth(self.http.get(self.url("/chunks/lookup")))
            .query(&[("hash", hash_hex), ("len", &len.to_string())])
            .send()
            .await?;
        if res.status().as_u16() == 404 {
            return Ok(None);
        }
        let value: serde_json::Value = self.check(res).await?.json().await?;
        let chunk = value
            .get("chunk")
            .cloned()
            .ok_or_else(|| ClientError::Protocol("chunk missing from lookup".into()))?;
        serde_json::from_value(chunk)
            .map(Some)
            .map_err(|e| ClientError::Protocol(e.to_string()))
    }

    pub async fn publish_chunk(
        &self,
        prepared: &nntdrive_storage::PreparedChunk,
    ) -> Result<(ChunkEntry, usize)> {
        let res = self
            .auth(self.http.post(self.url("/chunks")))
            .json(&json!({
                "chunk_id": prepared.id,
                "index": prepared.index,
                "offset": prepared.offset,
                "plaintext_hash": hex(&prepared.plaintext_hash),
                "plaintext_len": prepared.plaintext_len,
                "compression": prepared.compression as u8,
                "ciphertext": b64(&prepared.ciphertext),
            }))
            .send()
            .await?;
        let value: serde_json::Value = self.check(res).await?.json().await?;
        let chunk = value
            .get("chunk")
            .cloned()
            .ok_or_else(|| ClientError::Protocol("chunk missing from response".into()))?;
        let entry =
            serde_json::from_value(chunk).map_err(|e| ClientError::Protocol(e.to_string()))?;
        let articles = value
            .get("stats")
            .and_then(|s| s.get("articles_posted"))
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as usize;
        Ok((entry, articles))
    }

    pub async fn commit(
        &self,
        file_id: Uuid,
        revision_id: Uuid,
        parent_revision: Option<Uuid>,
        size: u64,
        sealed_manifest: &[u8],
    ) -> Result<()> {
        let res = self
            .auth(
                self.http
                    .post(self.url(&format!("/files/{file_id}/versions"))),
            )
            .json(&json!({
                "revision_id": revision_id,
                "parent_revision": parent_revision,
                "base_revision": parent_revision,
                "size": size,
                "sealed_manifest": b64(sealed_manifest),
            }))
            .send()
            .await?;
        self.check(res).await?;
        Ok(())
    }

    async fn chunk_locations(&self, chunk_id: Uuid) -> Result<ChunkLocations> {
        let res = self
            .auth(self.http.get(self.url(&format!("/chunks/{chunk_id}"))))
            .send()
            .await?;
        self.check(res)
            .await?
            .json()
            .await
            .map_err(|e| ClientError::Protocol(e.to_string()))
    }

    async fn article(&self, message_id: &str) -> Result<Vec<u8>> {
        let res = self
            .auth(
                self.http
                    .get(self.url(&format!("/articles/{}", urlencode(message_id)))),
            )
            .send()
            .await?;
        Ok(self.check(res).await?.bytes().await?.to_vec())
    }
}

/// Encrypts and uploads a local file as a new immutable revision.
pub async fn upload_file(
    api: &ApiClient,
    master: &MasterKey,
    file_id: Uuid,
    revision_id: Uuid,
    parent_revision: Option<Uuid>,
    path: &Path,
) -> Result<UploadResult> {
    upload_file_with_progress(
        api,
        master,
        file_id,
        revision_id,
        parent_revision,
        path,
        &|_, _, _| {},
    )
    .await
}

/// Logical plaintext bytes confirmed by chunk publication (or deduplication),
/// not estimated wire bytes. Completion is emitted only after manifest commit.
#[allow(clippy::too_many_arguments)]
pub async fn upload_file_with_progress(
    api: &ApiClient,
    master: &MasterKey,
    file_id: Uuid,
    revision_id: Uuid,
    parent_revision: Option<Uuid>,
    path: &Path,
    progress: &(dyn Fn(u64, u64, bool) + Send + Sync),
) -> Result<UploadResult> {
    let total = tokio::fs::metadata(path).await?.len();
    progress(0, total, false);
    let file = tokio::fs::File::open(path).await?;
    let mut stream = ChunkStream::new(file, nntdrive_storage::ChunkConfig::default());
    let mut entries = Vec::new();
    let mut chunks_new = 0;
    let mut chunks_reused = 0;
    let mut articles_posted = 0;
    while let Some(chunk) = stream.next_chunk().await? {
        if let Some(mut existing) = api
            .lookup_chunk(&hash_hex(&chunk.hash), chunk.len() as u64)
            .await?
        {
            existing.index = chunk.index;
            existing.offset = chunk.offset;
            entries.push(existing);
            chunks_reused += 1;
            progress(chunk.offset + chunk.len() as u64, total, false);
            continue;
        }
        let prepared = prepare_chunk(master, &chunk, COMPRESSION_LEVEL)
            .map_err(|e| ClientError::Storage(e.to_string()))?;
        let (entry, articles) = api.publish_chunk(&prepared).await?;
        entries.push(entry);
        chunks_new += 1;
        articles_posted += articles;
        progress(chunk.offset + chunk.len() as u64, total, false);
    }
    let size = stream.total_bytes();
    let content_hash = stream.content_hash();
    let mut manifest = FileManifest::new(file_id, revision_id, size, content_hash);
    manifest.chunks = entries;
    manifest
        .validate()
        .map_err(|e| ClientError::Protocol(format!("manifest invalid: {e}")))?;
    let sealed = master
        .seal_manifest(file_id, revision_id, &manifest.to_bytes())?
        .to_bytes();
    api.commit(file_id, revision_id, parent_revision, size, &sealed)
        .await?;
    progress(size, size, true);
    Ok(UploadResult {
        revision_id,
        size,
        chunks_new,
        chunks_reused,
        articles_posted,
    })
}

/// Downloads, verifies and decrypts a revision, writing it atomically.
pub async fn download_file(
    api: &ApiClient,
    master: &MasterKey,
    file_id: Uuid,
    revision: Option<Uuid>,
    destination: &Path,
) -> Result<DownloadResult> {
    download_file_with_progress(api, master, file_id, revision, destination, &|_, _, _| {}).await
}

/// Verified plaintext bytes written to the temporary destination. Completion
/// follows whole-file verification and atomic materialization.
pub async fn download_file_with_progress(
    api: &ApiClient,
    master: &MasterKey,
    file_id: Uuid,
    revision: Option<Uuid>,
    destination: &Path,
    progress: &(dyn Fn(u64, u64, bool) + Send + Sync),
) -> Result<DownloadResult> {
    let (sealed, revision_id) = api.manifest(file_id, revision).await?;
    let envelope = Envelope::from_bytes(&sealed)?;
    let plain = master.open_manifest(file_id, revision_id, &envelope)?;
    let manifest = FileManifest::from_bytes(&plain)
        .map_err(|e| ClientError::Protocol(format!("manifest invalid: {e}")))?;
    manifest
        .validate()
        .map_err(|e| ClientError::Protocol(format!("manifest invalid: {e}")))?;
    if manifest.file_id != file_id || manifest.revision_id != revision_id {
        return Err(ClientError::Integrity(
            "manifest identity does not match server metadata".into(),
        ));
    }

    let tmp = destination.with_extension(format!(
        "{}.nntdrive-part",
        destination
            .extension()
            .map(|e| e.to_string_lossy().to_string())
            .unwrap_or_default()
    ));
    if let Some(parent) = destination.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let mut out = tokio::fs::File::create(&tmp).await?;
    let mut whole = blake3::Hasher::new();
    let mut shards_fetched = 0usize;
    let mut completed = 0;
    progress(0, manifest.size, false);
    for chunk in &manifest.chunks {
        let locations = api.chunk_locations(chunk.id).await?;
        let mut ciphertext = Vec::with_capacity(chunk.ciphertext_len as usize);
        for stripe in &chunk.stripes {
            let loc = locations
                .stripes
                .iter()
                .find(|s| s.id == stripe.id)
                .ok_or_else(|| ClientError::Protocol("stripe location missing".into()))?;
            let mut shards: Vec<Option<Vec<u8>>> =
                vec![None; stripe.data_shards + stripe.parity_shards];
            for candidate in &loc.shards {
                if shards.iter().filter(|s| s.is_some()).count() >= stripe.data_shards {
                    break;
                }
                let idx = candidate.index as usize;
                if idx >= shards.len() || shards[idx].is_some() {
                    continue;
                }
                let data = match api.article(&candidate.message_id).await {
                    Ok(d) => d,
                    Err(ClientError::NotFound) => continue,
                    Err(e) => return Err(e),
                };
                let expected = stripe
                    .shard_hashes
                    .get(idx)
                    .ok_or_else(|| ClientError::Protocol("shard hash missing".into()))?;
                if sha256_hex(&data) != *expected || candidate.sha256 != *expected {
                    continue;
                }
                shards[idx] = Some(data);
                shards_fetched += 1;
            }
            let rec = erasure::reconstruct(
                stripe.data_shards,
                stripe.parity_shards,
                stripe.shard_len,
                stripe.ciphertext_len,
                shards,
            )
            .map_err(|e| ClientError::Storage(e.to_string()))?;
            ciphertext.extend_from_slice(&rec.ciphertext);
        }
        if ciphertext.len() as u64 != chunk.ciphertext_len {
            return Err(ClientError::Integrity(
                "chunk ciphertext size mismatch".into(),
            ));
        }
        let envelope = Envelope::from_bytes(&ciphertext)?;
        let hash = nntdrive_storage::chunker::hash_from_hex(&chunk.plaintext_hash)
            .ok_or_else(|| ClientError::Protocol("chunk hash invalid".into()))?;
        let compressed = master.open_chunk(
            chunk.id,
            &hash,
            chunk.plaintext_len,
            chunk.compression as u8,
            &envelope,
        )?;
        let plain = match chunk.compression {
            Compression::None => compressed,
            Compression::Zstd => zstd::bulk::decompress(&compressed, chunk.plaintext_len as usize)
                .map_err(|e| ClientError::Integrity(format!("decompression failed: {e}")))?,
        };
        if plain.len() as u64 != chunk.plaintext_len {
            return Err(ClientError::Integrity(
                "chunk plaintext size mismatch".into(),
            ));
        }
        if hash_hex(blake3::hash(&plain).as_bytes()) != chunk.plaintext_hash {
            return Err(ClientError::Integrity("chunk hash mismatch".into()));
        }
        whole.update(&plain);
        out.write_all(&plain).await?;
        completed += plain.len() as u64;
        progress(completed, manifest.size, false);
    }
    out.flush().await?;
    drop(out);
    if whole.finalize().to_hex().to_string() != manifest.content_hash {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(ClientError::Integrity(
            "whole-file hash does not match manifest".into(),
        ));
    }
    #[cfg(windows)]
    if destination.exists() {
        let _ = tokio::fs::remove_file(destination).await;
    }
    tokio::fs::rename(&tmp, destination).await?;
    progress(completed, manifest.size, true);
    Ok(DownloadResult {
        revision_id,
        size: manifest.size,
        chunks: manifest.chunks.len(),
        shards_fetched,
    })
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(data);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

fn urlencode(s: &str) -> String {
    // Message-IDs are constrained ASCII; percent-encode anything outside the
    // unreserved set to keep the path valid.
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~' | b'@') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

pub fn default_download_path(destination: &Path) -> PathBuf {
    destination.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_encoding_keeps_message_ids_safe() {
        assert_eq!(
            urlencode("abc.123@nntdrive.local"),
            "abc.123@nntdrive.local"
        );
        assert_eq!(urlencode("a/b c"), "a%2Fb%20c");
    }

    #[test]
    fn base64_and_hex_helpers() {
        assert_eq!(hex(&[0, 15, 255]), "000fff");
        assert_eq!(b64(b"hi"), "aGk=");
    }
}
