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
            },
            master,
        ))
    }

    /// Re-wraps `master` under a new password/salt. Used for password changes
    /// and for epoch rotation after device revocation.
    pub fn rewrap(&self, master: &MasterKey, password: &str) -> Result<Self> {
        let kdf = KdfParams::generate();
        let kek = kdf.derive(password.as_bytes())?;
        let wrapped = envelope::seal(
            &kek,
            &amk_wrap_aad(self.account_id, master.epoch),
            master.expose_secret(),
        )?;
        Ok(Self {
            version: Self::VERSION,
            account_id: self.account_id,
            epoch: master.epoch,
            kdf,
            wrapped_master_key: wrapped,
            created_at: chrono::Utc::now(),
        })
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
}
