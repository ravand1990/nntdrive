#![no_main]
use libfuzzer_sys::fuzz_target;
use nntdrive_nntp::{
    article::{dot_stuff, dot_unstuff},
    ParsedArticle,
};

fuzz_target!(|data: &[u8]| {
    if data.len() > 65_536 {
        return;
    }
    let parsed = ParsedArticle::parse(data);
    assert!(parsed.body.len() <= data.len());
    assert_eq!(dot_unstuff(&dot_stuff(data)), data);
});
