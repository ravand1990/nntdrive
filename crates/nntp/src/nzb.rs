//! NZB generation and parsing.
//!
//! NZBs are a convenience index: they let a user hand a file's article list to
//! an external downloader. NNTDrive never relies on NZBs as its source of
//! truth (message-ids inside the encrypted manifests are), so a lost NZB is not
//! data loss.

use quick_xml::events::Event;
use quick_xml::Reader;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NzbSegment {
    pub bytes: u64,
    pub number: u32,
    /// Message-ID without angle brackets.
    pub message_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NzbFile {
    pub poster: String,
    pub date: i64,
    pub subject: String,
    pub groups: Vec<String>,
    pub segments: Vec<NzbSegment>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Nzb {
    pub meta: Vec<(String, String)>,
    pub files: Vec<NzbFile>,
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

impl NzbSegment {
    fn normalized_id(&self) -> String {
        self.message_id
            .trim()
            .trim_start_matches('<')
            .trim_end_matches('>')
            .to_string()
    }
}

impl Nzb {
    pub fn new(title: &str) -> Self {
        Self {
            meta: vec![("title".into(), title.into())],
            files: Vec::new(),
        }
    }

    pub fn to_xml(&self) -> String {
        let mut out = String::from(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <!DOCTYPE nzb PUBLIC \"-//newzBin//DTD NZB 1.1//EN\" \"http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd\">\n\
             <nzb xmlns=\"http://www.newzbin.com/DTD/2003/nzb\">\n  <head>\n",
        );
        for (k, v) in &self.meta {
            out.push_str(&format!(
                "    <meta type=\"{}\">{}</meta>\n",
                escape(k),
                escape(v)
            ));
        }
        out.push_str("  </head>\n");
        for f in &self.files {
            out.push_str(&format!(
                "  <file poster=\"{}\" date=\"{}\" subject=\"{}\">\n    <groups>\n",
                escape(&f.poster),
                f.date,
                escape(&f.subject)
            ));
            for g in &f.groups {
                out.push_str(&format!("      <group>{}</group>\n", escape(g)));
            }
            out.push_str("    </groups>\n    <segments>\n");
            for s in &f.segments {
                out.push_str(&format!(
                    "      <segment bytes=\"{}\" number=\"{}\">{}</segment>\n",
                    s.bytes,
                    s.number,
                    escape(&format!("<{}>", s.normalized_id()))
                ));
            }
            out.push_str("    </segments>\n  </file>\n");
        }
        out.push_str("</nzb>\n");
        out
    }

    pub fn parse(xml: &str) -> Result<Self, String> {
        let mut reader = Reader::from_str(xml);
        reader.config_mut().trim_text(true);
        let mut nzb = Nzb {
            meta: Vec::new(),
            files: Vec::new(),
        };
        let mut current: Option<NzbFile> = None;
        let mut current_segment: Option<(u64, u32, String)> = None;
        let mut meta_type: Option<String> = None;
        let mut buf = Vec::new();

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                    let name = e.name().as_ref().to_vec();
                    match name.as_slice() {
                        b"file" => {
                            let mut file = NzbFile {
                                poster: String::new(),
                                date: 0,
                                subject: String::new(),
                                groups: Vec::new(),
                                segments: Vec::new(),
                            };
                            for a in e.attributes().flatten() {
                                let val = String::from_utf8_lossy(&a.value).to_string();
                                match a.key.as_ref() {
                                    b"poster" => file.poster = val,
                                    b"subject" => file.subject = val,
                                    b"date" => file.date = val.parse().unwrap_or(0),
                                    _ => {}
                                }
                            }
                            current = Some(file);
                        }
                        b"segment" => {
                            let mut bytes = 0u64;
                            let mut number = 0u32;
                            for a in e.attributes().flatten() {
                                let val = String::from_utf8_lossy(&a.value).to_string();
                                match a.key.as_ref() {
                                    b"bytes" => bytes = val.parse().unwrap_or(0),
                                    b"number" => number = val.parse().unwrap_or(0),
                                    _ => {}
                                }
                            }
                            current_segment = Some((bytes, number, String::new()));
                        }
                        b"meta" => {
                            for a in e.attributes().flatten() {
                                if a.key.as_ref() == b"type" {
                                    meta_type = Some(String::from_utf8_lossy(&a.value).to_string());
                                }
                            }
                        }
                        _ => {}
                    }
                }
                Ok(Event::Text(t)) => {
                    let raw = String::from_utf8_lossy(t.as_ref());
                    let text = quick_xml::escape::unescape(&raw)
                        .map_err(|e| e.to_string())?
                        .to_string();
                    if let Some(seg) = current_segment.as_mut() {
                        seg.2.push_str(&text);
                    } else if let Some(kind) = meta_type.take() {
                        nzb.meta.push((kind, text));
                    }
                }
                Ok(Event::End(e)) => match e.name().as_ref() {
                    b"segment" => {
                        if let (Some((bytes, number, id)), Some(file)) =
                            (current_segment.take(), current.as_mut())
                        {
                            file.segments.push(NzbSegment {
                                bytes,
                                number,
                                message_id: id
                                    .trim()
                                    .trim_start_matches('<')
                                    .trim_end_matches('>')
                                    .to_string(),
                            });
                        }
                    }
                    b"group" => {}
                    b"file" => {
                        if let Some(file) = current.take() {
                            nzb.files.push(file);
                        }
                    }
                    _ => {}
                },
                Ok(Event::Eof) => break,
                Err(e) => return Err(format!("malformed NZB: {e}")),
                _ => {}
            }
            buf.clear();
        }
        Ok(nzb)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Nzb {
        Nzb {
            meta: vec![("title".into(), "chunk A&B".into())],
            files: vec![NzbFile {
                poster: "NNTDrive <nntdrive@localhost>".into(),
                date: 1_760_000_000,
                subject: "[NNTDrive] opaque".into(),
                groups: vec!["alt.binaries.test".into()],
                segments: vec![
                    NzbSegment {
                        bytes: 1024,
                        number: 1,
                        message_id: "a@nntdrive".into(),
                    },
                    NzbSegment {
                        bytes: 999,
                        number: 2,
                        message_id: "b&c@nntdrive".into(),
                    },
                ],
            }],
        }
    }

    #[test]
    fn roundtrip() {
        let original = sample();
        let xml = original.to_xml();
        assert!(xml.contains("&amp;"));
        let parsed = Nzb::parse(&xml).unwrap();
        assert_eq!(parsed.meta[0].1, "chunk A&B");
        assert_eq!(parsed.files[0].segments.len(), 2);
        assert_eq!(parsed.files[0].segments[1].message_id, "b&c@nntdrive");
        assert_eq!(parsed.files[0].segments[0].bytes, 1024);
    }

    #[test]
    fn parses_foreign_nzb_with_angle_brackets() {
        let xml = r#"<?xml version="1.0"?>
<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
<file poster="p" date="1" subject="s">
<groups><group>alt.binaries.test</group></groups>
<segments><segment bytes="10" number="1"> &lt;abc@example&gt; </segment></segments>
</file></nzb>"#;
        let parsed = Nzb::parse(xml).unwrap();
        assert_eq!(parsed.files[0].segments[0].message_id, "abc@example");
    }

    #[test]
    fn malformed_xml_is_an_error() {
        assert!(Nzb::parse("<nzb><head><meta type=\"title\">&bogus;</meta></head></nzb>").is_err());
    }
}
