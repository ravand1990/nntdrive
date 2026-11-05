//! Disposable real HTTP + mock NNTP fixture for the Dart FFI smoke test.
//! Run in the Flutter check container with TEST_DATABASE_URL and
//! NNTDRIVE_FFI_PATH set; no deployment services or real providers are used.
use nntdrive_backend::state::{AppState, ServerConfig};
use nntdrive_nntp::{MockConfig, MockNntpServer, NntpPool};
use nntdrive_storage::TestDb;
use std::sync::Arc;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let db = TestDb::create()
        .await
        .ok_or_else(|| anyhow::anyhow!("test PostgreSQL is required"))?;
    let nntp = MockNntpServer::start(MockConfig::default()).await;
    let cache = tempfile::tempdir()?;
    let config = ServerConfig {
        bind: "127.0.0.1:0".into(),
        cache_dir: cache.path().into(),
        cache_limit_bytes: 32 * 1024 * 1024,
        allow_registration: true,
        secret_key: [5; 32],
        default_quota_bytes: None,
        health_check_interval_secs: 3600,
        retention_refresh_days: 30,
        retention_interval_secs: 3600,
    };
    let state = AppState::new(
        db.store.pool().clone(),
        Arc::new(NntpPool::new(vec![nntp.client_config()])?),
        config,
    )?;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            nntdrive_backend::app(state)
                .into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )
        .await
    });
    let work = tempfile::tempdir()?;
    let path = work.path().to_path_buf();
    let status = tokio::task::spawn_blocking(move || {
        std::process::Command::new("dart")
            .args([
                "run",
                "tool/sync_smoke.dart",
                &format!("http://{addr}"),
                &path.to_string_lossy(),
            ])
            .current_dir("clients/flutter")
            .status()
    })
    .await??;
    server.abort();
    anyhow::ensure!(status.success(), "Dart FFI smoke failed: {status}");
    Ok(())
}
