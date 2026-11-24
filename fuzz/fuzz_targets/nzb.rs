#![no_main]
use libfuzzer_sys::fuzz_target;
use nntdrive_nntp::Nzb;

fuzz_target!(|data: &[u8]| {
    if data.len() > 65_536 {
        return;
    }
    if let Ok(xml) = std::str::from_utf8(data) {
        // Existing parser tolerance is not a strict XML/NZB validation oracle.
        let _ = Nzb::parse(xml);
    }
});
