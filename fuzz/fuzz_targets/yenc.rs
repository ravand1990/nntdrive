#![no_main]
use libfuzzer_sys::fuzz_target;
use nntdrive_nntp::{yenc_decode, yenc_encode};

fuzz_target!(|data: &[u8]| {
    if data.len() > 65_536 {
        return;
    }
    let _ = yenc_decode(data);
    // Reach authenticated decoding for every arbitrary binary input too.
    let decoded = yenc_decode(&yenc_encode("opaque", data)).expect("generated yEnc must decode");
    assert_eq!(decoded.data, data);
    assert_eq!(decoded.name, "opaque");
});
