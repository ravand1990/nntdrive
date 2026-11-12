//! NNTDrive backend library: router, auth, API, jobs.
#![recursion_limit = "512"]

pub mod admin;
pub mod api;
pub mod auth;
pub mod error;
pub mod jobs;
pub mod roots;
pub mod state;

use axum::routing::{delete, get, patch, post};
use axum::Router;
use nntdrive_nntp::{NntpConfig, NntpPool, ProviderRole};
use sqlx::PgPool;
use std::sync::Arc;
use tower_http::trace::TraceLayer;

mod copy;
mod copy_tree;
pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");

pub fn app(state: state::AppState) -> Router {
    let api = Router::new()
        .route("/auth/register", post(auth::register))
        .route("/auth/login", post(auth::login))
        .route("/auth/lookup", get(auth::lookup_account))
        .route("/setup/status", get(auth::setup_status))
        .route("/tokens", post(auth::create_token))
        .route("/auth/logout", post(auth::logout))
        .route("/me", get(auth::me))
        .route("/devices", get(auth::list_devices))
        .route("/devices/{id}", delete(auth::revoke_device))
        .route("/roots", get(roots::list_roots).post(roots::bootstrap_root))
        .route("/files", get(api::list_files).post(api::create_file))
        .route("/files/{id}", patch(api::patch_file))
        .route(
            "/files/{id}/copy-checked",
            post(copy::publish).layer(axum::extract::DefaultBodyLimit::max(2 * 1024 * 1024)),
        )
        .route(
            "/copy-tree-destination",
            get(copy_tree::destination_snapshot),
        )
        .route("/files/{id}/copy-tree-snapshot", get(copy_tree::snapshot))
        .route(
            "/files/{id}/copy-tree-checked",
            post(copy_tree::publish).layer(axum::extract::DefaultBodyLimit::max(12 * 1024 * 1024)),
        )
        .route("/files/{id}/move", post(api::move_file))
        .route(
            "/files/{id}/move-checked",
            post(api::move_file_checked)
                .layer(axum::extract::DefaultBodyLimit::max(2 * 1024 * 1024)),
        )
        .route(
            "/files/{id}/rename",
            post(api::rename_file).layer(axum::extract::DefaultBodyLimit::max(2 * 1024 * 1024)),
        )
        .route(
            "/files/{id}/versions",
            get(api::list_versions).post(api::commit_version),
        )
        .route(
            "/files/{id}/versions/{revision}/references",
            axum::routing::put(api::backfill_references),
        )
        .route("/files/{id}/manifest", get(api::get_manifest))
        .route("/reference-backfill", get(api::incomplete_references))
        .route("/chunks/lookup", get(api::lookup_chunk))
        .route("/chunks", post(api::publish_chunk))
        .route("/chunks/{id}", get(api::get_chunk))
        .route("/articles/{message_id}", get(api::get_article))
        .route("/events", get(api::list_events))
        .route("/events/stream", get(api::stream_events))
        .route("/admin/stats", get(admin::stats))
        .route("/admin/users", get(admin::users))
        .route("/admin/users/{id}", patch(admin::patch_user))
        .route(
            "/admin/providers",
            get(admin::list_providers).post(admin::create_provider),
        )
        .route(
            "/admin/providers/{id}",
            patch(admin::patch_provider).delete(admin::delete_provider),
        )
        .route("/admin/providers/{id}/test", post(admin::test_provider))
        .route("/admin/articles/verify", get(admin::verify_recent_articles))
        .route(
            "/admin/jobs",
            get(admin::list_jobs).post(admin::enqueue_job),
        )
        .route(
            "/admin/retention",
            get(admin::get_retention).put(admin::set_retention),
        )
        .route("/admin/restart", post(admin::restart_backend));

    Router::new()
        .route(
            "/",
            get(|| async { axum::response::Redirect::temporary("/admin") }),
        )
        .route("/healthz", get(api::health))
        .route(
            "/admin",
            get(|| async { axum::response::Html(include_str!("../static/admin.html")) }),
        )
        .nest("/api/v1", api)
        .layer(axum::extract::DefaultBodyLimit::max(160 * 1024 * 1024))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// DB-managed installations never fall back to environment providers.
pub async fn load_providers(pool: &PgPool, secret_key: &[u8; 32]) -> anyhow::Result<NntpPool> {
    let mut tx = pool.begin().await?;
    let managed: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM provider_management) OR EXISTS(SELECT 1 FROM providers)",
    )
    .fetch_one(&mut *tx)
    .await?;
    let db = load_db_providers(&mut tx, secret_key).await?;
    if !managed {
        if let Ok(json) = std::env::var("NNTDRIVE_NNTP_PROVIDERS") {
            return Ok(NntpPool::new(nntdrive_nntp::parse_providers(&json)?)?);
        }
    }
    Ok(db)
}

pub(crate) async fn load_db_providers(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    secret_key: &[u8; 32],
) -> anyhow::Result<NntpPool> {
    let rows = sqlx::query("SELECT * FROM providers ORDER BY priority, id")
        .fetch_all(&mut **tx)
        .await?;
    let mut configs = Vec::new();
    for row in rows {
        let config = provider_config(&row, secret_key)?;
        if sqlx::Row::try_get::<bool, _>(&row, "enabled")? {
            configs.push(config);
        }
    }
    Ok(NntpPool::new(configs)?)
}

pub(crate) fn provider_config(
    row: &sqlx::postgres::PgRow,
    key: &[u8; 32],
) -> anyhow::Result<NntpConfig> {
    use sqlx::Row;
    let blob: Option<Vec<u8>> = row.try_get("password_enc")?;
    let password = match blob {
        None => None,
        Some(blob) => Some(
            String::from_utf8(
                state::decrypt_secret(key, &blob)
                    .ok_or_else(|| anyhow::anyhow!("invalid provider credentials"))?,
            )
            .map_err(|_| anyhow::anyhow!("invalid provider credentials"))?,
        ),
    };
    let role = match row.try_get::<String, _>("role")?.as_str() {
        "both" => ProviderRole::Both,
        "posting_only" => ProviderRole::PostingOnly,
        "retrieval_only" => ProviderRole::RetrievalOnly,
        _ => anyhow::bail!("invalid provider role"),
    };
    let config = NntpConfig {
        name: row.try_get("name")?,
        host: row.try_get("host")?,
        port: row.try_get::<i32, _>("port")?.try_into()?,
        tls: row.try_get("tls")?,
        username: row.try_get("username")?,
        password,
        max_connections: row.try_get::<i32, _>("max_connections")?.try_into()?,
        role,
        priority: row.try_get::<i32, _>("priority")?.try_into()?,
        groups: row.try_get("groups")?,
        message_id_domain: "nntdrive.local".into(),
        connect_timeout_secs: 30,
        io_timeout_secs: 60,
        retention_days: row
            .try_get::<Option<i32>, _>("retention_days")?
            .map(u32::try_from)
            .transpose()?,
        max_retries: 3,
    };
    config.validate()?;
    Ok(config)
}

pub fn run_worker(state: Arc<state::AppState>) {
    let worker = format!("worker-{}", uuid::Uuid::new_v4());
    tokio::spawn(jobs::worker_loop(state, worker));
}
