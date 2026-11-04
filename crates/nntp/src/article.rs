//! Usenet article construction, Message-IDs and dot-stuffing.

use chrono::{DateTime, Utc};
use rand::{rngs::OsRng, RngCore};

#[derive(Debug, Clone)]
pub struct Article {
    pub message_id: String,
    pub subject: String,
    pub groups: Vec<String>,
    pub body: Vec<u8>,
    pub from: String,
    pub date: DateTime<Utc>,
}

impl Article {
    pub fn new(groups: Vec<String>, subject: String, body: Vec<u8>, message_id: String) -> Self {
        Self {
            message_id,
            subject,
            groups,
            body,
            from: "NNTDrive <nntdrive@localhost>".into(),
            date: Utc::now(),
        }
    }

    /// Full wire form, headers + dot-stuffed body, ready to be sent after the
    /// server's 340 response. Does not include the terminating ".\r\n".
    pub fn to_wire(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.body.len() + 512);
        out.extend_from_slice(format!("From: {}\r\n", self.from).as_bytes());
        out.extend_from_slice(format!("Newsgroups: {}\r\n", self.groups.join(",")).as_bytes());
        out.extend_from_slice(
            format!("Subject: {}\r\n", sanitize_header(&self.subject)).as_bytes(),
        );
        out.extend_from_slice(format!("Message-ID: <{}>\r\n", self.message_id).as_bytes());
        out.extend_from_slice(format!("Date: {}\r\n", self.date.to_rfc2822()).as_bytes());
        out.extend_from_slice(b"X-Newsreader: NNTDrive/0.1\r\n");
        out.extend_from_slice(b"MIME-Version: 1.0\r\n");
        out.extend_from_slice(b"Content-Type: application/octet-stream\r\n");
        out.extend_from_slice(b"Content-Transfer-Encoding: 8bit\r\n");
        out.extend_from_slice(b"\r\n");
        out.extend_from_slice(&dot_stuff(&self.body));
        out
    }

    pub fn raw_size(&self) -> usize {
        self.to_wire().len()
    }
}

fn sanitize_header(s: &str) -> String {
    s.chars()
        .map(|c| if c == '\r' || c == '\n' { ' ' } else { c })
        .collect()
}

/// Doubles a leading '.' on every line, as required by RFC 3977 section 3.1.1.
pub fn dot_stuff(body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len() + 16);
    let mut at_line_start = true;
    for &b in body {
        if at_line_start && b == b'.' {
            out.push(b'.');
        }
        out.push(b);
        at_line_start = b == b'\n';
    }
    out
}

pub fn dot_unstuff(body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len());
    let mut at_line_start = true;
    let mut i = 0;
    while i < body.len() {
        if at_line_start && body[i] == b'.' && body.get(i + 1) == Some(&b'.') {
            i += 1; // drop one of the two dots
        }
        out.push(body[i]);
        at_line_start = body[i] == b'\n';
        i += 1;
    }
    out
}

/// `<random>.<time>@domain`, unique without coordination.
pub fn new_message_id(domain: &str) -> String {
    let mut rnd = [0u8; 16];
    OsRng.fill_bytes(&mut rnd);
    format!(
        "{}.{}@{}",
        hex16(&rnd[..8]),
        Utc::now().timestamp_micros(),
        domain
    )
}

fn hex16(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn group_domain(message_id: &str) -> &str {
    message_id.rsplit_once('@').map(|(_, d)| d).unwrap_or("")
}

#[derive(Debug, Clone)]
pub struct ParsedArticle {
    pub headers: Vec<(String, String)>,
    pub message_id: Option<String>,
    pub subject: Option<String>,
    pub body: Vec<u8>,
}

impl ParsedArticle {
    pub fn parse(raw: &[u8]) -> Self {
        let split = raw
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .or_else(|| raw.windows(2).position(|w| w == b"\n\n"));
        let (head, body) = match split {
            Some(p) => {
                let sep = if raw[p..].starts_with(b"\r\n\r\n") {
                    4
                } else {
                    2
                };
                (&raw[..p], raw[p + sep..].to_vec())
            }
            None => (&raw[..0], raw.to_vec()),
        };
        let mut headers: Vec<(String, String)> = Vec::new();
        let mut last: Option<usize> = None;
        for line in String::from_utf8_lossy(head).split_inclusive('\n') {
            let line = line.trim_end_matches(['\r', '\n']);
            if line.starts_with([' ', '\t']) {
                if let Some(idx) = last {
                    headers[idx].1.push(' ');
                    headers[idx].1.push_str(line.trim_start());
                }
                continue;
            }
            if let Some((k, v)) = line.split_once(':') {
                headers.push((k.trim().to_ascii_lowercase(), v.trim().to_string()));
                last = Some(headers.len() - 1);
            }
        }
        let get = |name: &str| {
            headers
                .iter()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.clone())
        };
        let message_id = get("message-id").map(|v| {
            v.trim()
                .trim_start_matches('<')
                .trim_end_matches('>')
                .to_string()
        });
        Self {
            message_id,
            subject: get("subject"),
            headers,
            body,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_ids_are_unique_and_domain_scoped() {
        let a = new_message_id("example.test");
        let b = new_message_id("example.test");
        assert_ne!(a, b);
        assert_eq!(group_domain(&a), "example.test");
        assert!(!a.contains('<'));
    }

    #[test]
    fn dot_stuffing_roundtrip() {
        let body = b".first\r\n..second\r\nnormal\r\n.\r\n".to_vec();
        let stuffed = dot_stuff(&body);
        assert!(stuffed.starts_with(b"..first"));
        assert_eq!(dot_unstuff(&stuffed), body);
    }

    #[test]
    fn article_wire_and_parse() {
        let article = Article::new(
            vec!["alt.binaries.test".into()],
            "opaque subject\r\ninjected: header".into(),
            b"=ybegin size=0 name=x\r\n=yend size=0 pcrc32=00000000\r\n".to_vec(),
            new_message_id("nntdrive.local"),
        );
        let wire = article.to_wire();
        let parsed = ParsedArticle::parse(&wire);
        assert_eq!(
            parsed.message_id.as_deref(),
            Some(article.message_id.as_str())
        );
        // Header injection was neutralised.
        assert!(!parsed.headers.iter().any(|(k, _)| k == "injected"));
        assert!(parsed.body.starts_with(b"=ybegin"));
    }
}
