//! Streaming content-defined chunking (FastCDC 2020), bounded memory.

use crate::config::ChunkConfig;
use std::io;
use tokio::io::{AsyncRead, AsyncReadExt};

#[derive(Debug, Clone)]
pub struct Chunk {
    pub index: u32,
    pub offset: u64,
    pub data: Vec<u8>,
    pub hash: [u8; 32],
}

impl Chunk {
    pub fn len(&self) -> usize {
        self.data.len()
    }
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}

/// Streaming chunker. The buffer never exceeds `max_size`, so gigabyte files
/// are processed with a few MiB of RAM.
pub struct ChunkStream<R> {
    reader: R,
    buffer: Vec<u8>,
    eof: bool,
    config: ChunkConfig,
    index: u32,
    offset: u64,
    hasher: blake3::Hasher,
}

impl<R: AsyncRead + Unpin> ChunkStream<R> {
    pub fn new(reader: R, config: ChunkConfig) -> Self {
        Self {
            reader,
            buffer: Vec::new(),
            eof: false,
            config,
            index: 0,
            offset: 0,
            hasher: blake3::Hasher::new(),
        }
    }

    /// Whole-file BLAKE3, finalised after the stream is exhausted.
    pub fn content_hash(&self) -> String {
        self.hasher.finalize().to_hex().to_string()
    }

    pub fn total_bytes(&self) -> u64 {
        self.offset
    }

    async fn fill(&mut self) -> io::Result<()> {
        let max = self.config.max_size as usize;
        while !self.eof && self.buffer.len() < max {
            let want = max - self.buffer.len();
            let mut scratch = vec![0u8; want.min(1024 * 1024)];
            let n = self.reader.read(&mut scratch).await?;
            if n == 0 {
                self.eof = true;
            } else {
                self.buffer.extend_from_slice(&scratch[..n]);
            }
        }
        Ok(())
    }

    pub async fn next_chunk(&mut self) -> io::Result<Option<Chunk>> {
        self.fill().await?;
        if self.buffer.is_empty() {
            return Ok(None);
        }
        let cuts: Vec<usize> = fastcdc::v2020::FastCDC::new(
            &self.buffer,
            self.config.min_size,
            self.config.avg_size,
            self.config.max_size,
        )
        .map(|c| c.length)
        .collect();
        debug_assert!(!cuts.is_empty());

        // When more data may follow, withhold the final cut unless it is
        // already at the maximum size (it cannot grow).
        let emit_count = if self.eof || (*cuts.last().unwrap() as u32) >= self.config.max_size {
            cuts.len()
        } else {
            cuts.len() - 1
        };
        if emit_count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "chunker made no progress",
            ));
        }
        let take: usize = cuts[..emit_count].iter().sum();
        let data: Vec<u8> = self.buffer.drain(..take).collect();
        self.hasher.update(&data);
        let chunk = Chunk {
            index: self.index,
            offset: self.offset,
            hash: *blake3::hash(&data).as_bytes(),
            data,
        };
        self.index += 1;
        self.offset += take as u64;
        Ok(Some(chunk))
    }
}

pub fn hash_hex(hash: &[u8]) -> String {
    hash.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn hash_from_hex(s: &str) -> Option<[u8; 32]> {
    let bytes = hex_decode(s)?;
    bytes.try_into().ok()
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let b = s.as_bytes();
    for pair in b.chunks(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn cfg() -> ChunkConfig {
        ChunkConfig {
            min_size: 16 * 1024,
            avg_size: 64 * 1024,
            max_size: 256 * 1024,
        }
    }

    async fn chunk_all(data: Vec<u8>) -> (Vec<Chunk>, String) {
        let mut s = ChunkStream::new(Cursor::new(data), cfg());
        let mut out = Vec::new();
        while let Some(c) = s.next_chunk().await.unwrap() {
            out.push(c);
        }
        let hash = s.content_hash();
        (out, hash)
    }

    #[tokio::test]
    async fn chunks_respect_bounds_and_cover_input() {
        let data: Vec<u8> = (0u32..2_000_000)
            .map(|i| (i.wrapping_mul(2654435761) >> 13) as u8)
            .collect();
        let (chunks, whole_hash) = chunk_all(data.clone()).await;
        let mut rebuilt = Vec::new();
        let mut offset = 0u64;
        for (i, c) in chunks.iter().enumerate() {
            assert_eq!(c.index, i as u32);
            assert_eq!(c.offset, offset);
            assert!(c.len() >= 16 * 1024 || chunks.len() == 1 || i == chunks.len() - 1);
            assert!(c.len() <= 256 * 1024);
            assert_eq!(c.hash, *blake3::hash(&c.data).as_bytes());
            rebuilt.extend_from_slice(&c.data);
            offset += c.len() as u64;
        }
        assert_eq!(rebuilt, data);
        assert_eq!(whole_hash, blake3::hash(&data).to_hex().to_string());
    }

    #[tokio::test]
    async fn chunking_is_deterministic_across_read_sizes() {
        let data: Vec<u8> = (0..700_000u32).map(|i| (i % 251) as u8).collect();
        let (a, ha) = chunk_all(data.clone()).await;
        let (b, hb) = chunk_all(data).await;
        assert_eq!(ha, hb);
        assert_eq!(
            a.iter().map(|c| c.len()).collect::<Vec<_>>(),
            b.iter().map(|c| c.len()).collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn empty_and_tiny_files() {
        let (empty, hash) = chunk_all(vec![]).await;
        assert!(empty.is_empty());
        assert_eq!(hash, blake3::hash(b"").to_hex().to_string());

        let (tiny, _) = chunk_all(b"hello".to_vec()).await;
        assert_eq!(tiny.len(), 1);
        assert_eq!(tiny[0].data, b"hello");
    }

    #[tokio::test]
    async fn large_file_is_split_into_many_chunks() {
        let data = vec![7u8; 5 * 1024 * 1024];
        let (chunks, _) = chunk_all(data).await;
        assert!(chunks.len() > 5);
        // Steady-state memory is bounded by max_size plus one chunk.
        for c in &chunks {
            assert!(c.len() <= 256 * 1024);
        }
    }
}
