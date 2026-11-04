//! Offline recovery kit.
//!
//! The recovery kit is the only artefact a user must store outside the backend.
//! It contains the AMK wrapped by a high-entropy recovery code (Argon2id) plus
//! the account id and key epoch. It is deliberately small and self-contained so
//! it can be printed, stored in a safe, or kept on offline media.

pub use crate::base32::decode_recovery_code;
use crate::base32::encode_recovery_code;
use crate::envelope::{open, seal, Envelope};
use crate::{CryptoError, KdfParams, MasterKey, Result, SecretKey, KEY_LEN};
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
}

impl RecoveryKit {
    pub const VERSION: u8 = 1;

    /// Returns the kit (safe to store on the server as an extra copy, because
    /// it is encrypted) and the recovery code (must be stored offline by the
    /// user and is shown exactly once).
    pub fn create(master: &MasterKey, note: Option<String>) -> Result<(Self, String)> {
        let mut code_bytes = [0u8; RECOVERY_CODE_LEN];
        OsRng.fill_bytes(&mut code_bytes);
        let code_secret = SecretKey::from_bytes(code_bytes);
        let code = encode_recovery_code(code_secret.as_bytes());

        let kdf = KdfParams::generate();
        let kek = kdf.derive(code.as_bytes())?;
        let wrapped = seal(
            &kek,
            &recovery_aad(master.account_id(), master.epoch()),
            master.expose_secret(),
        )?;
        Ok((
            Self {
                version: Self::VERSION,
                account_id: master.account_id(),
                epoch: master.epoch(),
                kdf,
                wrapped_master_key: wrapped,
                created_at: chrono::Utc::now(),
                note,
            },
            code,
        ))
    }

    pub fn unlock(&self, code: &str) -> Result<MasterKey> {
        if self.version != Self::VERSION {
            return Err(CryptoError::UnsupportedVersion(self.version));
        }
        let decoded = decode_recovery_code(code).ok_or(CryptoError::InvalidRecoveryCode)?;
        if decoded.len() != RECOVERY_CODE_LEN {
            return Err(CryptoError::InvalidRecoveryCode);
        }
        // Re-encode to normalise case/separators exactly as `create` did.
        let normalized = encode_recovery_code(&decoded);
        let kek = self.kdf.derive(normalized.as_bytes())?;
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
}
