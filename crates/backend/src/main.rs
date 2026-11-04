use anyhow::Context as _;
use nntdrive_backend::{
    app, load_providers, run_worker, state::AppState, state::ServerConfig, MIGRATOR,
};
use sqlx::postgres::PgPoolOptions;
use std::net::SocketAddr;
use std::sync::Arc;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let json_logs = std::env::var("LOG_FORMAT")
        .map(|v| v.eq_ignore_ascii_case("json"))
        .unwrap_or(false);
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "info,sqlx=warn".into());
    if json_logs {
        tracing_subscriber::fmt()
            .json()
            .with_env_filter(filter)
            .init();
    } else {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    }

    let database_url = std::env::var("DATABASE_URL").context("DATABASE_URL is required")?;
    let config = ServerConfig::from_env()?;
    let bind: SocketAddr = config.bind.parse().context("invalid NNTDRIVE_BIND")?;

    let pool = PgPoolOptions::new()
        .max_connections(
            std::env::var("DATABASE_MAX_CONNECTIONS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(20),
        )
        .connect(&database_url)
        .await
        .context("cannot connect to PostgreSQL")?;
    MIGRATOR
        .run(&pool)
        .await
        .context("database migration failed")?;

    let nntp = load_providers(&pool, &config.secret_key).await?;
    let state = Arc::new(AppState::new(pool, Arc::new(nntp), config)?);

    run_worker(state.clone());
    let scheduler_state = state.clone();
    tokio::spawn(nntdrive_backend::jobs::scheduler_loop(scheduler_state));

    let router = app((*state).clone());
    let listener = tokio::net::TcpListener::bind(bind).await?;
    tracing::info!(%bind, "NNTDrive backend listening");
    let restart = state.restart.clone();
    let shutdown = async move {
        tokio::select! {
            _ = shutdown_signal() => {},
            _ = restart.notified() => {
                tracing::warn!("restart requested via admin API; stopping");
            }
        }
    };
    axum::serve(
        listener,
        router.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown)
    .await?;
    // Returning normally lets Docker (`restart: unless-stopped`) or systemd
    // (`Restart=always`) start the process again with the new provider config.
    tracing::info!("backend stopped");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c().await.ok();
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut s) => {
                s.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    tracing::info!("shutdown signal received; finishing in-flight requests");
}
