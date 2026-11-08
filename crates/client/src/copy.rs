//! Local-only preparation for a future guarded Copy transaction.
//!
//! This does not publish a node or check destination collisions. Callers must not
//! use separate create/commit requests as an atomic Copy implementation.
use crate::{ClientError, Result};
use nntdrive_crypto::{Envelope, MasterKey};
use nntdrive_storage::manifest::FileManifest;
use uuid::Uuid;

/// Ciphertext-only candidate. Not serializable or Debug: avoid accidental logs.
pub struct PreparedFileCopy {
    pub file_id: Uuid,
    pub revision_id: Uuid,
    pub size: u64,
    pub name_enc: Vec<u8>,
    pub sealed_manifest: Vec<u8>,
}

/// Authenticate the source and re-encrypt its name and manifest for fresh IDs.
///
/// Version-1 content uses account-scoped content keys (ADR-002), not per-file
/// keys. Immutable chunk references can therefore be reused within this master
/// key's scope. No keys are copied or exported. A new file ID also has a distinct
/// derived per-file key, but that key is not used by v1 storage. This is NOT a
/// cross-account copy or an independently revocable encryption domain.
pub fn prepare_file_copy(
    master: &MasterKey,
    source_id: Uuid,
    source_revision: Uuid,
    source_name: &[u8],
    source_manifest: &[u8],
) -> Result<PreparedFileCopy> {
    let name = master.open_name(source_id, &Envelope::from_bytes(source_name)?)?;
    let plain = master.open_manifest(
        source_id,
        source_revision,
        &Envelope::from_bytes(source_manifest)?,
    )?;
    let source = FileManifest::from_bytes(&plain)
        .map_err(|_| ClientError::Integrity("invalid copy source manifest".into()))?;
    source
        .validate()
        .map_err(|_| ClientError::Integrity("invalid copy source manifest".into()))?;
    if source.file_id != source_id || source.revision_id != source_revision {
        return Err(ClientError::Integrity(
            "copy source identity mismatch".into(),
        ));
    }
    let file_id = Uuid::new_v4();
    let revision_id = Uuid::new_v4();
    let mut copied = FileManifest::new(file_id, revision_id, source.size, source.content_hash);
    copied.chunks = source.chunks;
    Ok(PreparedFileCopy {
        file_id,
        revision_id,
        size: copied.size,
        name_enc: master.seal_name(file_id, &name)?.to_bytes(),
        sealed_manifest: master
            .seal_manifest(file_id, revision_id, &copied.to_bytes())?
            .to_bytes(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_rebinds_authenticated_metadata_and_preserves_source() {
        let master = MasterKey::generate(Uuid::new_v4(), 0);
        let id = Uuid::new_v4();
        let revision = Uuid::new_v4();
        let mut source =
            FileManifest::new(id, revision, 1, blake3::hash(b"x").to_hex().to_string());
        source.chunks.push(nntdrive_storage::manifest::ChunkEntry {
            id: Uuid::new_v4(),
            index: 0,
            offset: 0,
            plaintext_len: 1,
            plaintext_hash: blake3::hash(b"x").to_hex().to_string(),
            ciphertext_len: 42,
            compression: nntdrive_storage::manifest::Compression::None,
            stripes: vec![nntdrive_storage::manifest::StripeEntry {
                id: Uuid::new_v4(),
                index: 0,
                data_shards: 1,
                parity_shards: 1,
                shard_len: 42,
                ciphertext_len: 42,
                shard_hashes: vec!["a".repeat(64), "b".repeat(64)],
            }],
        });
        let name = master.seal_name(id, "private name.txt").unwrap().to_bytes();
        let sealed = master
            .seal_manifest(id, revision, &source.to_bytes())
            .unwrap()
            .to_bytes();
        let candidate = prepare_file_copy(&master, id, revision, &name, &sealed).unwrap();
        assert_ne!(candidate.file_id, id);
        assert_ne!(candidate.revision_id, revision);
        let envelope = Envelope::from_bytes(&candidate.sealed_manifest).unwrap();
        let copied = FileManifest::from_bytes(
            &master
                .open_manifest(candidate.file_id, candidate.revision_id, &envelope)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(copied.file_id, candidate.file_id);
        assert_eq!(copied.revision_id, candidate.revision_id);
        assert_eq!(copied.content_hash, source.content_hash);
        assert_eq!(copied.chunks, source.chunks);
        assert_eq!(
            master
                .open_name(
                    candidate.file_id,
                    &Envelope::from_bytes(&candidate.name_enc).unwrap()
                )
                .unwrap(),
            "private name.txt"
        );
        assert!(master.open_manifest(id, revision, &envelope).is_err());
        assert!(master
            .open_name(id, &Envelope::from_bytes(&candidate.name_enc).unwrap())
            .is_err());
        assert_ne!(
            master
                .file_key(id)
                .unwrap()
                .chunk_key(0)
                .unwrap()
                .as_bytes(),
            master
                .file_key(candidate.file_id)
                .unwrap()
                .chunk_key(0)
                .unwrap()
                .as_bytes()
        );
        assert_eq!(
            master
                .open_manifest(id, revision, &Envelope::from_bytes(&sealed).unwrap())
                .unwrap(),
            source.to_bytes()
        );
        let other = MasterKey::generate(Uuid::new_v4(), 0);
        assert!(prepare_file_copy(&other, id, revision, &name, &sealed).is_err());
        assert!(prepare_file_copy(&master, Uuid::new_v4(), revision, &name, &sealed).is_err());
        let mut tampered = sealed.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert!(prepare_file_copy(&master, id, revision, &name, &tampered).is_err());
        let malformed = master
            .seal_manifest(id, revision, b"invalid")
            .unwrap()
            .to_bytes();
        assert!(prepare_file_copy(&master, id, revision, &name, &malformed).is_err());
        let mut mismatched = source.clone();
        mismatched.file_id = Uuid::new_v4();
        let invalid = master
            .seal_manifest(id, revision, &mismatched.to_bytes())
            .unwrap()
            .to_bytes();
        assert!(prepare_file_copy(&master, id, revision, &name, &invalid).is_err());
        let mut invalid_structure = source.clone();
        invalid_structure.size += 1;
        let invalid = master
            .seal_manifest(id, revision, &invalid_structure.to_bytes())
            .unwrap()
            .to_bytes();
        assert!(prepare_file_copy(&master, id, revision, &name, &invalid).is_err());
        let empty = FileManifest::new(id, revision, 0, blake3::hash(b"").to_hex().to_string());
        let sealed_empty = master
            .seal_manifest(id, revision, &empty.to_bytes())
            .unwrap()
            .to_bytes();
        let a = prepare_file_copy(&master, id, revision, &name, &sealed_empty).unwrap();
        let b = prepare_file_copy(&master, id, revision, &name, &sealed_empty).unwrap();
        assert_ne!(a.file_id, b.file_id);
        assert_ne!(a.revision_id, b.revision_id);
        assert_eq!(a.size, 0);
    }
}
