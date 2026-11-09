//! Server configuration, shared state and the encrypted chunk cache.

use crate::error::{sha256, ApiError};
use axum::http::StatusCode;
use nntdrive_nntp::NntpPool;
use nntdrive_storage::{Storage, StorageConfig, Store};
use sqlx::PgPool;
use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

#[derive(Clone)]
pub struct ServerConfig {
    pub bind: String,
    pub cache_dir: PathBuf,
    pub cache_limit_bytes: u64,
    pub allow_registration: bool,
    pub secret_key: [u8; 32],
    pub default_quota_bytes: Option<i64>,
    pub health_check_interval_secs: u64,
    pub retention_refresh_days: u32,
    pub retention_interval_secs: u64,
}

impl ServerConfig {
    pub fn from_env() -> anyhow::Result<Self> {
        let bind = std::env::var("NNTDRIVE_BIND").unwrap_or_else(|_| "0.0.0.0:8080".into());
        let cache_dir = std::env::var("NNTDRIVE_CACHE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("./cache"));
        let cache_limit_bytes = std::env::var("NNTDRIVE_CACHE_LIMIT_BYTES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(10 * 1024 * 1024 * 1024u64);
        let allow_registration = std::env::var("NNTDRIVE_ALLOW_REGISTRATION")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        let secret_key = match std::env::var("NNTDRIVE_SECRET_KEY") {
            Ok(v) => {
                use base64::Engine;
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(v.trim())
                    .map_err(|_| anyhow::anyhow!("NNTDRIVE_SECRET_KEY must be base64"))?;
                let arr: [u8; 32] = bytes
                    .try_into()
                    .map_err(|_| anyhow::anyhow!("NNTDRIVE_SECRET_KEY must be 32 bytes"))?;
                arr
            }
            Err(_) => {
                use rand::RngCore;
                let mut k = [0u8; 32];
                rand::rngs::OsRng.fill_bytes(&mut k);
                tracing::warn!(
                    "NNTDRIVE_SECRET_KEY is not set; provider credentials written by the admin API \
                     will not survive a restart. Set a base64 32-byte key in production."
                );
                k
            }
        };
        let default_quota_bytes = std::env::var("NNTDRIVE_DEFAULT_QUOTA_BYTES")
            .ok()
            .and_then(|v| v.parse().ok());
        Ok(Self {
            bind,
            cache_dir,
            cache_limit_bytes,
            allow_registration,
            secret_key,
            default_quota_bytes,
            health_check_interval_secs: std::env::var("NNTDRIVE_HEALTH_INTERVAL_SECS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(6 * 60 * 60),
            retention_refresh_days: std::env::var("NNTDRIVE_REFRESH_DAYS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(180),
            retention_interval_secs: std::env::var("NNTDRIVE_REFRESH_INTERVAL_SECS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(24 * 60 * 60),
        })
    }
}

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub store: Store,
    pub storage: Arc<Storage>,
    pub config: Arc<ServerConfig>,
    pub cache: Arc<ArticleCache>,
    pub limiter: Arc<RateLimiter>,
    /// Notified by the admin restart endpoint; the server then shuts down
    /// gracefully and the container manager (Compose/systemd) starts it again.
    pub restart: Arc<tokio::sync::Notify>,
    pub provider_mutations: Arc<Mutex<()>>,
}

impl AppState {
    pub fn new(pool: PgPool, nntp: Arc<NntpPool>, config: ServerConfig) -> anyhow::Result<Self> {
        let store = Store::new(pool.clone());
        let storage = Storage::new(store.clone(), nntp, storage_config_from_env())?;
        let cache = Arc::new(ArticleCache::new(
            config.cache_dir.clone(),
            config.cache_limit_bytes,
        ));
        Ok(Self {
            pool,
            store,
            storage: Arc::new(storage),
            limiter: Arc::new(RateLimiter::new(20, Duration::from_secs(60))),
            config: Arc::new(config),
            cache,
            restart: Arc::new(tokio::sync::Notify::new()),
            provider_mutations: Arc::new(Mutex::new(())),
        })
    }

    /// Enforces the account's logical quota before accepting new ciphertext.
    pub async fn check_quota(
        &self,
        account_id: uuid::Uuid,
        additional: u64,
    ) -> Result<(), ApiError> {
        let row = sqlx::query_as::<_, (Option<i64>, Option<i64>)>(
            "SELECT a.quota_bytes,
                    (SELECT COALESCE(SUM(plaintext_len),0)::bigint FROM chunks c WHERE c.account_id = a.id)
             FROM accounts a WHERE a.id = $1",
        )
        .bind(account_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or(ApiError::Unauthorized)?;
        if let Some(limit) = row.0 {
            if row.1.unwrap_or(0) + additional as i64 > limit {
                return Err(ApiError::QuotaExceeded);
            }
        }
        Ok(())
    }
}

fn storage_config_from_env() -> StorageConfig {
    let mut cfg = StorageConfig::default();
    if let Ok(json) = std::env::var("NNTDRIVE_STORAGE_CONFIG") {
        match serde_json::from_str::<StorageConfig>(&json) {
            Ok(parsed) => cfg = parsed,
            Err(e) => tracing::warn!(error = %e, "invalid NNTDRIVE_STORAGE_CONFIG, using defaults"),
        }
    }
    cfg
}

/// Simple per-IP limiter for authentication endpoints. A reverse proxy with a
/// stricter limiter is recommended in front of it.
pub struct RateLimiter {
    inner: Mutex<HashMap<IpAddr, VecDeque<Instant>>>,
    max: usize,
    window: Duration,
}

impl RateLimiter {
    pub fn new(max: usize, window: Duration) -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            max,
            window,
        }
    }

    pub async fn allow(&self, ip: IpAddr) -> bool {
        let mut map = self.inner.lock().await;
        if map.len() > 10_000 {
            map.clear();
        }
        let now = Instant::now();
        let q = map.entry(ip).or_default();
        while q
            .front()
            .map(|t| now.duration_since(*t) > self.window)
            .unwrap_or(false)
        {
            q.pop_front();
        }
        if q.len() >= self.max {
            return false;
        }
        q.push_back(now);
        true
    }
}

/// Encrypted shard cache. Articles are immutable, so cache entries cannot go
/// stale; the cache is optional and never the only copy of committed data.
pub struct ArticleCache {
    dir: PathBuf,
    limit: AtomicU64,
    used: AtomicU64,
}

impl ArticleCache {
    pub fn new(dir: PathBuf, limit: u64) -> Self {
        let _ = std::fs::create_dir_all(&dir);
        let used = walk_size(&dir);
        Self {
            dir,
            limit: AtomicU64::new(limit),
            used: AtomicU64::new(used),
        }
    }

    fn path_for(&self, message_id: &str) -> PathBuf {
        self.dir
            .join(format!("{}.article", hex(&sha256(message_id.as_bytes()))))
    }

    pub async fn get(&self, message_id: &str) -> Option<Vec<u8>> {
        let path = self.path_for(message_id);
        tokio::fs::read(&path).await.ok()
    }

    pub async fn put(&self, message_id: &str, data: &[u8]) -> std::io::Result<()> {
        let path = self.path_for(message_id);
        let tmp = path.with_extension("tmp");
        tokio::fs::write(&tmp, data).await?;
        tokio::fs::rename(&tmp, &path).await?;
        let total = self.used.fetch_add(data.len() as u64, Ordering::Relaxed) + data.len() as u64;
        if total > self.limit.load(Ordering::Relaxed) {
            self.evict().await;
        }
        Ok(())
    }

    pub fn used_bytes(&self) -> u64 {
        self.used.load(Ordering::Relaxed)
    }

    pub fn limit_bytes(&self) -> u64 {
        self.limit.load(Ordering::Relaxed)
    }

    async fn evict(&self) {
        let dir = self.dir.clone();
        let entries = tokio::task::spawn_blocking(move || {
            let mut v = Vec::new();
            if let Ok(read) = std::fs::read_dir(&dir) {
                for e in read.flatten() {
                    if let Ok(meta) = e.metadata() {
                        let modified = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
                        v.push((modified, meta.len(), e.path()));
                    }
                }
            }
            v.sort();
            v
        })
        .await
        .unwrap_or_default();
        let mut used = self.used.load(Ordering::Relaxed);
        let limit = self.limit.load(Ordering::Relaxed);
        for (_mtime, len, path) in entries {
            if used <= limit {
                break;
            }
            if tokio::fs::remove_file(&path).await.is_ok() {
                used = used.saturating_sub(len);
                self.used.store(used, Ordering::Relaxed);
            }
        }
    }
}

fn walk_size(dir: &std::path::Path) -> u64 {
    let mut total = 0;
    if let Ok(read) = std::fs::read_dir(dir) {
        for e in read.flatten() {
            if let Ok(meta) = e.metadata() {
                if meta.is_file() {
                    total += meta.len();
                }
            }
        }
    }
    total
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Provider passwords are encrypted at rest with the server's secret key. This
/// protects against database-only disclosure; it does not protect against a
/// fully compromised backend host, which is outside the E2EE guarantee.
pub fn encrypt_secret(key: &[u8; 32], plaintext: &[u8]) -> Vec<u8> {
    use chacha20poly1305::aead::{Aead, KeyInit};
    use chacha20poly1305::{XChaCha20Poly1305, XNonce};
    use rand::RngCore;
    let cipher = XChaCha20Poly1305::new(key.into());
    let mut nonce = [0u8; 24];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let ct = cipher
        .encrypt(XNonce::from_slice(&nonce), plaintext)
        .expect("encryption cannot fail");
    let mut out = nonce.to_vec();
    out.extend_from_slice(&ct);
    out
}

pub fn decrypt_secret(key: &[u8; 32], blob: &[u8]) -> Option<Vec<u8>> {
    use chacha20poly1305::aead::{Aead, KeyInit};
    use chacha20poly1305::{XChaCha20Poly1305, XNonce};
    if blob.len() < 24 {
        return None;
    }
    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(XNonce::from_slice(&blob[..24]), &blob[24..])
        .ok()
}

pub fn json_ok(message: &str) -> axum::response::Response {
    use axum::response::IntoResponse;
    (
        StatusCode::OK,
        axum::Json(serde_json::json!({ "status": "ok", "message": message })),
    )
        .into_response()
}
