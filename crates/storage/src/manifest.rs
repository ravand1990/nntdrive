//! Versioned file manifest. Serialized, then sealed with the account's
//! manifest key before it leaves the client.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const MANIFEST_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum Compression {
    None = 0,
    Zstd = 1,
}

impl Compression {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(Self::None),
            1 => Some(Self::Zstd),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StripeEntry {
    pub id: Uuid,
    pub index: u32,
    pub data_shards: usize,
    pub parity_shards: usize,
    pub shard_len: usize,
    pub ciphertext_len: usize,
    /// SHA-256 of every shard (data then parity). Checked before reconstruction
    /// so a malicious backend cannot swap article contents silently.
    pub shard_hashes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChunkEntry {
    pub id: Uuid,
    pub index: u32,
    pub offset: u64,
    pub plaintext_len: u64,
    pub plaintext_hash: String,
    pub ciphertext_len: u64,
    pub compression: Compression,
    pub stripes: Vec<StripeEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileManifest {
    pub version: u32,
    pub file_id: Uuid,
    pub revision_id: Uuid,
    pub size: u64,
    pub content_hash: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub chunks: Vec<ChunkEntry>,
}

impl FileManifest {
    pub fn new(file_id: Uuid, revision_id: Uuid, size: u64, content_hash: String) -> Self {
        Self {
            version: MANIFEST_VERSION,
            file_id,
            revision_id,
            size,
            content_hash,
            created_at: chrono::Utc::now(),
            chunks: Vec::new(),
        }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("manifest is serializable")
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        serde_json::from_slice(bytes)
    }

    /// Structural validation of untrusted (but authenticated) manifest data.
    pub fn validate(&self) -> Result<(), String> {
        if self.version != MANIFEST_VERSION {
            return Err(format!("unsupported manifest version {}", self.version));
        }
        if self.content_hash.len() != 64 {
            return Err("content hash must be 64 hex chars".into());
        }
        let mut expected_offset = 0u64;
        let mut total = 0u64;
        for (i, c) in self.chunks.iter().enumerate() {
            if c.index as usize != i {
                return Err("chunk indices are not contiguous".into());
            }
            if c.offset != expected_offset {
                return Err("chunk offsets are inconsistent".into());
            }
            if c.plaintext_hash.len() != 64 {
                return Err("chunk hash must be 64 hex chars".into());
            }
            if c.stripes.is_empty() && c.plaintext_len > 0 {
                return Err("non-empty chunk has no stripes".into());
            }
            let mut stripe_bytes = 0usize;
            for (j, s) in c.stripes.iter().enumerate() {
                if s.index as usize != j {
                    return Err("stripe indices are not contiguous".into());
                }
                if s.data_shards == 0 || s.parity_shards == 0 {
                    return Err("stripe has zero shards".into());
                }
                if s.shard_hashes.len() != s.data_shards + s.parity_shards {
                    return Err("stripe shard hash count mismatch".into());
                }
                if s.shard_hashes.iter().any(|h| h.len() != 64) {
                    return Err("invalid shard hash".into());
                }
                stripe_bytes = stripe_bytes
                    .checked_add(s.ciphertext_len)
                    .ok_or("overflow")?;
            }
            if stripe_bytes as u64 != c.ciphertext_len {
                return Err("stripe sizes do not add up to ciphertext length".into());
            }
            expected_offset = expected_offset
                .checked_add(c.plaintext_len)
                .ok_or("size overflow")?;
            total = total.checked_add(c.plaintext_len).ok_or("size overflow")?;
        }
        if total != self.size {
            return Err("manifest size does not match chunk sizes".into());
        }
        Ok(())
    }

    pub fn total_articles(&self) -> usize {
        self.chunks
            .iter()
            .flat_map(|c| &c.stripes)
            .map(|s| s.data_shards + s.parity_shards)
            .sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> FileManifest {
        let mut m = FileManifest::new(Uuid::new_v4(), Uuid::new_v4(), 10, "a".repeat(64));
        m.chunks.push(ChunkEntry {
            id: Uuid::new_v4(),
            index: 0,
            offset: 0,
            plaintext_len: 10,
            plaintext_hash: "b".repeat(64),
            ciphertext_len: 26,
            compression: Compression::None,
            stripes: vec![StripeEntry {
                id: Uuid::new_v4(),
                index: 0,
                data_shards: 1,
                parity_shards: 1,
                shard_len: 26,
                ciphertext_len: 26,
                shard_hashes: vec!["c".repeat(64), "d".repeat(64)],
            }],
        });
        m
    }

    #[test]
    fn validation_accepts_well_formed_manifest() {
        let m = sample();
        m.validate().unwrap();
        assert_eq!(m.total_articles(), 2);
        let round = FileManifest::from_bytes(&m.to_bytes()).unwrap();
        assert_eq!(round, m);
    }

    #[test]
    fn validation_rejects_tampering() {
        let mut m = sample();
        m.size = 11;
        assert!(m.validate().is_err());

        let mut m = sample();
        m.chunks[0].stripes[0].shard_hashes.pop();
        assert!(m.validate().is_err());

        let mut m = sample();
        m.chunks[0].index = 3;
        assert!(m.validate().is_err());
    }
}
