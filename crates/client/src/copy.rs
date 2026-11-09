//! Authenticated preparation and guarded publication for bounded file Copy.
//! Separate create/commit requests are never used as a Copy fallback.
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
    pub chunk_ids: Vec<Uuid>,
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
        chunk_ids: copied.chunks.iter().map(|c| c.id).collect(),
        name_enc: master.seal_name(file_id, &name)?.to_bytes(),
        sealed_manifest: master
            .seal_manifest(file_id, revision_id, &copied.to_bytes())?
            .to_bytes(),
    })
}

pub(super) fn portable_component(name: &str) -> bool {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.ends_with([' ', '.'])
        || name
            .chars()
            .any(|c| c.is_control() || "<>:\"/\\|?*".contains(c))
    {
        return false;
    }
    let stem = name
        .split('.')
        .next()
        .unwrap_or("")
        .trim_end_matches(' ')
        .to_lowercase();
    if matches!(stem.as_str(), "con" | "prn" | "aux" | "nul") {
        return false;
    }
    for prefix in ["com", "lpt"] {
        if let Some(suffix) = stem.strip_prefix(prefix) {
            if matches!(
                suffix,
                "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
            ) {
                return false;
            }
        }
    }
    true
}

impl crate::ApiClient {
    /// Copy one current encrypted file into a freshly checked destination.
    /// No automatic retries: an ambiguous response requires refreshing the tree.
    /// Same-folder copies collide intentionally; rename-copy UI is not provided.
    pub async fn copy_file_checked(
        &self,
        master: &MasterKey,
        source: &crate::FileDto,
        parent: Option<Uuid>,
    ) -> Result<(Uuid, Uuid)> {
        use base64::Engine;
        use unicode_normalization::UnicodeNormalization;
        let decode = |s: &str| {
            base64::engine::general_purpose::STANDARD
                .decode(s)
                .map_err(|_| ClientError::Protocol("invalid encrypted name".into()))
        };
        let invalid = || ClientError::Integrity("invalid copy namespace".into());
        if source.is_dir {
            return Err(invalid());
        }
        let revision = source.current_version.ok_or_else(invalid)?;
        let source_name = decode(&source.name_enc)?;
        let name = master.open_name(source.id, &Envelope::from_bytes(&source_name)?)?;
        // Reuse the sync engine's portable relative component validator.
        nntdrive_sync::scanner::validate_relative_path(&name).map_err(|_| invalid())?;
        if !portable_component(&name) {
            return Err(invalid());
        }
        let key = |s: &str| {
            s.nfc()
                .collect::<String>()
                .to_lowercase()
                .nfc()
                .collect::<String>()
        };
        let siblings = self.list_files(parent).await?;
        if siblings.len() > 4096 {
            return Err(invalid());
        }
        let mut seen = std::collections::BTreeSet::new();
        for sibling in &siblings {
            let bytes = decode(&sibling.name_enc)?;
            let plain = master.open_name(sibling.id, &Envelope::from_bytes(&bytes)?)?;
            if !portable_component(&plain) {
                return Err(invalid());
            }
            let comparison = key(&plain);
            if comparison == key(&name) || !seen.insert(comparison) {
                return Err(invalid());
            }
        }
        let (manifest, actual_revision) = self.manifest(source.id, Some(revision)).await?;
        if actual_revision != revision {
            return Err(invalid());
        }
        let candidate = prepare_file_copy(master, source.id, revision, &source_name, &manifest)?;
        if candidate.chunk_ids.len() > 4096 || candidate.sealed_manifest.len() > 1024 * 1024 {
            return Err(invalid());
        }
        let response = self.auth(self.http.post(self.url(&format!("/files/{}/copy-checked", source.id))))
            .json(&serde_json::json!({
                "source_revision": revision, "source_parent_id": source.parent_id,
                "source_name_enc": source.name_enc, "parent_id": parent,
                "siblings": siblings.iter().map(|s| serde_json::json!({"id":s.id,"name_enc":s.name_enc})).collect::<Vec<_>>(),
                "id":candidate.file_id,"revision_id":candidate.revision_id,"size":candidate.size,
                "name_enc":crate::b64(&candidate.name_enc), "sealed_manifest":crate::b64(&candidate.sealed_manifest),
                "chunk_ids":candidate.chunk_ids,
            })).send().await?;
        self.check(response).await?;
        Ok((candidate.file_id, candidate.revision_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_portable_components_fail_closed() {
        for name in [
            "",
            ".",
            "..",
            "../x",
            "a/b",
            "a\\b",
            "NUL .txt",
            "COM¹.txt",
            "lpt9",
            "x.",
            "x ",
            "bad?",
            "a\0b",
            "x:y",
        ] {
            assert!(!portable_component(name));
        }
        for name in ["Café.txt", "file😀", "COM10", "NULish", "a.b"] {
            assert!(portable_component(name));
        }
    }

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
