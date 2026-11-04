//! Device identity (X25519) and the account keyring.
//!
//! A device holds its private key in the OS secure store. The AMK is wrapped
//! for the device's public key, so the backend never sees a device secret and
//! can never unwrap content keys.

use crate::envelope::{open, seal, Envelope};
use crate::{hkdf_expand, CryptoError, MasterKey, Result, SecretKey};
use base64::Engine;
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use x25519_dalek::{PublicKey, StaticSecret};

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn unb64(s: &str) -> Result<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
        .decode(s)
        .map_err(|_| CryptoError::Malformed("bad base64 key"))
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DevicePublicKey(#[serde(with = "b64_bytes")] pub Vec<u8>);

impl std::fmt::Debug for DevicePublicKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DevicePublicKey(")?;
        f.write_str(&hex::encode(&self.0).chars().take(8).collect::<String>())?;
        f.write_str("…)")
    }
}

mod b64_bytes {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        bytes: &[u8],
        s: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_str(&b64(bytes))
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        d: D,
    ) -> std::result::Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        unb64(&s).map_err(serde::de::Error::custom)
    }
}

impl DevicePublicKey {
    fn to_dalek(&self) -> Result<PublicKey> {
        let arr: [u8; 32] = self
            .0
            .as_slice()
            .try_into()
            .map_err(|_| CryptoError::Malformed("device public key must be 32 bytes"))?;
        Ok(PublicKey::from(arr))
    }

    /// Seals `plaintext` (the AMK) for this device. AAD is bound to both the
    /// ephemeral and recipient keys, preventing key-substitution/replay.
    pub fn seal(&self, plaintext: &[u8], aad: &[u8]) -> Result<SealedKey> {
        let recipient = self.to_dalek()?;
        let ephemeral = StaticSecret::random_from_rng(OsRng);
        let ephemeral_pub = PublicKey::from(&ephemeral);
        let shared = ephemeral.diffie_hellman(&recipient);
        let mut salt = Vec::with_capacity(64);
        salt.extend_from_slice(ephemeral_pub.as_bytes());
        salt.extend_from_slice(recipient.as_bytes());
        let wrap_key = hkdf_expand(shared.as_bytes(), &salt, "nntdrive/v1/device-wrap", aad)?;
        let mut bound_aad = b"nntdrive/v1/device-wrap".to_vec();
        bound_aad.extend_from_slice(aad);
        bound_aad.extend_from_slice(ephemeral_pub.as_bytes());
        bound_aad.extend_from_slice(recipient.as_bytes());
        Ok(SealedKey {
            version: 1,
            ephemeral_public: b64(ephemeral_pub.as_bytes()),
            envelope: seal(&wrap_key, &bound_aad, plaintext)?,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SealedKey {
    pub version: u8,
    pub ephemeral_public: String,
    pub envelope: Envelope,
}

pub struct DeviceKeypair {
    secret: StaticSecret,
}

impl DeviceKeypair {
    pub fn generate() -> Self {
        Self {
            secret: StaticSecret::random_from_rng(OsRng),
        }
    }

    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self {
            secret: StaticSecret::from(bytes),
        }
    }

    pub fn to_bytes(&self) -> [u8; 32] {
        self.secret.to_bytes()
    }

    pub fn public(&self) -> DevicePublicKey {
        DevicePublicKey(PublicKey::from(&self.secret).as_bytes().to_vec())
    }

    pub fn open(&self, sealed: &SealedKey, aad: &[u8]) -> Result<Vec<u8>> {
        if sealed.version != 1 {
            return Err(CryptoError::UnsupportedVersion(sealed.version));
        }
        let eph_bytes = unb64(&sealed.ephemeral_public)?;
        let eph: [u8; 32] = eph_bytes
            .as_slice()
            .try_into()
            .map_err(|_| CryptoError::Malformed("bad ephemeral key"))?;
        let ephemeral = PublicKey::from(eph);
        let shared = self.secret.diffie_hellman(&ephemeral);
        let recipient = PublicKey::from(&self.secret);
        let mut salt = Vec::with_capacity(64);
        salt.extend_from_slice(ephemeral.as_bytes());
        salt.extend_from_slice(recipient.as_bytes());
        let wrap_key = hkdf_expand(shared.as_bytes(), &salt, "nntdrive/v1/device-wrap", aad)?;
        let mut bound_aad = b"nntdrive/v1/device-wrap".to_vec();
        bound_aad.extend_from_slice(aad);
        bound_aad.extend_from_slice(ephemeral.as_bytes());
        bound_aad.extend_from_slice(recipient.as_bytes());
        open(&wrap_key, &bound_aad, &sealed.envelope)
    }
}

impl std::fmt::Debug for DeviceKeypair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DeviceKeypair([redacted])")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyringDevice {
    pub device_id: Uuid,
    pub label: String,
    pub public_key: DevicePublicKey,
    pub bound_epoch: u32,
    pub added_at: chrono::DateTime<chrono::Utc>,
    pub revoked_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Keyring {
    pub version: u8,
    pub account_id: Uuid,
    pub epoch: u32,
    pub devices: Vec<KeyringDevice>,
}

impl Keyring {
    pub const VERSION: u8 = 1;

    pub fn new(account_id: Uuid, epoch: u32) -> Self {
        Self {
            version: Self::VERSION,
            account_id,
            epoch,
            devices: Vec::new(),
        }
    }

    pub fn active(&self) -> impl Iterator<Item = &KeyringDevice> {
        self.devices.iter().filter(|d| d.revoked_at.is_none())
    }

    /// Adds a device and returns the AMK sealed for it. The caller delivers the
    /// [`SealedKey`] to the device over the authenticated enrollment channel;
    /// it is never persisted by the server.
    pub fn enroll(
        &mut self,
        master: &MasterKey,
        device_id: Uuid,
        label: impl Into<String>,
        public_key: DevicePublicKey,
    ) -> Result<SealedKey> {
        if self.account_id != master.account_id() || self.epoch != master.epoch() {
            return Err(CryptoError::Malformed(
                "keyring epoch does not match master key",
            ));
        }
        if self
            .devices
            .iter()
            .any(|d| d.device_id == device_id && d.revoked_at.is_none())
        {
            return Err(CryptoError::Malformed(
                "device already enrolled in this epoch",
            ));
        }
        let mut aad = b"nntdrive/v1/enroll".to_vec();
        aad.extend_from_slice(device_id.as_bytes());
        let sealed = public_key.seal(master.expose_secret(), &aad)?;
        self.devices.retain(|d| d.device_id != device_id);
        self.devices.push(KeyringDevice {
            device_id,
            label: label.into(),
            public_key,
            bound_epoch: master.epoch(),
            added_at: chrono::Utc::now(),
            revoked_at: None,
        });
        Ok(sealed)
    }

    pub fn revoke(&mut self, device_id: Uuid) -> bool {
        if let Some(d) = self.devices.iter_mut().find(|d| d.device_id == device_id) {
            d.revoked_at = Some(chrono::Utc::now());
            true
        } else {
            false
        }
    }

    pub fn seal(&self, master: &MasterKey) -> Result<Envelope> {
        let key = master.keyring_key()?;
        let mut aad = b"nntdrive/v1/keyring".to_vec();
        aad.extend_from_slice(self.account_id.as_bytes());
        aad.extend_from_slice(&self.epoch.to_be_bytes());
        seal(&key, &aad, &serde_json::to_vec(self)?)
    }

    pub fn open(master: &MasterKey, envelope: &Envelope) -> Result<Self> {
        let key = master.keyring_key()?;
        let mut aad = b"nntdrive/v1/keyring".to_vec();
        aad.extend_from_slice(master.account_id().as_bytes());
        aad.extend_from_slice(&master.epoch().to_be_bytes());
        let bytes = open(&key, &aad, envelope)?;
        let ring: Keyring = serde_json::from_slice(&bytes)?;
        if ring.account_id != master.account_id() || ring.epoch != master.epoch() {
            return Err(CryptoError::Malformed(
                "keyring belongs to another account/epoch",
            ));
        }
        Ok(ring)
    }
}

/// Unseals the AMK delivered at enrollment time. Only the enrolled device can
/// do this.
pub fn open_enrollment(
    device: &DeviceKeypair,
    device_id: Uuid,
    sealed: &SealedKey,
) -> Result<SecretKey> {
    let mut aad = b"nntdrive/v1/enroll".to_vec();
    aad.extend_from_slice(device_id.as_bytes());
    let bytes = device.open(sealed, &aad)?;
    SecretKey::from_slice(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn master() -> MasterKey {
        MasterKey::generate(Uuid::new_v4(), 0)
    }

    #[test]
    fn enrollment_roundtrip_and_wrong_device() {
        let m = master();
        let laptop = DeviceKeypair::generate();
        let phone = DeviceKeypair::generate();
        let mut ring = Keyring::new(m.account_id(), m.epoch());
        let sealed = ring
            .enroll(&m, Uuid::new_v4(), "laptop", laptop.public())
            .unwrap();
        let id = ring.devices[0].device_id;
        let opened = open_enrollment(&laptop, id, &sealed).unwrap();
        assert_eq!(opened.as_bytes(), m.expose_secret());
        assert!(open_enrollment(&phone, id, &sealed).is_err());

        // Keyring survives sealing and is bound to epoch.
        let env = ring.seal(&m).unwrap();
        let loaded = Keyring::open(&m, &env).unwrap();
        assert_eq!(loaded.devices.len(), 1);
        let other_epoch = m.rotate();
        assert!(Keyring::open(&other_epoch, &env).is_err());
    }

    #[test]
    fn revoked_device_is_not_active() {
        let m = master();
        let laptop = DeviceKeypair::generate();
        let mut ring = Keyring::new(m.account_id(), m.epoch());
        let id = Uuid::new_v4();
        ring.enroll(&m, id, "laptop", laptop.public()).unwrap();
        assert_eq!(ring.active().count(), 1);
        assert!(ring.revoke(id));
        assert_eq!(ring.active().count(), 0);
    }

    #[test]
    fn enrollment_rejects_epoch_mismatch() {
        let m = master();
        let d = DeviceKeypair::generate();
        let mut ring = Keyring::new(m.account_id(), 99);
        assert!(ring.enroll(&m, Uuid::new_v4(), "x", d.public()).is_err());
    }
}
