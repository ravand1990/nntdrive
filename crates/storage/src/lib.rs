//! NNTDrive storage engine.
//!
//! Pipeline: content-defined chunking -> optional zstd -> client-side
//! XChaCha20-Poly1305 -> Reed-Solomon -> yEnc articles on Usenet. Metadata lives
//! in PostgreSQL. Repair and retention operate on ciphertext only.

pub mod chunker;
pub mod config;
pub mod engine;
pub mod erasure;
pub mod manifest;
pub mod store;

pub use chunker::{Chunk, ChunkStream};
pub use config::{ChunkConfig, StorageConfig};
pub use engine::{
    prepare_chunk, Context, DownloadStats, FileHealth, PreparedChunk, RefreshReport, RepairReport,
    Storage, StorageError, StripeHealth, UploadOutcome, UploadStats,
};
pub use manifest::{ChunkEntry, Compression, FileManifest, StripeEntry, MANIFEST_VERSION};
pub use store::{ChunkRow, PlatformTotals, ShardRow, Store, StoreError, StripeRow, TestDb};
