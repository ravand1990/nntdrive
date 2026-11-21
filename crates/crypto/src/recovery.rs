//! Offline recovery kit.
//!
//! The recovery kit is the only artefact a user must store outside the backend.
//! It contains the AMK wrapped by a high-entropy recovery code (Argon2id) plus
//! the account id and key epoch. It is deliberately small and self-contained so
//! it can be printed, stored in a safe, or kept on offline media.

pub use crate::base32::decode_recovery_code;
use crate::base32::encode_recovery_code;
use crate::envelope::{open, seal, Envelope};
use crate::{
    CryptoError, KdfParams, MasterKey, MasterKeyRing, Result, RetainedEpoch, SecretKey, KEY_LEN,
};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const RECOVERY_CODE_LEN: usize = KEY_LEN;

fn recovery_aad(account_id: Uuid, epoch: u32) -> Vec<u8> {
    let mut aad = b"nntdrive/v1/recovery-kit".to_vec();
    aad.extend_from_slice(account_id.as_bytes());
    aad.extend_from_slice(&epoch.to_be_bytes());
    aad
}

/// Decodes and re-encodes a recovery code so case and separators normalise
/// exactly as the code was produced.
fn normalize_code(code: &str) -> Result<String> {
    let decoded = decode_recovery_code(code).ok_or(CryptoError::InvalidRecoveryCode)?;
    if decoded.len() != RECOVERY_CODE_LEN {
        return Err(CryptoError::InvalidRecoveryCode);
    }
    Ok(encode_recovery_code(&decoded))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryKit {
    pub version: u8,
    pub account_id: Uuid,
    pub epoch: u32,
    pub kdf: KdfParams,
    pub wrapped_master_key: Envelope,
    pub created_at: chrono::DateTime<chrono::Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// Older AMK epochs, oldest first, wrapped under the same recovery code.
    /// A kit minted before a rotation has none; a kit minted afterwards keeps
    /// them so a recovery can still read revisions sealed before the rotation.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub retained: Vec<RetainedEpoch>,
}

impl RecoveryKit {
    pub const VERSION: u8 = 1;

    /// Returns the kit (safe to store on the server as an extra copy, because
    /// it is encrypted) and the recovery code (must be stored offline by the
    /// user and is shown exactly once).
    pub fn create(master: &MasterKey, note: Option<String>) -> Result<(Self, String)> {
        Self::create_with_ring(&MasterKeyRing::from(master.clone()), note)
    }

    /// Like [`Self::create`], but wraps every epoch of an unlocked ring so a
    /// recovery can still read revisions sealed before a rotation.
    pub fn create_with_ring(ring: &MasterKeyRing, note: Option<String>) -> Result<(Self, String)> {
        let mut code_bytes = [0u8; RECOVERY_CODE_LEN];
        OsRng.fill_bytes(&mut code_bytes);
        let code = encode_recovery_code(SecretKey::from_bytes(code_bytes).as_bytes());
        Self::seal_ring(ring, note, code)
    }

    /// Mints a kit for the next epoch after a rotation and keeps every epoch the
    /// current kit could restore, so revisions written before the rotation stay
    /// readable from the new kit.
    ///
    /// The current recovery code is required: a rotation cannot re-wrap an
    /// existing kit without it. A wrong code fails before anything is created,
    /// and the returned code is a fresh one that must be shown once and stored
    /// offline.
    pub fn rotate(
        &self,
        code: &str,
        rotated: &MasterKey,
        note: Option<String>,
    ) -> Result<(Self, String)> {
        if rotated.account_id() != self.account_id {
            return Err(CryptoError::Malformed(
                "master key belongs to another account",
            ));
        }
        if rotated.epoch() != self.epoch + 1 {
            return Err(CryptoError::Malformed(
                "rotated master key must be exactly the next epoch",
            ));
        }
        // Unlocking first validates the code and every retained epoch; a wrong
        // code must fail here, before a new kit is minted.
        let ring = self.unlock_ring(code).map_err(|e| match e {
            CryptoError::Authentication => CryptoError::InvalidRecoveryCode,
            other => other,
        })?;
        // The epoch this kit was minted for becomes a retained epoch of the new
        // kit, so pre-rotation revisions stay restorable.
        let mut previous = ring.previous().to_vec();
        previous.push(ring.current().clone());
        let ring = MasterKeyRing::from_parts(rotated.clone(), previous);
        Self::create_with_ring(&ring, note)
    }

    /// Reports a kit minted for an older epoch than the account is on now.
    ///
    /// Call this with the epoch of the account's published keyfile before using
    /// a kit for a restore, so a kit from before a rotation gives an actionable
    /// message instead of an unexplained decrypt failure.
    pub fn check_epoch(&self, current_epoch: u32) -> Result<()> {
        if self.epoch == current_epoch {
            return Ok(());
        }
        if self.epoch < current_epoch {
            return Err(CryptoError::StaleRecoveryKit {
                kit_epoch: self.epoch,
                current_epoch,
            });
        }
        Err(CryptoError::Malformed(
            "recovery kit is ahead of the account key epoch",
        ))
    }

    fn seal_ring(
        ring: &MasterKeyRing,
        note: Option<String>,
        code: String,
    ) -> Result<(Self, String)> {
        let normalized = normalize_code(&code)?;
        let kdf = KdfParams::generate();
        let kek = kdf.derive(normalized.as_bytes())?;
        let current = ring.current();
        let wrapped = seal(
            &kek,
            &recovery_aad(current.account_id(), current.epoch()),
            current.expose_secret(),
        )?;
        let mut retained = Vec::with_capacity(ring.previous().len());
        for master in ring.previous() {
            if master.epoch() >= current.epoch() {
                return Err(CryptoError::Malformed("retained epoch is not older"));
            }
            retained.push(RetainedEpoch {
                epoch: master.epoch(),
                wrapped_master_key: seal(
                    &kek,
                    &recovery_aad(current.account_id(), master.epoch()),
                    master.expose_secret(),
                )?,
                retired_at: chrono::Utc::now(),
            });
        }
        retained.sort_by_key(|r| r.epoch);
        Ok((
            Self {
                version: Self::VERSION,
                account_id: current.account_id(),
                epoch: current.epoch(),
                kdf,
                wrapped_master_key: wrapped,
                created_at: chrono::Utc::now(),
                note,
                retained,
            },
            code,
        ))
    }

    fn kek_for(&self, code: &str) -> Result<SecretKey> {
        let normalized = normalize_code(code)?;
        self.kdf.derive(normalized.as_bytes())
    }

    pub fn unlock(&self, code: &str) -> Result<MasterKey> {
        if self.version != Self::VERSION {
            return Err(CryptoError::UnsupportedVersion(self.version));
        }
        let kek = self.kek_for(code)?;
        let bytes = open(
            &kek,
            &recovery_aad(self.account_id, self.epoch),
            &self.wrapped_master_key,
        )?;
        Ok(MasterKey::from_secret(
            self.account_id,
            self.epoch,
            SecretKey::from_slice(&bytes)?,
        ))
    }

    /// Unlocks the current and every retained epoch the kit carries.
    pub fn unlock_ring(&self, code: &str) -> Result<MasterKeyRing> {
        if self.version != Self::VERSION {
            return Err(CryptoError::UnsupportedVersion(self.version));
        }
        let kek = self.kek_for(code)?;
        let bytes = open(
            &kek,
            &recovery_aad(self.account_id, self.epoch),
            &self.wrapped_master_key,
        )?;
        let current =
            MasterKey::from_secret(self.account_id, self.epoch, SecretKey::from_slice(&bytes)?);
        let mut previous = Vec::with_capacity(self.retained.len());
        for entry in &self.retained {
            if entry.epoch >= self.epoch {
                return Err(CryptoError::Malformed("retained epoch is not older"));
            }
            let bytes = open(
                &kek,
                &recovery_aad(self.account_id, entry.epoch),
                &entry.wrapped_master_key,
            )?;
            previous.push(MasterKey::from_secret(
                self.account_id,
                entry.epoch,
                SecretKey::from_slice(&bytes)?,
            ));
        }
        Ok(MasterKeyRing::from_parts(current, previous))
    }

    pub fn to_json_pretty(&self) -> Result<String> {
        Ok(serde_json::to_string_pretty(self)?)
    }

    pub fn from_json(s: &str) -> Result<Self> {
        Ok(serde_json::from_str(s)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::KeyFile;

    #[test]
    fn recovery_kit_roundtrip() {
        let master = MasterKey::generate(Uuid::new_v4(), 4);
        let (kit, code) = RecoveryKit::create(&master, Some("printed 2026-11-04".into())).unwrap();
        let restored = kit.unlock(&code).unwrap();
        assert_eq!(restored.expose_secret(), master.expose_secret());
        assert_eq!(restored.epoch(), 4);

        // Case-insensitive, separators optional.
        assert!(kit.unlock(&code.to_lowercase().replace('-', " ")).is_ok());
    }

    #[test]
    fn wrong_or_malformed_code_fails() {
        let master = MasterKey::generate(Uuid::new_v4(), 0);
        let (kit, code) = RecoveryKit::create(&master, None).unwrap();
        let mut chars: Vec<char> = code.chars().collect();
        // Flip the last base32 character.
        let last = chars.len() - 1;
        chars[last] = if chars[last] == 'A' { 'B' } else { 'A' };
        let wrong: String = chars.into_iter().collect();
        assert!(kit.unlock(&wrong).is_err());
        assert!(kit.unlock("garbage").is_err());
        assert!(matches!(
            kit.unlock("NNTR-"),
            Err(CryptoError::InvalidRecoveryCode)
        ));
    }

    #[test]
    fn kit_json_and_tamper() {
        let master = MasterKey::generate(Uuid::new_v4(), 1);
        let (kit, code) = RecoveryKit::create(&master, None).unwrap();
        let json = kit.to_json_pretty().unwrap();
        assert!(!json.contains(&code));
        let mut loaded = RecoveryKit::from_json(&json).unwrap();
        assert!(loaded.unlock(&code).is_ok());
        loaded.wrapped_master_key.ciphertext[0] ^= 1;
        assert!(loaded.unlock(&code).is_err());
    }

    #[test]
    fn legacy_kit_json_without_retained_epochs_still_unlocks() {
        let master = MasterKey::generate(Uuid::new_v4(), 2);
        let (kit, code) = RecoveryKit::create(&master, None).unwrap();
        let mut value = serde_json::to_value(&kit).unwrap();
        // A kit minted before this change carries no `retained` field at all.
        value.as_object_mut().unwrap().remove("retained");
        let loaded = RecoveryKit::from_json(&value.to_string()).unwrap();
        assert!(loaded.retained.is_empty());
        assert_eq!(loaded.unlock(&code).unwrap().epoch(), 2);
        assert_eq!(
            loaded
                .unlock_ring(&code)
                .unwrap()
                .epochs()
                .collect::<Vec<_>>(),
            vec![2]
        );
    }

    #[test]
    fn kit_after_rotation_restores_revisions_sealed_before_and_after() {
        let account = Uuid::new_v4();
        let (keyfile, master) = KeyFile::create("pw", account).unwrap();
        let node = Uuid::new_v4();
        let old_name = master.seal_name(node, "before rotation.txt").unwrap();
        let (rotated_keyfile, rotated_master) = keyfile.rotate(&master, "pw").unwrap();

        // The post-rotation kit carries both epochs and a fresh code.
        let ring = rotated_keyfile.unlock_ring("pw").unwrap();
        let (kit, code) = RecoveryKit::create_with_ring(&ring, None).unwrap();
        assert_eq!(kit.epoch, 1);
        assert_eq!(kit.retained.len(), 1);

        let new_name = rotated_master
            .seal_name(node, "after rotation.txt")
            .unwrap();
        let recovered = kit.unlock_ring(&code).unwrap();
        assert_eq!(recovered.epochs().collect::<Vec<_>>(), vec![1, 0]);
        assert_eq!(
            recovered.open_name(node, &old_name).unwrap(),
            "before rotation.txt"
        );
        assert_eq!(
            recovered.open_name(node, &new_name).unwrap(),
            "after rotation.txt"
        );

        // A kit minted for the old epoch alone cannot read post-rotation names.
        let (stale_kit, stale_code) = RecoveryKit::create(&master, None).unwrap();
        let stale_ring = stale_kit.unlock_ring(&stale_code).unwrap();
        assert!(stale_ring.open_name(node, &new_name).is_err());
    }

    #[test]
    fn rotating_a_kit_keeps_retained_epochs_and_needs_the_current_code() {
        let account = Uuid::new_v4();
        let (keyfile, master) = KeyFile::create("pw", account).unwrap();
        let (kit, code) = RecoveryKit::create(&master, None).unwrap();
        let (rotated_keyfile, rotated_master) = keyfile.rotate(&master, "pw").unwrap();

        // A wrong code fails before anything is minted.
        let wrong = code.chars().rev().collect::<String>();
        assert!(matches!(
            kit.rotate(&wrong, &rotated_master, None),
            Err(CryptoError::InvalidRecoveryCode)
        ));

        // A key that is not exactly the next epoch is refused.
        assert!(kit.rotate(&code, &master, None).is_err());
        let other_account = MasterKey::generate(Uuid::new_v4(), 1);
        assert!(kit.rotate(&code, &other_account, None).is_err());

        let (rotated_kit, rotated_code) = kit.rotate(&code, &rotated_master, None).unwrap();
        assert_ne!(rotated_code, code);
        assert_eq!(rotated_kit.epoch, 1);
        assert_eq!(rotated_kit.retained.len(), 1);
        assert_eq!(rotated_kit.retained[0].epoch, 0);
        assert_eq!(
            rotated_kit
                .unlock_ring(&rotated_code)
                .unwrap()
                .epochs()
                .collect::<Vec<_>>(),
            vec![1, 0]
        );
        // The old kit's code does not open the new kit.
        assert!(rotated_kit.unlock(&code).is_err());
        assert_eq!(
            rotated_keyfile.epoch, rotated_kit.epoch,
            "kit and keyfile epochs must agree"
        );
    }

    #[test]
    fn stale_kit_is_reported_with_an_actionable_message() {
        let master = MasterKey::generate(Uuid::new_v4(), 0);
        let (kit, _) = RecoveryKit::create(&master, None).unwrap();
        assert!(kit.check_epoch(0).is_ok());
        let err = kit.check_epoch(2).unwrap_err();
        assert!(matches!(
            err,
            CryptoError::StaleRecoveryKit {
                kit_epoch: 0,
                current_epoch: 2
            }
        ));
        let message = err.to_string();
        assert!(message.contains("epoch 0"));
        assert!(message.contains("epoch 2"));
        assert!(message.contains("rotation"));
        // A kit newer than the account key is malformed rather than stale.
        assert!(kit.check_epoch(0).is_ok());
        let ahead = RecoveryKit {
            epoch: 3,
            ..kit.clone()
        };
        assert!(ahead.check_epoch(1).is_err());
    }

    #[test]
    fn restored_keyfile_from_a_ring_keeps_every_epoch() {
        let account = Uuid::new_v4();
        let (keyfile, master) = KeyFile::create("old-pw", account).unwrap();
        let (_, rotated_master) = keyfile.rotate(&master, "old-pw").unwrap();
        let ring = MasterKeyRing::from_parts(rotated_master.clone(), vec![master.clone()]);

        let restored = KeyFile::from_ring(&ring, "new-pw").unwrap();
        assert_eq!(restored.epoch, 1);
        assert_eq!(restored.retained.len(), 1);
        let unlocked = restored.unlock_ring("new-pw").unwrap();
        assert_eq!(unlocked.epochs().collect::<Vec<_>>(), vec![1, 0]);
        assert!(restored.unlock("old-pw").is_err());
    }
}
