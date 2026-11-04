//! Storage engine configuration.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkConfig {
    pub min_size: u32,
    pub avg_size: u32,
    pub max_size: u32,
}

impl Default for ChunkConfig {
    fn default() -> Self {
        Self {
            min_size: 256 * 1024,
            avg_size: 1024 * 1024,
            max_size: 4 * 1024 * 1024,
        }
    }
}

impl ChunkConfig {
    pub fn validate(&self) -> Result<(), String> {
        if !(16 * 1024..=32 * 1024 * 1024).contains(&self.min_size) {
            return Err("chunk min_size out of range".into());
        }
        if self.avg_size < self.min_size || self.avg_size > self.max_size {
            return Err("chunk sizes must satisfy min <= avg <= max".into());
        }
        if self.max_size > 64 * 1024 * 1024 {
            return Err("chunk max_size too large".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageConfig {
    pub chunks: ChunkConfig,
    /// Bytes of ciphertext per data shard. The resulting yEnc article must stay
    /// below the provider's article-size limit (typically 1 MB).
    pub shard_size: usize,
    /// Maximum data shards per stripe (>= 1).
    pub max_data_shards: usize,
    /// Requested redundancy, default 30% (3 parity shards for 10 data shards).
    pub redundancy_percent: u8,
    pub compression_level: i32,
    /// Fetch every posted article back and compare its hash before committing.
    pub verify_after_post: bool,
    /// Extra shards beyond the reconstruction threshold that must be verified.
    pub durability_margin: usize,
    /// Health-check interval hint in seconds (workers read it from settings).
    pub health_check_interval_secs: u64,
    /// Refresh articles this many days before the provider's retention limit.
    pub retention_safety_margin_days: u32,
}

impl Default for StorageConfig {
    fn default() -> Self {
        Self {
            chunks: ChunkConfig::default(),
            shard_size: 512 * 1024,
            max_data_shards: 10,
            redundancy_percent: 30,
            compression_level: 3,
            verify_after_post: true,
            durability_margin: 1,
            health_check_interval_secs: 6 * 60 * 60,
            retention_safety_margin_days: 7,
        }
    }
}

impl StorageConfig {
    pub fn validate(&self) -> Result<(), String> {
        self.chunks.validate()?;
        if !(64 * 1024..=4 * 1024 * 1024).contains(&self.shard_size) {
            return Err("shard_size must be 64 KiB..=4 MiB".into());
        }
        if !(1..=32).contains(&self.max_data_shards) {
            return Err("max_data_shards must be 1..=32".into());
        }
        if self.max_data_shards > 250 {
            return Err("max_data_shards exceeds Reed-Solomon field limit".into());
        }
        if self.redundancy_percent == 0 || self.redundancy_percent > 100 {
            return Err("redundancy_percent must be 1..=100".into());
        }
        Ok(())
    }

    pub fn parity_for(&self, data_shards: usize) -> usize {
        let p = (data_shards * self.redundancy_percent as usize).div_ceil(100);
        p.max(1)
    }
}
