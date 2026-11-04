//! Crockford base32 for human transcription of recovery codes.
//! Encoding only - this is not cryptography.

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().saturating_mul(8).div_ceil(5) + 8);
    let mut buffer: u32 = 0;
    let mut bits = 0u32;
    for &b in bytes {
        buffer = (buffer << 8) | b as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(ALPHABET[((buffer >> bits) & 0x1f) as usize] as char);
        }
    }
    if bits > 0 {
        out.push(ALPHABET[((buffer << (5 - bits)) & 0x1f) as usize] as char);
    }
    out
}

pub fn decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 5 / 8);
    let mut buffer: u32 = 0;
    let mut bits = 0u32;
    for c in s.chars() {
        if c == '-' || c == ' ' || c == '\n' || c == '\r' || c == '\t' {
            continue;
        }
        let c = c.to_ascii_uppercase();
        let c = match c {
            'I' | 'L' => '1',
            'O' => '0',
            _ => c,
        };
        let v = ALPHABET.iter().position(|&a| a as char == c)? as u32;
        buffer = (buffer << 5) | v;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push(((buffer >> bits) & 0xff) as u8);
        }
    }
    Some(out)
}

/// 32 random bytes -> `NNTR-XXXX-XXXX-...` (52 base32 chars, 13 groups of 4).
pub fn encode_recovery_code(bytes: &[u8]) -> String {
    let raw = encode(bytes);
    let mut groups: Vec<String> = raw
        .as_bytes()
        .chunks(4)
        .map(|c| String::from_utf8_lossy(c).to_string())
        .collect();
    groups.insert(0, "NNTR".to_string());
    groups.join("-")
}

pub fn decode_recovery_code(code: &str) -> Option<Vec<u8>> {
    let cleaned: String = code
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect();
    let body = cleaned.strip_prefix("NNTR").unwrap_or(&cleaned).to_string();
    let bytes = decode(&body)?;
    // Reject non-canonical codes (e.g. a flipped padding character) so a
    // mistyped code fails instead of silently decoding to the same key.
    if encode(&bytes) != body {
        return None;
    }
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_confusable_characters() {
        let data = b"0123456789abcdefghijklmnopqrstuv";
        let encoded = encode(data);
        assert_eq!(decode(&encoded).unwrap(), data);
        assert_eq!(decode(&encoded.to_lowercase()).unwrap(), data);
        assert_eq!(decode("O0I1").unwrap(), decode("0011").unwrap());
    }

    #[test]
    fn recovery_code_roundtrip() {
        let bytes = [7u8; 32];
        let code = encode_recovery_code(&bytes);
        assert!(code.starts_with("NNTR-"));
        assert_eq!(decode_recovery_code(&code).unwrap().len(), 32);
        assert_eq!(decode_recovery_code(&code).unwrap(), bytes.to_vec());
    }
}
