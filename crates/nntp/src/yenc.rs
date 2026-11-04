//! yEnc 1.2 encoding/decoding (single-part articles).
//!
//! We use yEnc because it is the de-facto binary format on Usenet and is
//! understood by every provider's tooling. CRC32 is verified on decode; a
//! mismatch is an error, never a warning.

use crc32fast::Hasher;

#[derive(Debug, thiserror::Error)]
pub enum YencError {
    #[error("missing yEnc begin/end marker")]
    MissingMarkers,
    #[error("malformed yEnc header: {0}")]
    BadHeader(&'static str),
    #[error("yEnc size mismatch: header {expected}, decoded {actual}")]
    SizeMismatch { expected: usize, actual: usize },
    #[error("yEnc CRC32 mismatch")]
    CrcMismatch,
    #[error("unsupported multi-part yEnc article (part != 1/1)")]
    Multipart,
    #[error("invalid escape sequence at end of input")]
    TruncatedEscape,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct YencData {
    pub name: String,
    pub data: Vec<u8>,
    pub crc32: u32,
}

const LINE_LEN: usize = 128;
const ESCAPE_COST: usize = 8; // escape roughly 1 in 64 bytes + CRLF

/// Worst-case encoded size including headers.
pub fn max_encoded_len(input_len: usize) -> usize {
    input_len + input_len / ESCAPE_COST + input_len / LINE_LEN * 2 + 256
}

fn escape_needed(byte: u8, at_line_start: bool) -> bool {
    matches!(byte, 0x00 | 0x0A | 0x0D | 0x3D)
        || (at_line_start && (byte == b'.' || byte == b' ' || byte == b'\t'))
        || byte == b' '
        || byte == b'\t'
}

/// Encodes `data`. `name` is opaque (chunk id), never a plaintext filename.
pub fn encode(name: &str, data: &[u8]) -> Vec<u8> {
    let crc = {
        let mut h = Hasher::new();
        h.update(data);
        h.finalize()
    };
    let mut out = Vec::with_capacity(max_encoded_len(data.len()));
    out.extend_from_slice(
        format!(
            "=ybegin part=1 total=1 line={} size={} name={}\r\n",
            LINE_LEN,
            data.len(),
            sanitize_name(name)
        )
        .as_bytes(),
    );

    let mut line_len = 0usize;
    for &b in data {
        let mut encoded = b.wrapping_add(42);
        let at_start = line_len == 0;
        if escape_needed(encoded, at_start) {
            out.push(b'=');
            encoded = encoded.wrapping_add(64);
            line_len += 1;
        }
        out.push(encoded);
        line_len += 1;
        if line_len >= LINE_LEN {
            out.extend_from_slice(b"\r\n");
            line_len = 0;
        }
    }
    if line_len > 0 {
        out.extend_from_slice(b"\r\n");
    }
    out.extend_from_slice(
        format!("=yend size={} part=1 pcrc32={:08x}\r\n", data.len(), crc).as_bytes(),
    );
    out
}

fn sanitize_name(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_graphic() && c != '=' {
                c
            } else {
                '_'
            }
        })
        .take(200)
        .collect()
}

/// Decodes a single-part yEnc body. Header names are informational only; the
/// caller must verify size and identity against its own manifest.
pub fn decode(input: &[u8]) -> Result<YencData, YencError> {
    let mut pos = 0usize;
    let mut begin_line: Option<&[u8]> = None;
    while pos < input.len() {
        let end = input[pos..]
            .iter()
            .position(|&b| b == b'\n')
            .map(|p| pos + p)
            .unwrap_or(input.len());
        let line = &input[pos..end];
        if line.starts_with(b"=ybegin ") {
            begin_line = Some(line);
            pos = end + 1;
            break;
        }
        pos = end + 1;
    }
    let begin = begin_line.ok_or(YencError::MissingMarkers)?;
    let begin = std::str::from_utf8(begin).map_err(|_| YencError::BadHeader("non-ascii header"))?;
    let mut name = String::new();
    let mut declared_size = None;
    for field in begin["=ybegin ".len()..].split_whitespace() {
        if let Some(v) = field.strip_prefix("name=") {
            name = v.to_string();
        } else if let Some(v) = field.strip_prefix("size=") {
            declared_size = v.parse::<usize>().ok();
        } else if let Some(v) = field.strip_prefix("part=") {
            if v != "1" {
                return Err(YencError::Multipart);
            }
        }
    }
    let declared_size = declared_size.ok_or(YencError::BadHeader("missing size"))?;

    let mut data = Vec::with_capacity(declared_size);
    let mut crc = None;
    let mut ended = false;
    while pos < input.len() {
        let end = input[pos..]
            .iter()
            .position(|&b| b == b'\n')
            .map(|p| pos + p)
            .unwrap_or(input.len());
        let mut line = &input[pos..end];
        pos = end + 1;
        if line.ends_with(b"\r") {
            line = &line[..line.len() - 1];
        }
        if let Some(rest) = line.strip_prefix(b"=yend ") {
            for field in String::from_utf8_lossy(rest).split_whitespace() {
                if let Some(v) = field
                    .strip_prefix("pcrc32=")
                    .or_else(|| field.strip_prefix("crc32="))
                {
                    crc = u32::from_str_radix(v, 16).ok();
                }
            }
            ended = true;
            break;
        }
        if line.starts_with(b"=ypart ") {
            return Err(YencError::Multipart);
        }
        if line.is_empty() {
            continue;
        }
        let mut i = 0;
        while i < line.len() {
            let b = line[i];
            if b == b'=' {
                let next = *line.get(i + 1).ok_or(YencError::TruncatedEscape)?;
                data.push(next.wrapping_sub(64).wrapping_sub(42));
                i += 2;
            } else {
                data.push(b.wrapping_sub(42));
                i += 1;
            }
        }
    }
    if !ended {
        return Err(YencError::MissingMarkers);
    }
    if data.len() != declared_size {
        return Err(YencError::SizeMismatch {
            expected: declared_size,
            actual: data.len(),
        });
    }
    let actual_crc = {
        let mut h = Hasher::new();
        h.update(&data);
        h.finalize()
    };
    if let Some(expected) = crc {
        if expected != actual_crc {
            return Err(YencError::CrcMismatch);
        }
    } else {
        return Err(YencError::BadHeader("missing crc32"));
    }
    Ok(YencData {
        name,
        data,
        crc32: actual_crc,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_all_byte_values() {
        let data: Vec<u8> = (0..=255u8).cycle().take(10_000).collect();
        let encoded = encode("abc123", &data);
        assert!(encoded.starts_with(b"=ybegin "));
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded.data, data);
        assert_eq!(decoded.name, "abc123");
    }

    #[test]
    fn escapes_leading_dot_and_crlf() {
        let data = b".\r\n=hello \x00world".to_vec();
        let encoded = encode("x", &data);
        assert!(!encoded.windows(3).any(|w| w == b"\r\n.\r"));
        assert_eq!(decode(&encoded).unwrap().data, data);
    }

    #[test]
    fn corrupted_payload_fails_crc() {
        let mut encoded = encode("x", b"the quick brown fox jumps over the lazy dog");
        let begin = encoded.windows(2).position(|w| w == b"\r\n").unwrap() + 2;
        let mut pos = begin + 5;
        while matches!(encoded[pos], b'\r' | b'\n' | b'=') {
            pos += 1;
        }
        encoded[pos] = encoded[pos].wrapping_add(1);
        assert!(matches!(decode(&encoded), Err(YencError::CrcMismatch)));
    }

    #[test]
    fn truncated_input_fails() {
        let encoded = encode("x", &vec![7u8; 500]);
        let truncated = &encoded[..encoded.len() / 2];
        assert!(decode(truncated).is_err());
    }

    #[test]
    fn rejects_multipart() {
        let input = b"=ybegin part=2 total=3 line=128 size=10 name=x\r\n=k\r\n=yend size=10 part=2 pcrc32=00000000\r\n";
        assert!(matches!(decode(input), Err(YencError::Multipart)));
    }

    #[test]
    fn encoded_size_bound_is_safe() {
        let data = [0u8; 4096];
        assert!(encode("x", &data).len() < max_encoded_len(data.len()));
    }
}
