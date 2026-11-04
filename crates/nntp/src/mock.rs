//! In-process NNTP test server.
//!
//! Supports posting, retrieval, authentication, Message-ID addressing and
//! deliberate faults: article deletion, payload corruption, retention expiry,
//! provider outage and posting rejection. Tests never touch a real provider.

use crate::article::{dot_stuff, dot_unstuff, ParsedArticle};
use crate::client::NntpConfig;
use std::collections::{BTreeMap, HashSet};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::Mutex;

#[derive(Debug, Clone)]
pub struct MockConfig {
    pub require_auth: bool,
    pub username: String,
    pub password: String,
    pub posting_enabled: bool,
    pub groups: Vec<String>,
}

impl Default for MockConfig {
    fn default() -> Self {
        Self {
            require_auth: true,
            username: "testuser".into(),
            password: "testpass".into(),
            posting_enabled: true,
            groups: vec!["alt.binaries.test".into()],
        }
    }
}

struct Stored {
    raw: Vec<u8>,
    size: u64,
    posted_at: std::time::Instant,
}

#[derive(Default)]
struct Inner {
    articles: BTreeMap<String, Stored>,
    deleted: HashSet<String>,
    corrupted: HashSet<String>,
    outage: bool,
    block_posting: bool,
    expire_before: Option<std::time::Instant>,
    connections: u64,
}

#[derive(Default)]
pub struct MockStore {
    inner: Mutex<Inner>,
    pub post_attempts: AtomicU64,
    active_connections: AtomicU64,
    max_active_connections: AtomicU64,
}

impl MockStore {
    pub async fn max_active_connections(&self) -> u64 {
        self.max_active_connections.load(Ordering::Relaxed)
    }
    pub async fn article_ids(&self) -> Vec<String> {
        self.inner.lock().await.articles.keys().cloned().collect()
    }

    pub async fn article_count(&self) -> usize {
        self.inner.lock().await.articles.len()
    }

    pub async fn post_attempts(&self) -> u64 {
        self.post_attempts.load(Ordering::Relaxed)
    }

    pub async fn raw_article(&self, id: &str) -> Option<Vec<u8>> {
        self.inner
            .lock()
            .await
            .articles
            .get(id)
            .map(|a| a.raw.clone())
    }

    /// Inserts an already-formatted article. Used by tests that simulate an
    /// article being available on a second provider.
    pub async fn insert_raw(&self, raw: Vec<u8>) {
        let parsed = ParsedArticle::parse(&raw);
        if let Some(id) = parsed.message_id {
            let size = raw.len() as u64;
            self.inner.lock().await.articles.insert(
                id.clone(),
                Stored {
                    raw,
                    size,
                    posted_at: std::time::Instant::now(),
                },
            );
        }
    }

    /// Deletes a deterministic fraction of articles (0..=100).
    pub async fn delete_fraction(&self, percent: u8) {
        let ids: Vec<String> = {
            let inner = self.inner.lock().await;
            inner.articles.keys().cloned().collect()
        };
        let mut hasher = 0x9E37_79B9u64;
        let mut inner = self.inner.lock().await;
        for id in ids {
            hasher = hasher
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            if (hasher >> 33) % 100 < percent as u64 {
                inner.deleted.insert(id);
            }
        }
    }

    pub async fn delete_message(&self, id: &str) {
        self.inner.lock().await.deleted.insert(id.to_string());
    }

    pub async fn delete_all(&self) {
        let mut inner = self.inner.lock().await;
        let ids: Vec<String> = inner.articles.keys().cloned().collect();
        for id in ids {
            inner.deleted.insert(id);
        }
    }

    /// Simulates bit-rot: the article is still present but fails integrity.
    pub async fn corrupt_message(&self, id: &str) {
        self.inner.lock().await.corrupted.insert(id.to_string());
    }

    pub async fn corrupt_fraction(&self, percent: u8) {
        let ids: Vec<String> = {
            let inner = self.inner.lock().await;
            inner.articles.keys().cloned().collect()
        };
        let mut hasher = 0x1234_5678u64;
        let mut inner = self.inner.lock().await;
        for id in ids {
            hasher = hasher
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            if (hasher >> 33) % 100 < percent as u64 {
                inner.corrupted.insert(id);
            }
        }
    }

    pub async fn set_outage(&self, outage: bool) {
        self.inner.lock().await.outage = outage;
    }

    pub async fn set_posting_blocked(&self, blocked: bool) {
        self.inner.lock().await.block_posting = blocked;
    }

    /// Marks articles older than `age` as gone (retention expiry).
    pub async fn expire_older_than(&self, age: Duration) {
        let cutoff = std::time::Instant::now() - age;
        self.inner.lock().await.expire_before = Some(cutoff);
    }

    pub async fn connection_count(&self) -> u64 {
        self.inner.lock().await.connections
    }
}

pub struct MockNntpServer {
    pub addr: SocketAddr,
    pub store: Arc<MockStore>,
    shutdown: tokio::sync::watch::Sender<bool>,
    handle: tokio::task::JoinHandle<()>,
}

impl MockNntpServer {
    pub async fn start(config: MockConfig) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let store = Arc::new(MockStore::default());
        let (tx, mut rx) = tokio::sync::watch::channel(false);
        let store2 = store.clone();
        let config = Arc::new(config);
        let handle = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = rx.changed() => break,
                    accepted = listener.accept() => {
                        let Ok((stream, _)) = accepted else { continue };
                        let store = store2.clone();
                        let config = config.clone();
                        tokio::spawn(async move {
                            let _ = handle_connection(stream, store, config).await;
                        });
                    }
                }
            }
        });
        Self {
            addr,
            store,
            shutdown: tx,
            handle,
        }
    }

    /// Ready-to-use client config pointing at this server.
    pub fn client_config(&self) -> NntpConfig {
        NntpConfig {
            name: "mock".into(),
            host: "127.0.0.1".into(),
            port: self.addr.port(),
            tls: false,
            username: Some("testuser".into()),
            password: Some("testpass".into()),
            max_connections: 4,
            role: crate::client::ProviderRole::Both,
            priority: 0,
            groups: vec!["alt.binaries.test".into()],
            message_id_domain: "mock.local".into(),
            connect_timeout_secs: 5,
            io_timeout_secs: 5,
            retention_days: Some(30),
            max_retries: 1,
        }
    }
}

impl Drop for MockNntpServer {
    fn drop(&mut self) {
        let _ = self.shutdown.send(true);
        self.handle.abort();
    }
}

async fn handle_connection(
    stream: tokio::net::TcpStream,
    store: Arc<MockStore>,
    config: Arc<MockConfig>,
) -> std::io::Result<()> {
    {
        let mut inner = store.inner.lock().await;
        if inner.outage {
            return Ok(());
        }
        inner.connections += 1;
    }
    store.active_connections.fetch_add(1, Ordering::Relaxed);
    store.max_active_connections.fetch_max(
        store.active_connections.load(Ordering::Relaxed),
        Ordering::Relaxed,
    );
    struct ActiveGuard(Arc<MockStore>);
    impl Drop for ActiveGuard {
        fn drop(&mut self) {
            self.0.active_connections.fetch_sub(1, Ordering::Relaxed);
        }
    }
    let _active = ActiveGuard(store.clone());
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r);
    w.write_all(b"200 mock NNTP service ready (posting allowed)\r\n")
        .await?;

    let mut authed = !config.require_auth;
    let mut pending_user: Option<String> = None;
    let mut line = Vec::new();

    loop {
        if store.inner.lock().await.outage {
            return Ok(());
        }
        line.clear();
        let n = reader.read_until(b'\n', &mut line).await?;
        if n == 0 {
            return Ok(());
        }
        let cmd = String::from_utf8_lossy(&line).trim_end().to_string();
        if store.inner.lock().await.outage {
            return Ok(());
        }
        let (verb, arg) = match cmd.split_once(' ') {
            Some((v, a)) => (v.to_ascii_uppercase(), a.trim().to_string()),
            None => (cmd.to_ascii_uppercase(), String::new()),
        };

        match verb.as_str() {
            "CAPABILITIES" => {
                w.write_all(b"101 Capability list:\r\nVERSION 2\r\nREADER\r\nPOST\r\nAUTHINFO USER\r\n.\r\n").await?;
            }
            "MODE" => w.write_all(b"200 reader mode\r\n").await?,
            "AUTHINFO" => {
                let (sub, value) = match arg.split_once(' ') {
                    Some((s, v)) => (s.to_ascii_uppercase(), v.to_string()),
                    None => (arg.to_ascii_uppercase(), String::new()),
                };
                match sub.as_str() {
                    "USER" => {
                        pending_user = Some(value);
                        w.write_all(b"381 password required\r\n").await?;
                    }
                    "PASS" => {
                        let ok = pending_user.as_deref() == Some(config.username.as_str())
                            && value == config.password;
                        if ok {
                            authed = true;
                            w.write_all(b"281 authentication accepted\r\n").await?;
                        } else {
                            w.write_all(b"481 authentication failed\r\n").await?;
                        }
                    }
                    _ => w.write_all(b"501 unknown AUTHINFO command\r\n").await?,
                }
            }
            "QUIT" => {
                w.write_all(b"205 goodbye\r\n").await?;
                return Ok(());
            }
            "DATE" => w.write_all(b"111 20260101000000\r\n").await?,
            _ if !authed => {
                w.write_all(b"480 authentication required\r\n").await?;
            }
            "POST" => {
                store.post_attempts.fetch_add(1, Ordering::Relaxed);
                let blocked = { store.inner.lock().await.block_posting } || !config.posting_enabled;
                if blocked {
                    w.write_all(b"440 posting not allowed\r\n").await?;
                    continue;
                }
                w.write_all(b"340 send article to be posted\r\n").await?;
                let mut raw = Vec::new();
                loop {
                    let mut l = Vec::new();
                    let n = reader.read_until(b'\n', &mut l).await?;
                    if n == 0 {
                        return Ok(());
                    }
                    if l == b".\r\n" || l == b".\n" {
                        break;
                    }
                    let unstuffed = dot_unstuff(&l);
                    raw.extend_from_slice(&unstuffed);
                }
                let parsed = ParsedArticle::parse(&raw);
                let Some(message_id) = parsed.message_id.clone() else {
                    w.write_all(b"441 missing Message-ID\r\n").await?;
                    continue;
                };
                let size = raw.len() as u64;
                {
                    let mut inner = store.inner.lock().await;
                    inner.articles.insert(
                        message_id.clone(),
                        Stored {
                            raw,
                            size,
                            posted_at: std::time::Instant::now(),
                        },
                    );
                    inner.deleted.remove(&message_id);
                    inner.corrupted.remove(&message_id);
                }
                w.write_all(b"240 article received\r\n").await?;
            }
            "STAT" | "HEAD" | "BODY" => {
                let id = arg
                    .trim()
                    .trim_start_matches('<')
                    .trim_end_matches('>')
                    .to_string();
                let outcome = {
                    let inner = store.inner.lock().await;
                    let expired = inner
                        .expire_before
                        .map(|cutoff| {
                            inner
                                .articles
                                .get(&id)
                                .map(|a| a.posted_at < cutoff)
                                .unwrap_or(false)
                        })
                        .unwrap_or(false);
                    let present = inner.articles.contains_key(&id)
                        && !inner.deleted.contains(&id)
                        && !expired;
                    if !present {
                        None
                    } else {
                        let raw = inner.articles.get(&id).unwrap().raw.clone();
                        let size = inner.articles.get(&id).unwrap().size;
                        let mut raw = raw;
                        if inner.corrupted.contains(&id) {
                            // Flip a payload byte, keeping yEnc structure.
                            if let Some(pos) = raw.windows(6).position(|w| w == b"=yend ") {
                                if pos > 20 {
                                    raw[pos - 10] = raw[pos - 10].wrapping_add(1);
                                }
                            }
                        }
                        Some((raw, size))
                    }
                };
                match (verb.as_str(), outcome) {
                    (_, None) => w.write_all(b"430 no such article\r\n").await?,
                    ("STAT", Some((_, size))) => {
                        w.write_all(format!("223 0 <{id}> {size}\r\n").as_bytes())
                            .await?
                    }
                    ("HEAD", Some((raw, _))) => {
                        let head_end = raw
                            .windows(4)
                            .position(|w| w == b"\r\n\r\n")
                            .unwrap_or(raw.len());
                        w.write_all(format!("221 0 <{id}>\r\n").as_bytes()).await?;
                        w.write_all(&dot_stuff(&raw[..head_end])).await?;
                        w.write_all(b"\r\n.\r\n").await?;
                    }
                    ("BODY", Some((raw, _))) => {
                        let body_start = raw
                            .windows(4)
                            .position(|w| w == b"\r\n\r\n")
                            .map(|p| p + 4)
                            .unwrap_or(0);
                        w.write_all(format!("222 0 <{id}>\r\n").as_bytes()).await?;
                        w.write_all(&dot_stuff(&raw[body_start..])).await?;
                        if !raw[body_start..].ends_with(b"\r\n") {
                            w.write_all(b"\r\n").await?;
                        }
                        w.write_all(b".\r\n").await?;
                    }
                    _ => unreachable!(),
                }
            }
            "GROUP" => {
                w.write_all(b"211 0 0 0 alt.binaries.test\r\n").await?;
            }
            _ => {
                w.write_all(b"500 command not recognized\r\n").await?;
            }
        }
    }
}
