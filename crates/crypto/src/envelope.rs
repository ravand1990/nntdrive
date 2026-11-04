//! Versioned authenticated envelope used for every secret blob we persist or
//! send to the server.
//!
//! Wire/storage format (compact): `version(1) || nonce(24) || ciphertext+tag`.

use crate::{CryptoError, Result, NONCE_LEN};
use base64::Engine;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};

pub const VERSION: u8 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Envelope {
    pub version: u8,
    #[serde(with = "b64_field")]
    pub nonce: Vec<u8>,
    #[serde(with = "b64_field")]
    pub ciphertext: Vec<u8>,
}

mod b64_field {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        bytes: &Vec<u8>,
        s: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        d: D,
    ) -> std::result::Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD
            .decode(s)
            .map_err(serde::de::Error::custom)
    }
}

impl Envelope {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(1 + NONCE_LEN + self.ciphertext.len());
        out.push(self.version);
        out.extend_from_slice(&self.nonce);
        out.extend_from_slice(&self.ciphertext);
        out
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < 1 + NONCE_LEN + 16 {
            return Err(CryptoError::Malformed("truncated envelope"));
        }
        let version = bytes[0];
        if version != VERSION {
            return Err(CryptoError::UnsupportedVersion(version));
        }
        Ok(Self {
            version,
            nonce: bytes[1..1 + NONCE_LEN].to_vec(),
            ciphertext: bytes[1 + NONCE_LEN..].to_vec(),
        })
    }

    /// Overhead per sealed blob: version + nonce + Poly1305 tag.
    pub const OVERHEAD: usize = 1 + NONCE_LEN + 16;
}

pub(crate) fn seal(key: &crate::SecretKey, aad: &[u8], plaintext: &[u8]) -> Result<Envelope> {
    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| CryptoError::Authentication)?;
    Ok(Envelope {
        version: VERSION,
        nonce: nonce.to_vec(),
        ciphertext,
    })
}

pub(crate) fn open(key: &crate::SecretKey, aad: &[u8], env: &Envelope) -> Result<Vec<u8>> {
    if env.version != VERSION {
        return Err(CryptoError::UnsupportedVersion(env.version));
    }
    if env.nonce.len() != NONCE_LEN {
        return Err(CryptoError::Malformed("bad nonce length"));
    }
    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    cipher
        .decrypt(
            XNonce::from_slice(&env.nonce),
            Payload {
                msg: &env.ciphertext,
                aad,
            },
        )
        .map_err(|_| CryptoError::Authentication)
}
