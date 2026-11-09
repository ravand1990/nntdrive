//! NNTP client: TLS, authentication, posting, STAT/BODY, pooling and retries.
//!
//! A [`NntpPool`] owns one [`Provider`] per configured server. Providers are
//! independent: posting can use a different account from retrieval, and every
//! article is addressed by its Message-ID, so any provider carrying the group
//! can serve it.

use crate::article::{dot_unstuff, Article};
use crate::yenc;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use tokio_rustls::rustls::{ClientConfig, RootCertStore};
use tokio_rustls::TlsConnector;

#[derive(Debug, thiserror::Error)]
pub enum NntpError {
    #[error("network error: {0}")]
    Io(#[from] std::io::Error),
    #[error("TLS error: {0}")]
    Tls(String),
    #[error("NNTP protocol error {code}: {message}")]
    Protocol { code: u16, message: String },
    #[error("timed out talking to NNTP server")]
    Timeout,
    #[error("NNTP authentication failed")]
    Auth,
    #[error("provider {0} does not allow posting")]
    PostingDisabled(String),
    #[error("article not found")]
    NotFound,
    #[error("all providers failed; last error: {0}")]
    AllProvidersFailed(String),
    #[error("invalid NNTP configuration: {0}")]
    Config(String),
    #[error("yEnc error: {0}")]
    Yenc(#[from] yenc::YencError),
}

pub type Result<T> = std::result::Result<T, NntpError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderRole {
    Both,
    PostingOnly,
    RetrievalOnly,
}

/// Configuration for one Usenet provider. Deserialize from the admin API /
/// environment; password is never included in `Debug` output.
#[derive(Clone, Serialize, Deserialize)]
pub struct NntpConfig {
    pub name: String,
    pub host: String,
    pub port: u16,
    pub tls: bool,
    pub username: Option<String>,
    pub password: Option<String>,
    pub max_connections: usize,
    pub role: ProviderRole,
    /// Lower value is preferred.
    pub priority: u8,
    /// Groups to post to. Retrieval uses Message-IDs, so groups are cosmetic
    /// for downloading but required for posting.
    pub groups: Vec<String>,
    #[serde(default = "default_group_domain")]
    pub message_id_domain: String,
    #[serde(default = "default_timeout")]
    pub connect_timeout_secs: u64,
    #[serde(default = "default_timeout")]
    pub io_timeout_secs: u64,
    /// Retention advertised by the provider, if known. Health/retention jobs
    /// use it only as a hint; never as a guarantee.
    #[serde(default)]
    pub retention_days: Option<u32>,
    #[serde(default)]
    pub max_retries: u32,
}

fn default_timeout() -> u64 {
    30
}

fn default_group_domain() -> String {
    "nntdrive.local".into()
}

impl std::fmt::Debug for NntpConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NntpConfig")
            .field("name", &self.name)
            .field("host", &self.host)
            .field("port", &self.port)
            .field("tls", &self.tls)
            .field("username", &self.username)
            .field("password", &self.password.as_ref().map(|_| "[redacted]"))
            .field("max_connections", &self.max_connections)
            .field("role", &self.role)
            .field("priority", &self.priority)
            .field("groups", &self.groups)
            .field("retention_days", &self.retention_days)
            .finish()
    }
}

impl NntpConfig {
    pub fn validate(&self) -> Result<()> {
        if self.name.trim().is_empty()
            || self.host.trim().is_empty()
            || self.host.chars().any(char::is_whitespace)
        {
            return Err(NntpError::Config("host is required".into()));
        }
        if self.port == 0 {
            return Err(NntpError::Config("port must be non-zero".into()));
        }
        if self.max_connections == 0 || self.max_connections > 200 {
            return Err(NntpError::Config("max_connections must be 1..=200".into()));
        }
        if self.groups.is_empty()
            || self
                .groups
                .iter()
                .any(|g| g.is_empty() || g.chars().any(|c| c.is_whitespace() || c == ','))
        {
            return Err(NntpError::Config("at least one group is required".into()));
        }
        if self
            .username
            .iter()
            .chain(self.password.iter())
            .any(|v| v.contains(['\r', '\n']))
        {
            return Err(NntpError::Config("invalid provider credentials".into()));
        }
        if self.username.is_some() != self.password.is_some() {
            return Err(NntpError::Config(
                "username and password must be set together".into(),
            ));
        }
        Ok(())
    }

    pub fn can_post(&self) -> bool {
        matches!(self.role, ProviderRole::Both | ProviderRole::PostingOnly)
    }

    pub fn can_fetch(&self) -> bool {
        matches!(self.role, ProviderRole::Both | ProviderRole::RetrievalOnly)
    }
}

/// Stats exposed to the admin dashboard.
#[derive(Debug, Default)]
pub struct ProviderStats {
    pub posts: AtomicU64,
    pub post_failures: AtomicU64,
    pub fetches: AtomicU64,
    pub fetch_failures: AtomicU64,
    pub bytes_posted: AtomicU64,
    pub bytes_fetched: AtomicU64,
    pub connections_opened: AtomicU64,
}

#[derive(Debug, Default, Clone, Serialize)]
pub struct ProviderStatsSnapshot {
    pub posts: u64,
    pub post_failures: u64,
    pub fetches: u64,
    pub fetch_failures: u64,
    pub bytes_posted: u64,
    pub bytes_fetched: u64,
    pub connections_opened: u64,
}

impl ProviderStats {
    pub fn snapshot(&self) -> ProviderStatsSnapshot {
        ProviderStatsSnapshot {
            posts: self.posts.load(Ordering::Relaxed),
            post_failures: self.post_failures.load(Ordering::Relaxed),
            fetches: self.fetches.load(Ordering::Relaxed),
            fetch_failures: self.fetch_failures.load(Ordering::Relaxed),
            bytes_posted: self.bytes_posted.load(Ordering::Relaxed),
            bytes_fetched: self.bytes_fetched.load(Ordering::Relaxed),
            connections_opened: self.connections_opened.load(Ordering::Relaxed),
        }
    }
}

pub struct Provider {
    config: NntpConfig,
    idle: Arc<Mutex<Vec<Connection>>>,
    open: Arc<AtomicU64>,
    notify: Arc<tokio::sync::Notify>,
    pub stats: ProviderStats,
}

impl Provider {
    pub fn new(config: NntpConfig) -> Result<Arc<Self>> {
        config.validate()?;
        Ok(Arc::new(Self {
            config,
            idle: Arc::new(Mutex::new(Vec::new())),
            open: Arc::new(AtomicU64::new(0)),
            notify: Arc::new(tokio::sync::Notify::new()),
            stats: ProviderStats::default(),
        }))
    }

    pub fn name(&self) -> &str {
        &self.config.name
    }

    pub fn config(&self) -> &NntpConfig {
        &self.config
    }

    async fn acquire(&self) -> Result<ConnectionGuard<'_>> {
        loop {
            if let Some(conn) = self.idle.lock().await.pop() {
                return Ok(ConnectionGuard {
                    provider: self,
                    conn: Some(conn),
                });
            }
            let current = self.open.load(Ordering::Acquire);
            if (current as usize) < self.config.max_connections
                && self
                    .open
                    .compare_exchange(current, current + 1, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok()
            {
                match Connection::connect(&self.config).await {
                    Ok(conn) => {
                        self.stats
                            .connections_opened
                            .fetch_add(1, Ordering::Relaxed);
                        return Ok(ConnectionGuard {
                            provider: self,
                            conn: Some(conn),
                        });
                    }
                    Err(e) => {
                        self.open.fetch_sub(1, Ordering::AcqRel);
                        self.notify.notify_one();
                        return Err(e);
                    }
                }
            }
            // All connection slots are busy; wait for a release or close.
            let notified = self.notify.notified();
            // Re-check after registering interest to avoid a lost wakeup.
            if let Some(conn) = self.idle.lock().await.pop() {
                return Ok(ConnectionGuard {
                    provider: self,
                    conn: Some(conn),
                });
            }
            notified.await;
        }
    }

    fn backoff(&self, attempt: u32) -> Duration {
        let base = 250u64.saturating_mul(1 << attempt.min(6));
        Duration::from_millis(base.min(8_000))
    }

    /// Posts one article. Retries transient failures, reconnecting each time.
    pub async fn post(&self, article: &Article) -> Result<()> {
        if !self.config.can_post() {
            return Err(NntpError::PostingDisabled(self.config.name.clone()));
        }
        let payload = article.to_wire();
        let mut last_err = None;
        for attempt in 0..=self.config.max_retries {
            match self.post_once(article, &payload).await {
                Ok(()) => {
                    self.stats.posts.fetch_add(1, Ordering::Relaxed);
                    self.stats
                        .bytes_posted
                        .fetch_add(payload.len() as u64, Ordering::Relaxed);
                    return Ok(());
                }
                Err(e) if !is_retryable(&e) => {
                    self.stats.post_failures.fetch_add(1, Ordering::Relaxed);
                    return Err(e);
                }
                Err(e) => {
                    tracing::warn!(provider = %self.config.name, attempt, error = %e, "post failed, retrying");
                    last_err = Some(e);
                    tokio::time::sleep(self.backoff(attempt)).await;
                }
            }
        }
        self.stats.post_failures.fetch_add(1, Ordering::Relaxed);
        Err(last_err.unwrap_or_else(|| NntpError::AllProvidersFailed("post failed".into())))
    }

    async fn post_once(&self, article: &Article, payload: &[u8]) -> Result<()> {
        let mut guard = self.acquire().await?;
        let conn = guard.conn.as_mut().expect("connection present");
        conn.write_line("POST").await?;
        let (code, _) = conn.read_reply().await?;
        if code != 340 {
            return Err(match code {
                440 => NntpError::PostingDisabled(self.config.name.clone()),
                480..=482 => NntpError::Auth,
                _ => NntpError::Protocol {
                    code,
                    message: "POST not accepted".into(),
                },
            });
        }
        conn.write_all(payload).await?;
        conn.write_all(b"\r\n.\r\n").await?;
        let (code, msg) = conn.read_reply().await?;
        if code == 240 {
            // Confirm the article is addressable before reporting success.
            let (stat_code, _) = conn
                .command_line(&format!("STAT <{}>", article.message_id))
                .await?;
            // Some providers index with a short delay; a failed immediate STAT
            // is retried by the uploader's verification step, not here.
            if stat_code == 430 {
                tracing::debug!(message_id = %article.message_id, "article posted but not yet visible to STAT");
            }
            guard.release();
            Ok(())
        } else {
            Err(NntpError::Protocol {
                code,
                message: msg.first().cloned().unwrap_or_default(),
            })
        }
    }

    /// Returns the article's raw size if the provider has it.
    pub async fn stat(&self, message_id: &str) -> Result<Option<u64>> {
        if !self.config.can_fetch() {
            return Ok(None);
        }
        let mut last_err = None;
        for attempt in 0..=self.config.max_retries {
            match self.stat_once(message_id).await {
                Ok(v) => return Ok(v),
                Err(e) if !is_retryable(&e) => return Err(e),
                Err(e) => {
                    last_err = Some(e);
                    tokio::time::sleep(self.backoff(attempt)).await;
                }
            }
        }
        Err(last_err.unwrap_or_else(|| NntpError::AllProvidersFailed("STAT failed".into())))
    }

    async fn stat_once(&self, message_id: &str) -> Result<Option<u64>> {
        let mut guard = self.acquire().await?;
        let conn = guard.conn.as_mut().expect("connection present");
        let (code, lines) = conn.command_line(&format!("STAT <{}>", message_id)).await?;
        guard.release();
        self.stats.fetches.fetch_add(1, Ordering::Relaxed);
        match code {
            223 => {
                // 223 0 <message-id>  (some servers append size)
                let size = lines
                    .first()
                    .and_then(|l| l.split_whitespace().nth(2))
                    .and_then(|s| s.parse().ok());
                Ok(Some(size.unwrap_or(0)))
            }
            430 => {
                self.stats.fetch_failures.fetch_add(1, Ordering::Relaxed);
                Ok(None)
            }
            _ => Err(NntpError::Protocol {
                code,
                message: lines.join(" "),
            }),
        }
    }

    /// Fetches and decodes one single-part yEnc article.
    pub async fn fetch(&self, message_id: &str) -> Result<Vec<u8>> {
        if !self.config.can_fetch() {
            return Err(NntpError::Config(format!(
                "provider {} is posting-only",
                self.config.name
            )));
        }
        let mut last_err = None;
        for attempt in 0..=self.config.max_retries {
            match self.fetch_once(message_id).await {
                Ok(data) => {
                    self.stats.fetches.fetch_add(1, Ordering::Relaxed);
                    self.stats
                        .bytes_fetched
                        .fetch_add(data.len() as u64, Ordering::Relaxed);
                    return Ok(data);
                }
                Err(e) if !is_retryable(&e) => {
                    self.stats.fetch_failures.fetch_add(1, Ordering::Relaxed);
                    return Err(e);
                }
                Err(e) => {
                    last_err = Some(e);
                    tokio::time::sleep(self.backoff(attempt)).await;
                }
            }
        }
        self.stats.fetch_failures.fetch_add(1, Ordering::Relaxed);
        Err(last_err.unwrap_or_else(|| NntpError::AllProvidersFailed("fetch failed".into())))
    }

    async fn fetch_once(&self, message_id: &str) -> Result<Vec<u8>> {
        let mut guard = self.acquire().await?;
        let conn = guard.conn.as_mut().expect("connection present");
        let (code, _) = conn.command_line(&format!("BODY <{}>", message_id)).await?;
        if code == 430 {
            return Err(NntpError::NotFound);
        }
        if code != 222 {
            return Err(NntpError::Protocol {
                code,
                message: "BODY failed".into(),
            });
        }
        let raw = conn.read_multiline().await?;
        guard.release();
        // BODY returns the article body only (no headers); decode it directly.
        let decoded = yenc::decode(&raw)?;
        Ok(decoded.data)
    }

    /// HEAD request used to check availability without transferring data.
    pub async fn head(&self, message_id: &str) -> Result<bool> {
        let mut guard = self.acquire().await?;
        let conn = guard.conn.as_mut().expect("connection present");
        let (code, _) = conn.command_line(&format!("HEAD <{}>", message_id)).await?;
        guard.release();
        Ok(code == 221)
    }
}

fn is_retryable(e: &NntpError) -> bool {
    match e {
        NntpError::Io(_) | NntpError::Timeout | NntpError::Tls(_) => true,
        NntpError::Protocol { code, .. } => {
            *code >= 400 && *code < 500 && *code != 430 && *code != 480
        }
        _ => false,
    }
}

/// Idle-pool connection wrapper. Dropping without `release` (on error/timeout)
/// discards the connection, which is safer than reusing a desynchronised one.
struct ConnectionGuard<'a> {
    provider: &'a Provider,
    conn: Option<Connection>,
}

impl<'a> ConnectionGuard<'a> {
    fn release(&mut self) {
        if let Some(conn) = self.conn.take() {
            let idle = self.provider.idle.clone();
            let notify = self.provider.notify.clone();
            tokio::spawn(async move {
                idle.lock().await.push(conn);
                notify.notify_one();
            });
        }
    }
}

impl Drop for ConnectionGuard<'_> {
    fn drop(&mut self) {
        // A connection discarded on error is closed and its slot is freed.
        if self.conn.is_some() {
            self.provider.open.fetch_sub(1, Ordering::AcqRel);
            self.provider.notify.notify_one();
        }
    }
}

type BoxStream = Box<dyn AsyncReadWrite + Send + Unpin>;

trait AsyncReadWrite: AsyncRead + AsyncWrite {}
impl<T: AsyncRead + AsyncWrite> AsyncReadWrite for T {}

struct Connection {
    reader: BufReader<tokio::io::ReadHalf<BoxStream>>,
    writer: tokio::io::WriteHalf<BoxStream>,
    timeout: Duration,
}

impl Connection {
    async fn connect(cfg: &NntpConfig) -> Result<Self> {
        // The dependency graph enables both aws-lc-rs and ring (sqlx/reqwest), so
        // rustls cannot auto-select a provider. Pick one explicitly before any
        // TLS handshake.
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        let addr = format!("{}:{}", cfg.host, cfg.port);
        let stream = tokio::time::timeout(
            Duration::from_secs(cfg.connect_timeout_secs.max(1)),
            TcpStream::connect(&addr),
        )
        .await
        .map_err(|_| NntpError::Timeout)??;
        stream.set_nodelay(true)?;

        let stream: BoxStream = if cfg.tls {
            let mut roots = RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let tls = ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            let connector = TlsConnector::from(Arc::new(tls));
            let server_name = cfg
                .host
                .clone()
                .try_into()
                .map_err(|_| NntpError::Config("invalid TLS server name".into()))?;
            let s = tokio::time::timeout(
                Duration::from_secs(cfg.connect_timeout_secs.max(1)),
                connector.connect(server_name, stream),
            )
            .await
            .map_err(|_| NntpError::Timeout)
            .map_err(|e| NntpError::Tls(e.to_string()))??;
            Box::new(s)
        } else {
            Box::new(stream)
        };

        let (r, w) = tokio::io::split(stream);
        let mut conn = Self {
            reader: BufReader::new(r),
            writer: w,
            timeout: Duration::from_secs(cfg.io_timeout_secs.max(1)),
        };

        let (code, msg) = conn.read_reply().await?;
        if code != 200 && code != 201 {
            return Err(NntpError::Protocol {
                code,
                message: msg.join(" "),
            });
        }

        if let (Some(user), Some(pass)) = (&cfg.username, &cfg.password) {
            let (code, _) = conn.command_line(&format!("AUTHINFO USER {user}")).await?;
            if code == 381 {
                let (code, msg) = conn.command_line(&format!("AUTHINFO PASS {pass}")).await?;
                if code != 281 {
                    return Err(NntpError::Auth);
                }
                tracing::debug!(provider = %cfg.name, "authenticated: {}", msg.join(" "));
            } else if code != 281 {
                return Err(NntpError::Auth);
            }
        }
        // Switch the connection to reader mode where required.
        let (code, _) = conn.command_line("MODE READER").await?;
        if code != 200 && code != 201 {
            tracing::debug!(code, "MODE READER not supported");
        }
        Ok(conn)
    }

    async fn write_all(&mut self, bytes: &[u8]) -> Result<()> {
        tokio::time::timeout(self.timeout, self.writer.write_all(bytes))
            .await
            .map_err(|_| NntpError::Timeout)??;
        tokio::time::timeout(self.timeout, self.writer.flush())
            .await
            .map_err(|_| NntpError::Timeout)??;
        Ok(())
    }

    async fn write_line(&mut self, line: &str) -> Result<()> {
        let mut buf = Vec::with_capacity(line.len() + 2);
        buf.extend_from_slice(line.as_bytes());
        buf.extend_from_slice(b"\r\n");
        self.write_all(&buf).await
    }

    async fn command_line(&mut self, line: &str) -> Result<(u16, Vec<String>)> {
        self.write_line(line).await?;
        self.read_reply().await
    }

    async fn read_line(&mut self) -> Result<String> {
        let raw = self.read_line_bytes().await?;
        Ok(String::from_utf8_lossy(&raw).into_owned())
    }

    async fn read_line_bytes(&mut self) -> Result<Vec<u8>> {
        let mut buf = Vec::with_capacity(256);
        let mut byte = [0u8; 1];
        loop {
            let n = tokio::time::timeout(self.timeout, self.reader.read(&mut byte))
                .await
                .map_err(|_| NntpError::Timeout)??;
            if n == 0 {
                return Err(NntpError::Io(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "connection closed",
                )));
            }
            if byte[0] == b'\n' {
                break;
            }
            if byte[0] != b'\r' {
                buf.push(byte[0]);
            }
            if buf.len() > 1 << 20 {
                return Err(NntpError::Protocol {
                    code: 0,
                    message: "response line too long".into(),
                });
            }
        }
        Ok(buf)
    }

    async fn read_reply(&mut self) -> Result<(u16, Vec<String>)> {
        let first = self.read_line().await?;
        let code: u16 =
            first
                .get(..3)
                .and_then(|s| s.parse().ok())
                .ok_or_else(|| NntpError::Protocol {
                    code: 0,
                    message: format!("malformed response: {first}"),
                })?;
        let mut lines = vec![first.get(4..).unwrap_or("").to_string()];
        if first.as_bytes().get(3) == Some(&b'-') {
            loop {
                let line = self.read_line().await?;
                if line == "." {
                    break;
                }
                lines.push(line);
            }
        }
        Ok((code, lines))
    }

    /// Reads a dot-terminated multi-line block (the response code line has
    /// already been consumed by `command_line`).
    async fn read_multiline(&mut self) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        loop {
            let line = self.read_line_bytes().await?;
            if line == b"." {
                break;
            }
            out.extend_from_slice(&line);
            out.extend_from_slice(b"\r\n");
            if out.len() > 64 << 20 {
                return Err(NntpError::Protocol {
                    code: 0,
                    message: "article exceeds 64 MiB limit".into(),
                });
            }
        }
        Ok(dot_unstuff(&out))
    }
}

/// A pool across all configured providers.
pub struct NntpPool {
    providers: Vec<Arc<Provider>>,
}

impl NntpPool {
    pub fn new(configs: Vec<NntpConfig>) -> Result<Self> {
        let mut providers: Vec<Arc<Provider>> = configs
            .iter()
            .map(|c| Provider::new(c.clone()))
            .collect::<Result<_>>()?;
        providers.sort_by_key(|p| p.config.priority);
        Ok(Self { providers })
    }

    pub fn providers(&self) -> &[Arc<Provider>] {
        &self.providers
    }

    pub fn provider(&self, name: &str) -> Option<&Arc<Provider>> {
        self.providers.iter().find(|p| p.name() == name)
    }

    /// Posts to the highest-priority posting provider, falling back on failure.
    /// Returns the provider that accepted the article.
    pub async fn post(&self, article: &Article) -> Result<String> {
        let mut errors = Vec::new();
        for p in self.providers.iter().filter(|p| p.config.can_post()) {
            match p.post(article).await {
                Ok(()) => return Ok(p.name().to_string()),
                Err(e) => {
                    tracing::warn!(provider = %p.name(), error = %e, "posting provider failed, trying next");
                    errors.push(format!("{}: {e}", p.name()));
                }
            }
        }
        Err(NntpError::AllProvidersFailed(if errors.is_empty() {
            "no posting provider configured".into()
        } else {
            errors.join("; ")
        }))
    }

    /// Message-ID domain used for newly posted articles.
    pub fn message_id_domain(&self) -> String {
        self.providers
            .iter()
            .find(|p| p.config.can_post())
            .map(|p| p.config.message_id_domain.clone())
            .unwrap_or_else(|| "nntdrive.local".into())
    }

    /// Groups used for newly posted articles.
    pub fn posting_groups(&self) -> Vec<String> {
        self.providers
            .iter()
            .find(|p| p.config.can_post())
            .map(|p| p.config.groups.clone())
            .unwrap_or_default()
    }

    /// STATs an article across providers. Returns the providers that have it.
    pub async fn available_on(&self, message_id: &str) -> Vec<String> {
        let mut found = Vec::new();
        for p in self.providers.iter().filter(|p| p.config.can_fetch()) {
            match p.stat(message_id).await {
                Ok(Some(_)) => found.push(p.name().to_string()),
                Ok(None) => {}
                Err(e) => tracing::debug!(provider = %p.name(), error = %e, "STAT failed"),
            }
        }
        found
    }

    pub async fn stat(&self, message_id: &str) -> Result<Option<u64>> {
        let mut last = None;
        for p in self.providers.iter().filter(|p| p.config.can_fetch()) {
            match p.stat(message_id).await {
                Ok(Some(size)) => return Ok(Some(size)),
                Ok(None) => {}
                Err(e) => last = Some(e),
            }
        }
        match last {
            Some(e) => Err(e),
            None => Ok(None),
        }
    }

    /// Fetches from any provider that has the article, preferring configured
    /// priority order.
    pub async fn fetch(&self, message_id: &str) -> Result<Vec<u8>> {
        let mut last = None;
        for p in self.providers.iter().filter(|p| p.config.can_fetch()) {
            match p.fetch(message_id).await {
                Ok(data) => return Ok(data),
                Err(NntpError::NotFound) => continue,
                Err(e) => last = Some(e),
            }
        }
        Err(last.unwrap_or(NntpError::NotFound))
    }

    pub fn stats(&self) -> Vec<(String, ProviderStatsSnapshot)> {
        self.providers
            .iter()
            .map(|p| (p.name().to_string(), p.stats.snapshot()))
            .collect()
    }
}
