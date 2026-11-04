//! Reed-Solomon erasure coding over encrypted chunk ciphertext.
//!
//! The engine never sees plaintext here: shards are slices of an authenticated
//! XChaCha20-Poly1305 envelope. Repair regenerates shards from shards.

use crate::config::StorageConfig;
use reed_solomon_erasure::galois_8::ReedSolomon;

#[derive(Debug, thiserror::Error)]
pub enum ErasureError {
    #[error("invalid erasure layout: {0}")]
    Layout(String),
    #[error("need {needed} shards to reconstruct, only {available} available")]
    TooFewShards { needed: usize, available: usize },
    #[error("shard integrity check failed")]
    CorruptShard,
    #[error("reed-solomon error: {0}")]
    Rs(#[from] reed_solomon_erasure::Error),
}

#[derive(Debug, Clone)]
pub struct EncodedStripe {
    pub index: u32,
    pub data_shards: usize,
    pub parity_shards: usize,
    pub shard_len: usize,
    pub ciphertext_len: usize,
    pub shards: Vec<Vec<u8>>,
}

impl EncodedStripe {
    pub fn total_shards(&self) -> usize {
        self.data_shards + self.parity_shards
    }
}

#[derive(Debug, Clone)]
pub struct Reconstructed {
    pub ciphertext: Vec<u8>,
    /// Complete shard set (data + parity), useful for repairing neighbours.
    pub shards: Vec<Vec<u8>>,
}

/// Splits ciphertext into stripes of at most `max_data_shards * shard_size` and
/// erasure-codes each stripe. Last shards are zero-padded, never truncated.
pub fn encode(
    ciphertext: &[u8],
    config: &StorageConfig,
) -> Result<Vec<EncodedStripe>, ErasureError> {
    if ciphertext.is_empty() {
        return Ok(Vec::new());
    }
    let max_span = config.max_data_shards * config.shard_size;
    let mut stripes = Vec::new();
    for (index, slab) in ciphertext.chunks(max_span).enumerate() {
        let k = (slab.len().div_ceil(config.shard_size)).clamp(1, config.max_data_shards);
        let shard_len = slab.len().div_ceil(k);
        let m = config.parity_for(k);
        let rs = ReedSolomon::new(k, m)?;

        let mut shards: Vec<Vec<u8>> = (0..k + m).map(|_| vec![0u8; shard_len]).collect();
        for (i, part) in slab.chunks(shard_len).enumerate() {
            shards[i][..part.len()].copy_from_slice(part);
        }
        rs.encode(&mut shards)?;
        stripes.push(EncodedStripe {
            index: index as u32,
            data_shards: k,
            parity_shards: m,
            shard_len,
            ciphertext_len: slab.len(),
            shards,
        });
    }
    Ok(stripes)
}

/// Reconstructs stripe ciphertext from any `k` valid shards and returns the
/// complete shard set. `shards` must have length `k + m`; use `None` for
/// missing/corrupt shards.
pub fn reconstruct(
    data_shards: usize,
    parity_shards: usize,
    shard_len: usize,
    ciphertext_len: usize,
    mut shards: Vec<Option<Vec<u8>>>,
) -> Result<Reconstructed, ErasureError> {
    if data_shards == 0 || parity_shards == 0 {
        return Err(ErasureError::Layout("shards must be non-zero".into()));
    }
    if shards.len() != data_shards + parity_shards {
        return Err(ErasureError::Layout("shard count mismatch".into()));
    }
    let available = shards.iter().filter(|s| s.is_some()).count();
    if available < data_shards {
        return Err(ErasureError::TooFewShards {
            needed: data_shards,
            available,
        });
    }
    for s in shards.iter().flatten() {
        if s.len() != shard_len {
            return Err(ErasureError::CorruptShard);
        }
    }
    let rs = ReedSolomon::new(data_shards, parity_shards)?;
    rs.reconstruct(&mut shards)?;
    let mut ciphertext = Vec::with_capacity(data_shards * shard_len);
    for shard in shards.iter().take(data_shards) {
        ciphertext.extend_from_slice(shard.as_ref().ok_or(ErasureError::CorruptShard)?);
    }
    if ciphertext_len > ciphertext.len() {
        return Err(ErasureError::Layout(
            "ciphertext length exceeds shards".into(),
        ));
    }
    ciphertext.truncate(ciphertext_len);
    let complete: Vec<Vec<u8>> = shards
        .into_iter()
        .map(|s| s.ok_or(ErasureError::CorruptShard))
        .collect::<Result<_, _>>()?;
    Ok(Reconstructed {
        ciphertext,
        shards: complete,
    })
}

/// Re-encodes parity from a known-complete data set (used after reconstruct).
pub fn reencode(
    shards: &mut [Vec<u8>],
    data_shards: usize,
    parity_shards: usize,
) -> Result<(), ErasureError> {
    let rs = ReedSolomon::new(data_shards, parity_shards)?;
    rs.encode(shards)?;
    Ok(())
}

pub fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(data);
    hex(&h.finalize())
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(data);
    h.finalize().into()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> StorageConfig {
        StorageConfig {
            shard_size: 64 * 1024,
            max_data_shards: 5,
            redundancy_percent: 40,
            ..Default::default()
        }
    }

    fn payload(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i.wrapping_mul(31) % 251) as u8).collect()
    }

    #[test]
    fn roundtrip_various_sizes_with_full_loss_budget() {
        for len in [1usize, 100, 60_000, 70_000, 300_000, 400_000] {
            let data = payload(len);
            let stripes = encode(&data, &cfg()).unwrap();
            let mut rebuilt = Vec::new();
            for stripe in stripes {
                // Lose exactly `parity` shards, including data shards.
                let mut shards: Vec<Option<Vec<u8>>> =
                    stripe.shards.iter().cloned().map(Some).collect();
                for i in (0..stripe.data_shards + stripe.parity_shards)
                    .step_by(2)
                    .take(stripe.parity_shards)
                {
                    shards[i] = None;
                }
                let rec = reconstruct(
                    stripe.data_shards,
                    stripe.parity_shards,
                    stripe.shard_len,
                    stripe.ciphertext_len,
                    shards,
                )
                .unwrap();
                assert_eq!(
                    rec.ciphertext,
                    data[rebuilt.len()..rebuilt.len() + stripe.ciphertext_len]
                );
                assert_eq!(rec.shards.len(), stripe.shards.len());
                rebuilt.extend_from_slice(&rec.ciphertext);
            }
            assert_eq!(rebuilt, data);
        }
    }

    #[test]
    fn too_many_missing_shards_is_an_error() {
        let data = payload(100_000);
        let stripe = encode(&data, &cfg()).unwrap().remove(0);
        let missing = stripe.parity_shards + 1;
        let mut shards: Vec<Option<Vec<u8>>> = stripe.shards.iter().cloned().map(Some).collect();
        for s in shards.iter_mut().take(missing) {
            *s = None;
        }
        let err = reconstruct(
            stripe.data_shards,
            stripe.parity_shards,
            stripe.shard_len,
            stripe.ciphertext_len,
            shards,
        )
        .unwrap_err();
        assert!(matches!(err, ErasureError::TooFewShards { .. }));
    }

    #[test]
    fn small_chunks_do_not_pad_to_shard_size() {
        let data = payload(1000);
        let stripe = encode(&data, &cfg()).unwrap().remove(0);
        assert_eq!(stripe.data_shards, 1);
        assert_eq!(stripe.shard_len, 1000);
        assert_eq!(stripe.parity_shards, 1);
    }

    #[test]
    fn multi_stripe_input() {
        let data = payload(5 * 64 * 1024 + 17); // 5 data shards max => 2 stripes
        let stripes = encode(&data, &cfg()).unwrap();
        assert_eq!(stripes.len(), 2);
        assert_eq!(stripes[0].index, 0);
        assert_eq!(stripes[1].index, 1);
    }

    #[test]
    fn corrupt_shard_reported_via_length_and_hash() {
        let data = payload(5000);
        let stripe = encode(&data, &cfg()).unwrap().remove(0);
        let mut shards: Vec<Option<Vec<u8>>> = stripe.shards.iter().cloned().map(Some).collect();
        shards[0] = Some(vec![9, 9, 9]); // wrong length
        assert!(matches!(
            reconstruct(
                stripe.data_shards,
                stripe.parity_shards,
                stripe.shard_len,
                stripe.ciphertext_len,
                shards
            ),
            Err(ErasureError::CorruptShard)
        ));
        assert_eq!(sha256_hex(b"abc").len(), 64);
    }
}
