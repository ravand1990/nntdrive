use nntdrive_nntp::{Nzb, NzbFile, NzbSegment};

#[test]
fn generated_nzb_preserves_metadata_and_article_identity() {
    let original = Nzb {
        meta: vec![("title".into(), "chunk A&B <opaque> \"é\"".into())],
        files: vec![NzbFile {
            poster: "poster".into(),
            date: 1_760_000_000,
            subject: "opaque".into(),
            groups: vec!["alt.binaries.test".into()],
            segments: vec![NzbSegment {
                bytes: 1024,
                number: 1,
                message_id: "a&b@example".into(),
            }],
        }],
    };
    let parsed = Nzb::parse(&original.to_xml()).unwrap();
    assert_eq!(parsed.meta, original.meta);
    assert_eq!(parsed.files[0].poster, "poster");
    assert_eq!(parsed.files[0].date, 1_760_000_000);
    assert_eq!(parsed.files[0].subject, "opaque");
    assert_eq!(parsed.files[0].segments, original.files[0].segments);
    // Group collection is not part of the existing parser contract.
}

#[test]
fn foreign_nzb_preserves_entities_and_multiple_articles() {
    let parsed = Nzb::parse(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd">
<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
<head><meta type="title">A&amp;B &#233; &#x1F512;</meta><meta type="category">test</meta></head>
<!-- External DTDs need not be fetched. -->
<file subject="opaque" date="-1" poster="p"><segments>
<segment number="2" bytes="99"> &lt;b&amp;c@example&gt; </segment>
<segment bytes="10" number="1">a@example</segment>
</segments></file>
<file poster="q" date="2" subject="other"><segments>
<segment bytes="7" number="1">d@example</segment>
</segments></file></nzb>"#,
    )
    .unwrap();
    assert_eq!(
        parsed.meta,
        [
            ("title".into(), "A&B é 🔒".into()),
            ("category".into(), "test".into())
        ]
    );
    assert_eq!(parsed.files.len(), 2);
    assert_eq!(parsed.files[0].date, -1);
    assert_eq!(
        parsed.files[0].segments,
        [
            NzbSegment {
                bytes: 99,
                number: 2,
                message_id: "b&c@example".into()
            },
            NzbSegment {
                bytes: 10,
                number: 1,
                message_id: "a@example".into()
            },
        ]
    );
    assert_eq!(parsed.files[1].segments[0].message_id, "d@example");
}

#[test]
fn invalid_xml_returns_an_error() {
    for xml in [
        "<nzb><file></nzb>",
        "<nzb><head><meta type=\"title\">&unknown;</meta></head></nzb>",
        "<nzb><file poster=unquoted></file></nzb>",
        "<nzb><file><segment bytes=unquoted>id</segment></file></nzb>",
        "<nzb><head><meta type=unquoted>title</meta></head></nzb>",
    ] {
        assert!(Nzb::parse(xml).is_err(), "accepted malformed NZB: {xml}");
    }
}

#[test]
fn duplicate_attributes_return_an_error() {
    for xml in [
        "<nzb><file poster=\"a\" poster=\"b\"></file></nzb>",
        "<nzb><file><segment bytes=\"1\" bytes=\"2\">id</segment></file></nzb>",
        "<nzb><head><meta type=\"title\" type=\"category\">x</meta></head></nzb>",
    ] {
        assert!(
            Nzb::parse(xml).is_err(),
            "accepted duplicate attributes: {xml}"
        );
    }
}

#[test]
fn bounded_attribute_lists_keep_duplicate_checks_enabled() {
    // Fixed small bounds exercise the actual caller, not timing or allocation limits.
    for count in [1, 16, 128] {
        let attrs: String = (0..count).map(|i| format!(" x{i}=\"v\"")).collect();
        let valid = format!("<nzb><file{attrs} poster=\"p\"></file></nzb>");
        assert_eq!(Nzb::parse(&valid).unwrap().files[0].poster, "p");
        let duplicate = format!("<nzb><file{attrs} x0=\"duplicate\"></file></nzb>");
        assert!(
            Nzb::parse(&duplicate).is_err(),
            "accepted {count}-attribute duplicate"
        );
    }
}
