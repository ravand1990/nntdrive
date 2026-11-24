//! Public, synthetic seeds stay deterministic ordinary regression fixtures.
use nntdrive_nntp::{
    article::{dot_stuff, dot_unstuff},
    yenc_decode, yenc_encode, Nzb, ParsedArticle,
};

#[test]
fn yenc_seed_corpus_and_binary_roundtrips() {
    assert!(
        yenc_decode(include_bytes!("../../../fuzz/seeds/yenc/empty"))
            .unwrap()
            .data
            .is_empty()
    );
    for seed in [
        include_bytes!("../../../fuzz/seeds/yenc/truncated").as_slice(),
        include_bytes!("../../../fuzz/seeds/yenc/oversized").as_slice(),
    ] {
        assert!(yenc_decode(seed).is_err());
    }
    for len in [0, 1, 127, 128, 129, 256, 65_536] {
        let bytes: Vec<_> = (0..=255).cycle().take(len).collect();
        assert_eq!(
            yenc_decode(&yenc_encode("opaque", &bytes)).unwrap().data,
            bytes
        );
    }
}

#[test]
fn nzb_seed_corpus_preserves_entities_and_rejects_duplicate_attributes() {
    let parsed = Nzb::parse(include_str!("../../../fuzz/seeds/nzb/entities")).unwrap();
    assert_eq!(parsed.meta[0].1, "A&B é");
    assert_eq!(parsed.files[0].segments[0].message_id, "a@example.test");
    assert!(Nzb::parse(include_str!("../../../fuzz/seeds/nzb/duplicate")).is_err());
    // Incomplete XML is intentionally not a strict-error oracle: the existing
    // parser accepts some EOF states. It must still terminate without panic.
    let _ = Nzb::parse(include_str!("../../../fuzz/seeds/nzb/truncated"));
}

#[test]
fn article_seed_corpus_and_binary_dot_roundtrips() {
    let folded = ParsedArticle::parse(include_bytes!("../../../fuzz/seeds/article/folded"));
    assert_eq!(folded.message_id.as_deref(), Some("opaque@example.test"));
    assert_eq!(folded.subject.as_deref(), Some("opaque continuation"));
    for seed in [
        include_bytes!("../../../fuzz/seeds/article/folded").as_slice(),
        include_bytes!("../../../fuzz/seeds/article/lf").as_slice(),
        include_bytes!("../../../fuzz/seeds/article/truncated").as_slice(),
    ] {
        assert!(ParsedArticle::parse(seed).body.len() <= seed.len());
        assert_eq!(dot_unstuff(&dot_stuff(seed)), seed);
    }
    let bytes: Vec<_> = (0..=255).cycle().take(65_536).collect();
    assert_eq!(dot_unstuff(&dot_stuff(&bytes)), bytes);
}
