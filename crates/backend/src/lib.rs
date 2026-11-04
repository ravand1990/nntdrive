//! NNTDrive backend library: router, auth, API, jobs.
#![recursion_limit = "512"]

pub mod admin;
pub mod api;
pub mod auth;
pub mod error;
pub mod jobs;
pub mod state;

use axum::routing::{delete, get, patch, post};
use axum::Router;
use nntdrive_nntp::{NntpConfig, NntpPool, ProviderRole};
use sqlx::PgPool;
use std::sync::Arc;
use tower_http::trace::TraceLayer;

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
        .route("/files", get(api::list_files).post(api::create_file))
        .route("/files/{id}", patch(api::patch_file))
        .route("/files/{id}/move", post(api::move_file))
        .route(
            "/files/{id}/versions",
            get(api::list_versions).post(api::commit_version),
        )
        .route("/files/{id}/manifest", get(api::get_manifest))
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
        .route("/admin/providers/{id}", delete(admin::delete_provider))
        .route("/admin/providers/{id}/test", post(admin::test_provider))
        .route(
            "/admin/jobs",
            get(admin::list_jobs).post(admin::enqueue_job),
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

/// Builds the provider pool from the database (preferred) or the environment.
/// The admin API persists providers for the next restart.
pub async fn load_providers(pool: &PgPool, secret_key: &[u8; 32]) -> anyhow::Result<NntpPool> {
    let rows = sqlx::query(
        "SELECT name, host, port, tls, username, password_enc, max_connections, role, priority,
                groups, retention_days, enabled FROM providers WHERE enabled = TRUE ORDER BY priority",
    )
    .fetch_all(pool)
    .await?;

    let mut configs = Vec::new();
    for row in rows {
        use sqlx::Row;
        let password_enc: Option<Vec<u8>> = row.get("password_enc");
        let password = password_enc
            .as_deref()
            .and_then(|b| state::decrypt_secret(secret_key, b))
            .and_then(|b| String::from_utf8(b).ok());
        let role = match row.get::<String, _>("role").as_str() {
            "posting_only" => ProviderRole::PostingOnly,
            "retrieval_only" => ProviderRole::RetrievalOnly,
            _ => ProviderRole::Both,
        };
        configs.push(NntpConfig {
            name: row.get("name"),
            host: row.get("host"),
            port: row.get::<i32, _>("port") as u16,
            tls: row.get("tls"),
            username: row.get("username"),
            password,
            max_connections: row.get::<i32, _>("max_connections") as usize,
            role,
            priority: row.get::<i32, _>("priority") as u8,
            groups: row.get("groups"),
            message_id_domain: "nntdrive.local".into(),
            connect_timeout_secs: 30,
            io_timeout_secs: 60,
            retention_days: row
                .get::<Option<i32>, _>("retention_days")
                .map(|d| d as u32),
            max_retries: 3,
        });
    }

    if configs.is_empty() {
        if let Ok(json) = std::env::var("NNTDRIVE_NNTP_PROVIDERS") {
            configs = nntdrive_nntp::parse_providers(&json)?;
        }
    }
    if configs.is_empty() {
        tracing::warn!("no NNTP providers configured; uploads will fail until one is added");
    }
    Ok(NntpPool::new(configs)?)
}

pub fn run_worker(state: Arc<state::AppState>) {
    let worker = format!("worker-{}", uuid::Uuid::new_v4());
    tokio::spawn(jobs::worker_loop(state, worker));
}
