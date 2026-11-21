//! NNTDrive end-to-end encryption.
//!
//! # Key hierarchy
//!
//! ```text
//! user password ──Argon2id──> KEK ──wraps──> Account Master Key (AMK, random 256 bit)
//! recovery code ──Argon2id──> KEK ──wraps──> AMK            (recovery kit)
//! device X25519 key ──ECDH+HKDF──> KEK ──wraps──> AMK      (device enrollment)
//!
//! AMK ──HKDF("file-key" || file_id)──────> per-file key (32 byte)
//! per-file key ──HKDF("chunk" || index)──> per-chunk key (32 byte)
//! AMK ──HKDF("name-key")─────────────────> name encryption key
//! AMK ──HKDF("manifest-key")─────────────> manifest encryption key
//! ```
//!
//! The server only ever sees [`Envelope`] bytes, opaque node ids, sizes and
//! timestamps. Nothing in this crate is custom cryptography: XChaCha20-Poly1305,
//! Argon2id, HKDF-SHA256, BLAKE3 and X25519 come from audited RustCrypto /
//! dalek crates.
//!
//! # Rotation
//!
//! Removing a device requires generating a **new** AMK (a new epoch), wrapping
//! it for the remaining devices and using it for new content. Content already
//! encrypted under an old epoch cannot be made unreadable to a device that
//! already held that epoch's key; see `SECURITY.md`.

mod base32;
mod device;
mod envelope;
mod recovery;

pub use base32::{decode_recovery_code, encode_recovery_code};
pub use device::{open_enrollment, DeviceKeypair, DevicePublicKey, Keyring, SealedKey};
pub use envelope::Envelope;
pub use recovery::{RecoveryKit, RECOVERY_CODE_LEN};

use argon2::{Algorithm, Argon2, Params, Version};
use hkdf::Hkdf;
use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use uuid::Uuid;
use zeroize::{Zeroize, ZeroizeOnDrop};

pub const KEY_LEN: usize = 32;
pub const NONCE_LEN: usize = 24;
pub const SALT_LEN: usize = 16;

/// Default Argon2id cost. ~64 MiB, 3 iterations, single lane. Stored in the
/// keyfile so parameters can be raised later without breaking old files.
pub const ARGON2_M_COST_KIB: u32 = 64 * 1024;
pub const ARGON2_T_COST: u32 = 3;
pub const ARGON2_P_COST: u32 = 1;

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("authentication failed (wrong key, wrong password or tampered data)")]
    Authentication,
    #[error("unsupported format version {0}")]
    UnsupportedVersion(u8),
    #[error("malformed key material: {0}")]
    Malformed(&'static str),
    #[error("key derivation failed")]
    Kdf,
    #[error("serialization failed: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("base32 decode failed")]
    Base32,
    #[error("invalid recovery code")]
    InvalidRecoveryCode,
    #[error("recovery kit is for key epoch {kit_epoch} but the account is on epoch {current_epoch}; a kit created before a key rotation cannot restore content sealed afterwards. Create a new kit from a device that can still unlock the account and store the new recovery code offline")]
    StaleRecoveryKit { kit_epoch: u32, current_epoch: u32 },
}

pub type Result<T> = std::result::Result<T, CryptoError>;

/// 32 bytes of secret key material, zeroized on drop and never printable.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct SecretKey([u8; KEY_LEN]);

impl SecretKey {
    pub fn generate() -> Self {
        let mut bytes = [0u8; KEY_LEN];
        OsRng.fill_bytes(&mut bytes);
        Self(bytes)
    }

    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(bytes)
    }

    pub fn from_slice(bytes: &[u8]) -> Result<Self> {
        let arr: [u8; KEY_LEN] = bytes
            .try_into()
            .map_err(|_| CryptoError::Malformed("expected 32 bytes"))?;
        Ok(Self(arr))
    }

    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }

    /// Lowercase hex. Only for persistence into an OS secure store; never log.
    pub fn to_hex(&self) -> String {
        hex::encode(self.0)
    }

    pub fn from_hex(s: &str) -> Result<Self> {
        let bytes = hex::decode(s.trim()).map_err(|_| CryptoError::Malformed("bad hex"))?;
        Self::from_slice(&bytes)
    }
}

impl std::fmt::Debug for SecretKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SecretKey([redacted])")
    }
}

/// Length-prefixed HKDF info string, so `("a","bc")` and `("ab","c")` differ.
fn hkdf_info(label: &str, context: &[u8]) -> Vec<u8> {
    let mut info = Vec::with_capacity(4 + label.len() + 4 + context.len());
    info.extend_from_slice(&(label.len() as u32).to_be_bytes());
    info.extend_from_slice(label.as_bytes());
    info.extend_from_slice(&(context.len() as u32).to_be_bytes());
    info.extend_from_slice(context);
    info
}

fn hkdf_expand(ikm: &[u8], salt: &[u8], label: &str, context: &[u8]) -> Result<SecretKey> {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut out = [0u8; KEY_LEN];
    hk.expand(&hkdf_info(label, context), &mut out)
        .map_err(|_| CryptoError::Kdf)?;
    Ok(SecretKey(out))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct KdfParams {
    pub algorithm: String,
    #[serde(with = "b64")]
    pub salt: Vec<u8>,
    pub m_cost_kib: u32,
    pub t_cost: u32,
    pub p_cost: u32,
}

impl KdfParams {
    fn generate() -> Self {
        let mut salt = vec![0u8; SALT_LEN];
        OsRng.fill_bytes(&mut salt);
        Self {
            algorithm: "argon2id".into(),
            salt,
            m_cost_kib: ARGON2_M_COST_KIB,
            t_cost: ARGON2_T_COST,
            p_cost: ARGON2_P_COST,
        }
    }

    fn derive(&self, password: &[u8]) -> Result<SecretKey> {
        if self.algorithm != "argon2id" {
            return Err(CryptoError::Kdf);
        }
        let params = Params::new(self.m_cost_kib, self.t_cost, self.p_cost, Some(KEY_LEN))
            .map_err(|_| CryptoError::Kdf)?;
        let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
        let mut out = [0u8; KEY_LEN];
        argon
            .hash_password_into(password, &self.salt, &mut out)
            .map_err(|_| CryptoError::Kdf)?;
        Ok(SecretKey(out))
    }
}

/// One previous AMK epoch, still wrapped under the same password-derived key as
/// the current epoch. It is retained so revisions written before a rotation
/// stay readable; see [`KeyFile::rotate`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RetainedEpoch {
    pub epoch: u32,
    pub wrapped_master_key: Envelope,
    pub retired_at: chrono::DateTime<chrono::Utc>,
}

/// A password-protected copy of the account master key. This is the only
/// credential file the server stores; the password never leaves the client.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyFile {
    pub version: u8,
    pub account_id: Uuid,
    pub epoch: u32,
    pub kdf: KdfParams,
    pub wrapped_master_key: Envelope,
    pub created_at: chrono::DateTime<chrono::Utc>,
    /// Older AMK epochs, oldest first. Empty for a keyfile that was never
    /// rotated and omitted from JSON in that case, so pre-rotation keyfiles
    /// stay byte-identical and older clients still parse a rotated one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub retained: Vec<RetainedEpoch>,
}

impl KeyFile {
    pub const VERSION: u8 = 1;

    /// Creates a fresh AMK and a keyfile that unlocks with `password`.
    pub fn create(password: &str, account_id: Uuid) -> Result<(Self, MasterKey)> {
        let master = MasterKey::generate(account_id, 0);
        let kdf = KdfParams::generate();
        let kek = kdf.derive(password.as_bytes())?;
        let wrapped = envelope::seal(
            &kek,
            &amk_wrap_aad(account_id, master.epoch),
            master.expose_secret(),
        )?;
        Ok((
            Self {
                version: Self::VERSION,
                account_id,
                epoch: master.epoch,
                kdf,
                wrapped_master_key: wrapped,
                created_at: chrono::Utc::now(),
                retained: Vec::new(),
            },
            master,
        ))
    }

    /// Builds a keyfile from an already unlocked ring and a password.
    ///
    /// Used after recovering the account from a recovery kit: the restored
    /// keyfile must keep every epoch the kit restored, otherwise revisions
    /// written before a rotation would become unreadable after a recovery.
    pub fn from_ring(ring: &MasterKeyRing, password: &str) -> Result<Self> {
        let kdf = KdfParams::generate();
        let kek = kdf.derive(password.as_bytes())?;
        let current = ring.current();
        let wrapped = envelope::seal(
            &kek,
            &amk_wrap_aad(ring.account_id(), current.epoch()),
            current.expose_secret(),
        )?;
        let mut retained = Vec::new();
        for master in ring.previous() {
            if master.epoch() >= current.epoch() {
                return Err(CryptoError::Malformed("retained epoch is not older"));
            }
            retained.push(RetainedEpoch {
                epoch: master.epoch(),
                wrapped_master_key: envelope::seal(
                    &kek,
                    &amk_wrap_aad(ring.account_id(), master.epoch()),
                    master.expose_secret(),
                )?,
                retired_at: chrono::Utc::now(),
            });
        }
        retained.sort_by_key(|r| r.epoch);
        Ok(Self {
            version: Self::VERSION,
            account_id: ring.account_id(),
            epoch: current.epoch(),
            kdf,
            wrapped_master_key: wrapped,
            created_at: chrono::Utc::now(),
            retained,
        })
    }

    /// Re-wraps the current and every retained epoch under a new password.
    ///
    /// The old password is required because retained epochs are only decryptable
    /// through the keyfile's password-derived key; without re-wrapping them a
    /// password change would leave pre-rotation revisions behind the old
    /// password.
    pub fn rewrap(
        &self,
        master: &MasterKey,
        old_password: &str,
        new_password: &str,
    ) -> Result<Self> {
        let old_kek = self.kdf.derive(old_password.as_bytes())?;
        let kdf = KdfParams::generate();
        let kek = kdf.derive(new_password.as_bytes())?;
        let wrapped = envelope::seal(
            &kek,
            &amk_wrap_aad(self.account_id, master.epoch),
            master.expose_secret(),
        )?;
        let mut retained = self.retained.clone();
        for entry in &mut retained {
            let plain = envelope::open(
                &old_kek,
                &amk_wrap_aad(self.account_id, entry.epoch),
                &entry.wrapped_master_key,
            )?;
            entry.wrapped_master_key =
                envelope::seal(&kek, &amk_wrap_aad(self.account_id, entry.epoch), &plain)?;
        }
        Ok(Self {
            version: Self::VERSION,
            account_id: self.account_id,
            epoch: master.epoch,
            kdf,
            wrapped_master_key: wrapped,
            created_at: chrono::Utc::now(),
            retained,
        })
    }

    /// Rotates to a fresh AMK epoch and returns the new keyfile together with
    /// the new master key. New content must be sealed with the returned key.
    ///
    /// The previous epoch stays wrapped inside the keyfile, so revisions that
    /// were written before the rotation remain readable for every device that
    /// receives this keyfile. A device that only kept the old keyfile cannot
    /// read content sealed under the new epoch.
    ///
    /// Rotation only happens locally; the caller decides whether and how to
    /// publish the new keyfile (for example via `POST /account/keyfile`). A
    /// failed publication leaves the old keyfile valid and unchanged.
    pub fn rotate(&self, master: &MasterKey, password: &str) -> Result<(Self, MasterKey)> {
        if self.version != Self::VERSION {
            return Err(CryptoError::UnsupportedVersion(self.version));
        }
        if master.account_id() != self.account_id || master.epoch() != self.epoch {
            return Err(CryptoError::Malformed("master key does not match keyfile"));
        }
        let rotated = master.rotate();
        let old_kek = self.kdf.derive(password.as_bytes())?;
        let kdf = KdfParams::generate();
        let kek = kdf.derive(password.as_bytes())?;
        let wrapped = envelope::seal(
            &kek,
            &amk_wrap_aad(self.account_id, rotated.epoch),
            rotated.expose_secret(),
        )?;
        // Every retained epoch must stay readable through the new password-derived
        // key, so re-wrap the whole ring instead of only the current epoch.
        let mut retained = self.retained.clone();
        for entry in &mut retained {
            let plain = envelope::open(
                &old_kek,
                &amk_wrap_aad(self.account_id, entry.epoch),
                &entry.wrapped_master_key,
            )?;
            entry.wrapped_master_key =
                envelope::seal(&kek, &amk_wrap_aad(self.account_id, entry.epoch), &plain)?;
        }
        retained.retain(|r| r.epoch != self.epoch);
        retained.push(RetainedEpoch {
            epoch: self.epoch,
            wrapped_master_key: envelope::seal(
                &kek,
                &amk_wrap_aad(self.account_id, self.epoch),
                master.expose_secret(),
            )?,
            retired_at: chrono::Utc::now(),
        });
        retained.sort_by_key(|r| r.epoch);
        Ok((
            Self {
                version: Self::VERSION,
                account_id: self.account_id,
                epoch: rotated.epoch,
                kdf,
                wrapped_master_key: wrapped,
                created_at: chrono::Utc::now(),
                retained,
            },
            rotated,
        ))
    }

    /// Unlocks the current epoch and every retained epoch at once.
    pub fn unlock_ring(&self, password: &str) -> Result<MasterKeyRing> {
        let current = self.unlock(password)?;
        let kek = self.kdf.derive(password.as_bytes())?;
        let mut previous = Vec::with_capacity(self.retained.len());
        for entry in &self.retained {
            let bytes = envelope::open(
                &kek,
                &amk_wrap_aad(self.account_id, entry.epoch),
                &entry.wrapped_master_key,
            )?;
            if entry.epoch >= self.epoch {
                return Err(CryptoError::Malformed("retained epoch is not older"));
            }
            previous.push(MasterKey::from_secret(
                self.account_id,
                entry.epoch,
                SecretKey::from_slice(&bytes)?,
            ));
        }
        previous.sort_by_key(|m| m.epoch);
        Ok(MasterKeyRing { current, previous })
    }

    pub fn unlock(&self, password: &str) -> Result<MasterKey> {
        if self.version != Self::VERSION {
            return Err(CryptoError::UnsupportedVersion(self.version));
        }
        let kek = self.kdf.derive(password.as_bytes())?;
        let bytes = envelope::open(
            &kek,
            &amk_wrap_aad(self.account_id, self.epoch),
            &self.wrapped_master_key,
        )?;
        let key = SecretKey::from_slice(&bytes)?;
        Ok(MasterKey {
            key,
            account_id: self.account_id,
            epoch: self.epoch,
        })
    }
}

fn amk_wrap_aad(account_id: Uuid, epoch: u32) -> Vec<u8> {
    let mut aad = b"nntdrive/v1/amk-wrap".to_vec();
    aad.extend_from_slice(account_id.as_bytes());
    aad.extend_from_slice(&epoch.to_be_bytes());
    aad
}

/// The account master key. Everything user-visible is derived from it.
#[derive(Clone)]
pub struct MasterKey {
    key: SecretKey,
    account_id: Uuid,
    epoch: u32,
}

impl std::fmt::Debug for MasterKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MasterKey")
            .field("account_id", &self.account_id)
            .field("epoch", &self.epoch)
            .field("key", &"[redacted]")
            .finish()
    }
}

impl MasterKey {
    pub fn generate(account_id: Uuid, epoch: u32) -> Self {
        Self {
            key: SecretKey::generate(),
            account_id,
            epoch,
        }
    }

    pub fn from_secret(account_id: Uuid, epoch: u32, secret: SecretKey) -> Self {
        Self {
            key: secret,
            account_id,
            epoch,
        }
    }

    pub fn account_id(&self) -> Uuid {
        self.account_id
    }

    pub fn epoch(&self) -> u32 {
        self.epoch
    }

    /// Only used for wrapping into keyfiles/devices. Do not log.
    pub fn expose_secret(&self) -> &[u8] {
        self.key.as_bytes()
    }

    fn derive(&self, label: &str, context: &[u8]) -> Result<SecretKey> {
        // Salt binds every derivation to an account and key epoch.
        let mut salt = b"nntdrive/v1/epoch".to_vec();
        salt.extend_from_slice(self.account_id.as_bytes());
        salt.extend_from_slice(&self.epoch.to_be_bytes());
        hkdf_expand(self.key.as_bytes(), &salt, label, context)
    }

    /// Derives the per-file key. Chunk keys are derived from this.
    pub fn file_key(&self, file_id: Uuid) -> Result<FileKey> {
        let key = self.derive("nntdrive/v1/file-key", file_id.as_bytes())?;
        Ok(FileKey { key, file_id })
    }

    pub fn name_key(&self) -> Result<SecretKey> {
        self.derive("nntdrive/v1/name-key", &[])
    }

    pub fn manifest_key(&self) -> Result<SecretKey> {
        self.derive("nntdrive/v1/manifest-key", &[])
    }

    pub fn keyring_key(&self) -> Result<SecretKey> {
        self.derive("nntdrive/v1/keyring-key", &[])
    }

    /// Content-encryption key for one chunk, scoped to the account and bound to
    /// the chunk's plaintext hash. Chunks are never deduplicated across
    /// accounts; reused chunks keep their original random nonce.
    pub fn chunk_key(&self, plaintext_hash: &[u8; 32]) -> Result<SecretKey> {
        self.derive("nntdrive/v1/content-chunk-key", plaintext_hash)
    }

    fn chunk_aad(
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
    ) -> Vec<u8> {
        let mut aad = b"nntdrive/v1/chunk".to_vec();
        aad.extend_from_slice(chunk_id.as_bytes());
        aad.extend_from_slice(plaintext_hash);
        aad.extend_from_slice(&plaintext_len.to_be_bytes());
        aad.push(compression);
        aad
    }

    /// Encrypts one (compressed) chunk. `compression` is authenticated so a
    /// ciphertext cannot be reinterpreted under a different codec.
    pub fn seal_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        plaintext: &[u8],
    ) -> Result<Envelope> {
        let key = self.chunk_key(plaintext_hash)?;
        envelope::seal(
            &key,
            &Self::chunk_aad(chunk_id, plaintext_hash, plaintext_len, compression),
            plaintext,
        )
    }

    pub fn open_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        envelope: &Envelope,
    ) -> Result<Vec<u8>> {
        let key = self.chunk_key(plaintext_hash)?;
        envelope::open(
            &key,
            &Self::chunk_aad(chunk_id, plaintext_hash, plaintext_len, compression),
            envelope,
        )
    }

    /// Creates a new epoch. Callers must wrap the returned key for every
    /// remaining device and use it for all new content.
    pub fn rotate(&self) -> Self {
        Self {
            key: SecretKey::generate(),
            account_id: self.account_id,
            epoch: self.epoch + 1,
        }
    }

    pub fn rotate_with_new_account_root(&self) -> Self {
        self.rotate()
    }

    pub fn seal_name(&self, node_id: Uuid, plaintext_name: &str) -> Result<Envelope> {
        let key = self.name_key()?;
        envelope::seal(
            &key,
            &name_aad(node_id, self.epoch),
            plaintext_name.as_bytes(),
        )
    }

    pub fn open_name(&self, node_id: Uuid, envelope: &Envelope) -> Result<String> {
        let key = self.name_key()?;
        let bytes = envelope::open(&key, &name_aad(node_id, self.epoch), envelope)?;
        String::from_utf8(bytes).map_err(|_| CryptoError::Malformed("name is not utf-8"))
    }

    pub fn seal_manifest(
        &self,
        file_id: Uuid,
        revision: Uuid,
        plaintext: &[u8],
    ) -> Result<Envelope> {
        let key = self.manifest_key()?;
        let mut aad = b"nntdrive/v1/manifest".to_vec();
        aad.extend_from_slice(file_id.as_bytes());
        aad.extend_from_slice(revision.as_bytes());
        envelope::seal(&key, &aad, plaintext)
    }

    pub fn open_manifest(
        &self,
        file_id: Uuid,
        revision: Uuid,
        envelope: &Envelope,
    ) -> Result<Vec<u8>> {
        let key = self.manifest_key()?;
        let mut aad = b"nntdrive/v1/manifest".to_vec();
        aad.extend_from_slice(file_id.as_bytes());
        aad.extend_from_slice(revision.as_bytes());
        envelope::open(&key, &aad, envelope)
    }
}

/// Key material used to seal new content and open authenticated envelopes.
///
/// A single [`MasterKey`] seals and opens with its own epoch only. A
/// [`MasterKeyRing`] seals with the current epoch and opens with the current
/// epoch first, then the retained older epochs. Both are accepted where a
/// caller may run before or after an AMK rotation.
pub trait AccountKey {
    fn account_id(&self) -> Uuid;
    fn epoch(&self) -> u32;
    fn seal_name(&self, node_id: Uuid, plaintext_name: &str) -> Result<Envelope>;
    fn open_name(&self, node_id: Uuid, envelope: &Envelope) -> Result<String>;
    fn seal_manifest(&self, file_id: Uuid, revision: Uuid, plaintext: &[u8]) -> Result<Envelope>;
    fn open_manifest(&self, file_id: Uuid, revision: Uuid, envelope: &Envelope) -> Result<Vec<u8>>;
    fn seal_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        plaintext: &[u8],
    ) -> Result<Envelope>;
    fn open_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        envelope: &Envelope,
    ) -> Result<Vec<u8>>;
}

impl AccountKey for MasterKey {
    fn account_id(&self) -> Uuid {
        MasterKey::account_id(self)
    }

    fn epoch(&self) -> u32 {
        MasterKey::epoch(self)
    }

    fn seal_name(&self, node_id: Uuid, plaintext_name: &str) -> Result<Envelope> {
        MasterKey::seal_name(self, node_id, plaintext_name)
    }

    fn open_name(&self, node_id: Uuid, envelope: &Envelope) -> Result<String> {
        MasterKey::open_name(self, node_id, envelope)
    }

    fn seal_manifest(&self, file_id: Uuid, revision: Uuid, plaintext: &[u8]) -> Result<Envelope> {
        MasterKey::seal_manifest(self, file_id, revision, plaintext)
    }

    fn open_manifest(&self, file_id: Uuid, revision: Uuid, envelope: &Envelope) -> Result<Vec<u8>> {
        MasterKey::open_manifest(self, file_id, revision, envelope)
    }

    fn seal_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        plaintext: &[u8],
    ) -> Result<Envelope> {
        MasterKey::seal_chunk(
            self,
            chunk_id,
            plaintext_hash,
            plaintext_len,
            compression,
            plaintext,
        )
    }

    fn open_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        envelope: &Envelope,
    ) -> Result<Vec<u8>> {
        MasterKey::open_chunk(
            self,
            chunk_id,
            plaintext_hash,
            plaintext_len,
            compression,
            envelope,
        )
    }
}

/// An unlocked keyfile: the current AMK plus every retained epoch.
///
/// New content is always sealed with the current epoch. Reads fall back to the
/// retained epochs so revisions written before a rotation keep working. The
/// fallback authenticates every candidate, so a wrong-epoch envelope simply
/// fails rather than producing plaintext.
#[derive(Clone)]
pub struct MasterKeyRing {
    current: MasterKey,
    previous: Vec<MasterKey>,
}

impl From<MasterKey> for MasterKeyRing {
    /// A ring with no retained epochs, for callers that only hold one key.
    fn from(current: MasterKey) -> Self {
        Self {
            current,
            previous: Vec::new(),
        }
    }
}

impl std::fmt::Debug for MasterKeyRing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MasterKeyRing")
            .field("epoch", &self.current.epoch)
            .field(
                "retained_epochs",
                &self
                    .previous
                    .iter()
                    .map(MasterKey::epoch)
                    .collect::<Vec<_>>(),
            )
            .finish()
    }
}

impl MasterKeyRing {
    pub fn current(&self) -> &MasterKey {
        &self.current
    }

    pub fn account_id(&self) -> Uuid {
        self.current.account_id()
    }

    pub fn epoch(&self) -> u32 {
        self.current.epoch
    }

    /// Retained (older) epochs, newest first. Callers sealing a copy of the
    /// ring must verify each epoch is older than [`Self::epoch`].
    pub fn previous(&self) -> &[MasterKey] {
        &self.previous
    }

    /// Builds a ring from a current key and already-unlocked older epochs.
    pub fn from_parts(current: MasterKey, mut previous: Vec<MasterKey>) -> Self {
        previous.sort_by_key(|m| m.epoch);
        Self { current, previous }
    }

    pub fn epochs(&self) -> impl Iterator<Item = u32> + '_ {
        std::iter::once(self.current.epoch).chain(self.previous.iter().rev().map(MasterKey::epoch))
    }

    pub fn master_for_epoch(&self, epoch: u32) -> Option<&MasterKey> {
        if epoch == self.current.epoch {
            return Some(&self.current);
        }
        self.previous.iter().find(|m| m.epoch == epoch)
    }

    /// Current epoch first, then retained epochs newest to oldest.
    fn candidates(&self) -> impl Iterator<Item = &MasterKey> {
        std::iter::once(&self.current).chain(self.previous.iter().rev())
    }

    pub fn seal_name(&self, node_id: Uuid, plaintext_name: &str) -> Result<Envelope> {
        self.current.seal_name(node_id, plaintext_name)
    }

    pub fn open_name(&self, node_id: Uuid, envelope: &Envelope) -> Result<String> {
        for master in self.candidates() {
            match master.open_name(node_id, envelope) {
                Ok(name) => return Ok(name),
                Err(CryptoError::Authentication) => {}
                Err(e) => return Err(e),
            }
        }
        Err(CryptoError::Authentication)
    }

    pub fn seal_manifest(
        &self,
        file_id: Uuid,
        revision: Uuid,
        plaintext: &[u8],
    ) -> Result<Envelope> {
        self.current.seal_manifest(file_id, revision, plaintext)
    }

    pub fn open_manifest(
        &self,
        file_id: Uuid,
        revision: Uuid,
        envelope: &Envelope,
    ) -> Result<Vec<u8>> {
        for master in self.candidates() {
            match master.open_manifest(file_id, revision, envelope) {
                Ok(plain) => return Ok(plain),
                Err(CryptoError::Authentication) => {}
                Err(e) => return Err(e),
            }
        }
        Err(CryptoError::Authentication)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn seal_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        plaintext: &[u8],
    ) -> Result<Envelope> {
        self.current.seal_chunk(
            chunk_id,
            plaintext_hash,
            plaintext_len,
            compression,
            plaintext,
        )
    }

    pub fn open_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        envelope: &Envelope,
    ) -> Result<Vec<u8>> {
        for master in self.candidates() {
            match master.open_chunk(
                chunk_id,
                plaintext_hash,
                plaintext_len,
                compression,
                envelope,
            ) {
                Ok(plain) => return Ok(plain),
                Err(CryptoError::Authentication) => {}
                Err(e) => return Err(e),
            }
        }
        Err(CryptoError::Authentication)
    }
}

impl<T: AccountKey + ?Sized> AccountKey for std::sync::Arc<T> {
    fn account_id(&self) -> Uuid {
        (**self).account_id()
    }

    fn epoch(&self) -> u32 {
        (**self).epoch()
    }

    fn seal_name(&self, node_id: Uuid, plaintext_name: &str) -> Result<Envelope> {
        (**self).seal_name(node_id, plaintext_name)
    }

    fn open_name(&self, node_id: Uuid, envelope: &Envelope) -> Result<String> {
        (**self).open_name(node_id, envelope)
    }

    fn seal_manifest(&self, file_id: Uuid, revision: Uuid, plaintext: &[u8]) -> Result<Envelope> {
        (**self).seal_manifest(file_id, revision, plaintext)
    }

    fn open_manifest(&self, file_id: Uuid, revision: Uuid, envelope: &Envelope) -> Result<Vec<u8>> {
        (**self).open_manifest(file_id, revision, envelope)
    }

    fn seal_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        plaintext: &[u8],
    ) -> Result<Envelope> {
        (**self).seal_chunk(
            chunk_id,
            plaintext_hash,
            plaintext_len,
            compression,
            plaintext,
        )
    }

    fn open_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        envelope: &Envelope,
    ) -> Result<Vec<u8>> {
        (**self).open_chunk(
            chunk_id,
            plaintext_hash,
            plaintext_len,
            compression,
            envelope,
        )
    }
}

impl AccountKey for MasterKeyRing {
    fn account_id(&self) -> Uuid {
        MasterKeyRing::account_id(self)
    }

    fn epoch(&self) -> u32 {
        MasterKeyRing::epoch(self)
    }

    fn seal_name(&self, node_id: Uuid, plaintext_name: &str) -> Result<Envelope> {
        MasterKeyRing::seal_name(self, node_id, plaintext_name)
    }

    fn open_name(&self, node_id: Uuid, envelope: &Envelope) -> Result<String> {
        MasterKeyRing::open_name(self, node_id, envelope)
    }

    fn seal_manifest(&self, file_id: Uuid, revision: Uuid, plaintext: &[u8]) -> Result<Envelope> {
        MasterKeyRing::seal_manifest(self, file_id, revision, plaintext)
    }

    fn open_manifest(&self, file_id: Uuid, revision: Uuid, envelope: &Envelope) -> Result<Vec<u8>> {
        MasterKeyRing::open_manifest(self, file_id, revision, envelope)
    }

    fn seal_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        plaintext: &[u8],
    ) -> Result<Envelope> {
        MasterKeyRing::seal_chunk(
            self,
            chunk_id,
            plaintext_hash,
            plaintext_len,
            compression,
            plaintext,
        )
    }

    fn open_chunk(
        &self,
        chunk_id: Uuid,
        plaintext_hash: &[u8; 32],
        plaintext_len: u64,
        compression: u8,
        envelope: &Envelope,
    ) -> Result<Vec<u8>> {
        MasterKeyRing::open_chunk(
            self,
            chunk_id,
            plaintext_hash,
            plaintext_len,
            compression,
            envelope,
        )
    }
}

fn name_aad(node_id: Uuid, epoch: u32) -> Vec<u8> {
    let mut aad = b"nntdrive/v1/name".to_vec();
    aad.extend_from_slice(node_id.as_bytes());
    aad.extend_from_slice(&epoch.to_be_bytes());
    aad
}

/// Per-file key. Never persisted; derived on demand from the AMK.
#[derive(Clone)]
pub struct FileKey {
    key: SecretKey,
    file_id: Uuid,
}

impl FileKey {
    /// Per-chunk key, separated by chunk index so a nonce reuse bug in one
    /// chunk cannot silently repeat keystream in another.
    pub fn chunk_key(&self, chunk_index: u32) -> Result<SecretKey> {
        hkdf_expand(
            self.key.as_bytes(),
            &self.file_id.as_bytes()[..16],
            "nntdrive/v1/chunk-key",
            &chunk_index.to_be_bytes(),
        )
    }
}

impl std::fmt::Debug for FileKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FileKey([redacted])")
    }
}

mod b64 {
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &Vec<u8>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD
            .decode(s)
            .map_err(serde::de::Error::custom)
    }
}

/// Password verifier for server authentication. The backend never sees the
/// password and cannot derive the account master key from this value because
/// the salt and output domain are separate from [`KeyFile`].
pub fn derive_auth_verifier(password: &str, account_id: Uuid) -> String {
    let mut salt_input = b"nntdrive/v1/auth-salt".to_vec();
    salt_input.extend_from_slice(account_id.as_bytes());
    let salt = blake3::hash(&salt_input);
    let params = Params::new(
        ARGON2_M_COST_KIB,
        ARGON2_T_COST,
        ARGON2_P_COST,
        Some(KEY_LEN),
    )
    .expect("static argon2 params");
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut out = [0u8; KEY_LEN];
    argon
        .hash_password_into(password.as_bytes(), &salt.as_bytes()[..16], &mut out)
        .expect("argon2 derivation");
    hex::encode(out)
}

/// Argon2id PHC hash of a verifier, stored by the backend.
pub fn hash_verifier(verifier: &str) -> Result<String> {
    use argon2::password_hash::{rand_core::OsRng, PasswordHasher, SaltString};
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(verifier.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|_| CryptoError::Kdf)
}

pub fn verify_verifier(verifier: &str, phc: &str) -> bool {
    use argon2::password_hash::{PasswordHash, PasswordVerifier};
    let Ok(parsed) = PasswordHash::new(phc) else {
        return false;
    };
    Argon2::default()
        .verify_password(verifier.as_bytes(), &parsed)
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyfile_roundtrip_and_wrong_password() {
        let account = Uuid::new_v4();
        let (kf, master) = KeyFile::create("correct horse battery staple", account).unwrap();
        let unlocked = kf.unlock("correct horse battery staple").unwrap();
        assert_eq!(unlocked.expose_secret(), master.expose_secret());

        let err = kf.unlock("wrong password").unwrap_err();
        assert!(matches!(err, CryptoError::Authentication));
    }

    #[test]
    fn keyfiles_use_unique_salts() {
        let account = Uuid::new_v4();
        let (a, _) = KeyFile::create("pw", account).unwrap();
        let (b, _) = KeyFile::create("pw", account).unwrap();
        assert_ne!(a.kdf.salt, b.kdf.salt);
        assert_ne!(a.wrapped_master_key, b.wrapped_master_key);
    }

    #[test]
    fn envelope_detects_tampering_and_wrong_key() {
        let key = SecretKey::generate();
        let mut env = envelope::seal(&key, b"aad", b"secret data").unwrap();
        assert_eq!(
            envelope::open(&key, b"aad", &env).unwrap(),
            b"secret data".to_vec()
        );

        let mut bad = env.clone();
        bad.ciphertext[0] ^= 0x01;
        assert!(matches!(
            envelope::open(&key, b"aad", &bad),
            Err(CryptoError::Authentication)
        ));
        assert!(matches!(
            envelope::open(&key, b"different aad", &env),
            Err(CryptoError::Authentication)
        ));
        let other = SecretKey::generate();
        assert!(matches!(
            envelope::open(&other, b"aad", &env),
            Err(CryptoError::Authentication)
        ));

        env.ciphertext.truncate(4);
        assert!(envelope::open(&key, b"aad", &env).is_err());
    }

    #[test]
    fn nonces_are_random_per_seal() {
        let key = SecretKey::generate();
        let a = envelope::seal(&key, b"", b"same").unwrap();
        let b = envelope::seal(&key, b"", b"same").unwrap();
        assert_ne!(a.nonce, b.nonce);
        assert_ne!(a.ciphertext, b.ciphertext); // no convergent encryption
    }

    #[test]
    fn file_and_chunk_keys_are_separated() {
        let master = MasterKey::generate(Uuid::new_v4(), 0);
        let f1 = master.file_key(Uuid::new_v4()).unwrap();
        let f2 = master.file_key(Uuid::new_v4()).unwrap();
        assert_ne!(
            f1.chunk_key(0).unwrap().as_bytes(),
            f2.chunk_key(0).unwrap().as_bytes()
        );
        assert_ne!(
            f1.chunk_key(0).unwrap().as_bytes(),
            f1.chunk_key(1).unwrap().as_bytes()
        );
        assert_ne!(
            master.name_key().unwrap().as_bytes(),
            master.manifest_key().unwrap().as_bytes()
        );
    }

    #[test]
    fn names_are_authenticated_and_bound_to_node() {
        let master = MasterKey::generate(Uuid::new_v4(), 3);
        let node = Uuid::new_v4();
        let sealed = master.seal_name(node, "Steuererklärung 2025.pdf").unwrap();
        assert!(!sealed.ciphertext.windows(4).any(|w| w == b"Steu"));
        assert_eq!(
            master.open_name(node, &sealed).unwrap(),
            "Steuererklärung 2025.pdf"
        );
        assert!(master.open_name(Uuid::new_v4(), &sealed).is_err());
    }

    #[test]
    fn manifest_bound_to_file_and_revision() {
        let master = MasterKey::generate(Uuid::new_v4(), 1);
        let file = Uuid::new_v4();
        let rev = Uuid::new_v4();
        let sealed = master
            .seal_manifest(file, rev, br#"{"chunks":[]}"#)
            .unwrap();
        assert_eq!(
            master.open_manifest(file, rev, &sealed).unwrap(),
            br#"{"chunks":[]}"#.to_vec()
        );
        assert!(master.open_manifest(file, Uuid::new_v4(), &sealed).is_err());
    }

    #[test]
    fn epoch_rotation_changes_derived_keys() {
        let master = MasterKey::generate(Uuid::new_v4(), 0);
        let file = Uuid::new_v4();
        let old = master.file_key(file).unwrap().chunk_key(0).unwrap();
        let rotated = master.rotate();
        assert_eq!(rotated.epoch(), 1);
        let new = rotated.file_key(file).unwrap().chunk_key(0).unwrap();
        assert_ne!(old.as_bytes(), new.as_bytes());
    }

    #[test]
    fn removed_device_cannot_decrypt_content_from_the_new_epoch() {
        let account = Uuid::new_v4();
        let master = MasterKey::generate(account, 0);
        let removed_device = crate::DeviceKeypair::generate();
        let mut ring = crate::Keyring::new(account, 0);
        let device_id = Uuid::new_v4();
        let sealed = ring
            .enroll(&master, device_id, "old laptop", removed_device.public())
            .unwrap();
        let old_amk = crate::open_enrollment(&removed_device, device_id, &sealed).unwrap();
        let removed_master = MasterKey::from_secret(account, 0, old_amk);

        let rotated = master.rotate();
        let chunk_id = Uuid::new_v4();
        let plaintext = b"content uploaded after revocation";
        let hash = *blake3::hash(plaintext).as_bytes();
        let envelope = rotated
            .seal_chunk(chunk_id, &hash, plaintext.len() as u64, 0, plaintext)
            .unwrap();

        assert!(rotated
            .open_chunk(chunk_id, &hash, plaintext.len() as u64, 0, &envelope)
            .is_ok());
        assert!(removed_master
            .open_chunk(chunk_id, &hash, plaintext.len() as u64, 0, &envelope)
            .is_err());
    }

    #[test]
    fn rotation_keeps_old_and_new_revisions_readable() {
        let account = Uuid::new_v4();
        let password = "correct horse battery staple";
        let (keyfile, master) = KeyFile::create(password, account).unwrap();
        let node = Uuid::new_v4();
        let file = Uuid::new_v4();
        let old_rev = Uuid::new_v4();
        let old_name = master.seal_name(node, "old revision.txt").unwrap();
        let old_manifest = master
            .seal_manifest(file, old_rev, b"{\"chunks\":[]}")
            .unwrap();
        let old_chunk_id = Uuid::new_v4();
        let old_plaintext = b"content written before the rotation";
        let old_hash = *blake3::hash(old_plaintext).as_bytes();
        let old_chunk = master
            .seal_chunk(
                old_chunk_id,
                &old_hash,
                old_plaintext.len() as u64,
                0,
                old_plaintext,
            )
            .unwrap();

        let (rotated_keyfile, rotated) = keyfile.rotate(&master, password).unwrap();
        assert_eq!(rotated.epoch(), 1);
        assert_eq!(rotated_keyfile.epoch, 1);
        assert_eq!(rotated_keyfile.retained.len(), 1);
        assert_eq!(rotated_keyfile.retained[0].epoch, 0);

        let ring = rotated_keyfile.unlock_ring(password).unwrap();
        assert_eq!(ring.epoch(), 1);
        assert_eq!(ring.epochs().collect::<Vec<_>>(), vec![1, 0]);
        assert_eq!(ring.open_name(node, &old_name).unwrap(), "old revision.txt");
        assert_eq!(
            ring.open_manifest(file, old_rev, &old_manifest).unwrap(),
            b"{\"chunks\":[]}".to_vec()
        );
        assert_eq!(
            ring.open_chunk(
                old_chunk_id,
                &old_hash,
                old_plaintext.len() as u64,
                0,
                &old_chunk
            )
            .unwrap(),
            old_plaintext.to_vec()
        );

        let new_name = ring.seal_name(node, "new revision.txt").unwrap();
        let new_chunk_id = Uuid::new_v4();
        let new_plaintext = b"content written after the rotation";
        let new_hash = *blake3::hash(new_plaintext).as_bytes();
        let new_chunk = ring
            .seal_chunk(
                new_chunk_id,
                &new_hash,
                new_plaintext.len() as u64,
                0,
                new_plaintext,
            )
            .unwrap();
        assert_eq!(ring.open_name(node, &new_name).unwrap(), "new revision.txt");
        assert_eq!(
            ring.open_chunk(
                new_chunk_id,
                &new_hash,
                new_plaintext.len() as u64,
                0,
                &new_chunk
            )
            .unwrap(),
            new_plaintext.to_vec()
        );
        // Old epoch keys must not authenticate new-epoch content.
        assert!(master.open_name(node, &new_name).is_err());
        assert!(master
            .open_chunk(
                new_chunk_id,
                &new_hash,
                new_plaintext.len() as u64,
                0,
                &new_chunk
            )
            .is_err());
    }

    #[test]
    fn revoked_device_with_only_the_old_keyfile_cannot_read_new_content() {
        let account = Uuid::new_v4();
        let password = "correct horse battery staple";
        let (keyfile, master) = KeyFile::create(password, account).unwrap();
        let (_, rotated) = keyfile.rotate(&master, password).unwrap();

        let revoked_view = keyfile.unlock(password).unwrap();
        assert_eq!(revoked_view.epoch(), 0);
        let node = Uuid::new_v4();
        let sealed = rotated.seal_name(node, "after revocation.txt").unwrap();
        assert!(revoked_view.open_name(node, &sealed).is_err());

        let chunk_id = Uuid::new_v4();
        let plaintext = b"new content";
        let hash = *blake3::hash(plaintext).as_bytes();
        let chunk = rotated
            .seal_chunk(chunk_id, &hash, plaintext.len() as u64, 0, plaintext)
            .unwrap();
        assert!(revoked_view
            .open_chunk(chunk_id, &hash, plaintext.len() as u64, 0, &chunk)
            .is_err());
    }

    #[test]
    fn repeated_rotation_retains_every_epoch_and_survives_rewrap() {
        let account = Uuid::new_v4();
        let password = "pw";
        let (keyfile, master) = KeyFile::create(password, account).unwrap();
        let node = Uuid::new_v4();
        let epoch0 = master.seal_name(node, "epoch zero").unwrap();
        let (kf1, master1) = keyfile.rotate(&master, password).unwrap();
        let epoch1 = master1.seal_name(node, "epoch one").unwrap();
        let (kf2, master2) = kf1.rotate(&master1, password).unwrap();
        let epoch2 = master2.seal_name(node, "epoch two").unwrap();

        let rewrapped = kf2.rewrap(&master2, "pw", "new password").unwrap();
        assert_eq!(rewrapped.retained.len(), 2);
        assert_eq!(
            rewrapped
                .retained
                .iter()
                .map(|r| r.epoch)
                .collect::<Vec<_>>(),
            vec![0, 1]
        );
        let ring = rewrapped.unlock_ring("new password").unwrap();
        assert_eq!(ring.epochs().collect::<Vec<_>>(), vec![2, 1, 0]);
        assert_eq!(ring.open_name(node, &epoch0).unwrap(), "epoch zero");
        assert_eq!(ring.open_name(node, &epoch1).unwrap(), "epoch one");
        assert_eq!(ring.open_name(node, &epoch2).unwrap(), "epoch two");
        assert!(rewrapped.unlock(password).is_err());
    }

    #[test]
    fn failed_rotation_attempt_leaves_the_old_keyfile_valid() {
        let account = Uuid::new_v4();
        let password = "pw";
        let (keyfile, master) = KeyFile::create(password, account).unwrap();
        // A keyfile from another account/epoch must not be rotated with this key.
        let (other_keyfile, _other_master) = KeyFile::create(password, Uuid::new_v4()).unwrap();
        assert!(other_keyfile.rotate(&master, password).is_err());
        let (wrong_epoch, _) = keyfile.rotate(&master, password).unwrap();
        assert!(wrong_epoch.rotate(&master, password).is_err());

        // The locally rotated keyfile was never published; the stored one still
        // unlocks the old epoch and its content.
        let node = Uuid::new_v4();
        let sealed = master.seal_name(node, "kept").unwrap();
        let still_valid = keyfile.unlock(password).unwrap();
        assert_eq!(still_valid.epoch(), 0);
        assert_eq!(still_valid.open_name(node, &sealed).unwrap(), "kept");
    }

    #[test]
    fn unrotated_keyfile_json_has_no_retained_field() {
        let (keyfile, master) = KeyFile::create("pw", Uuid::new_v4()).unwrap();
        let json = serde_json::to_value(&keyfile).unwrap();
        assert!(json.get("retained").is_none());
        // A rotated keyfile round-trips through JSON with its retained epochs.
        let (rotated, _) = keyfile.rotate(&master, "pw").unwrap();
        let encoded = serde_json::to_string(&rotated).unwrap();
        let decoded: KeyFile = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded.retained.len(), 1);
        assert_eq!(decoded.retained[0].epoch, 0);
    }
}
