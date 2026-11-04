//! NNTP transport for NNTDrive.
//!
//! * [`client`] - TLS client, connection pooling, retries, STAT/BODY/POST.
//! * [`yenc`] - yEnc 1.2 with CRC32 verification.
//! * [`nzb`] - NZB generation/parsing.
//! * [`mock`] - in-process NNTP server used by tests (delete/corrupt/expire).

pub mod article;
pub mod client;
pub mod mock;
pub mod nzb;
pub mod yenc;

pub use article::{group_domain, new_message_id, Article, ParsedArticle};
pub use client::{NntpConfig, NntpError, NntpPool, Provider, ProviderRole, ProviderStatsSnapshot};
pub use mock::{MockConfig, MockNntpServer, MockStore};
pub use nzb::{Nzb, NzbFile, NzbSegment};
pub use yenc::{decode as yenc_decode, encode as yenc_encode, YencData};

/// Environment-driven provider configuration for the CLI and backend.
/// Format: `NNTDRIVE_NNTP_PROVIDERS` holds a JSON array of [`NntpConfig`].
pub fn parse_providers(json: &str) -> Result<Vec<NntpConfig>, serde_json::Error> {
    serde_json::from_str(json)
}

pub fn eweka_config(username: String, password: String) -> NntpConfig {
    NntpConfig {
        name: "eweka".into(),
        host: "news.eweka.nl".into(),
        port: 563,
        tls: true,
        username: Some(username),
        password: Some(password),
        max_connections: 8,
        role: ProviderRole::Both,
        priority: 0,
        groups: vec!["alt.binaries.nntdrive".into()],
        message_id_domain: "nntdrive.local".into(),
        connect_timeout_secs: 30,
        io_timeout_secs: 60,
        retention_days: None,
        max_retries: 3,
    }
}
