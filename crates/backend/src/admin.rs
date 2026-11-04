//! Administrative API: stats, users, providers, jobs.

use crate::auth::{seal_provider_password, AdminUser};
use crate::error::{ApiError, ApiResult};
use crate::jobs;
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use uuid::Uuid;

pub async fn stats(
    State(state): State<AppState>,
    _admin: AdminUser,
) -> ApiResult<impl IntoResponse> {
    let totals = state.store.platform_totals().await?;
    let recent_failures: Vec<(String, String, DateTime<Utc>)> = sqlx::query_as(
        "SELECT kind, COALESCE(last_error, ''), updated_at FROM jobs
         WHERE state = 'failed' ORDER BY updated_at DESC LIMIT 20",
    )
    .fetch_all(&state.pool)
    .await?;
    let storage_cfg = state.storage.config();
    Ok(Json(json!({
        "users": totals.accounts,
        "active_users": totals.active_accounts,
        "devices": totals.devices,
        "files": totals.files,
        "versions": totals.versions,
        "logical_bytes": totals.logical_bytes,
        "ciphertext_bytes": totals.ciphertext_bytes,
        "usenet_bytes": totals.usenet_bytes,
        "redundancy_overhead": 1.0 + storage_cfg.redundancy_percent as f64 / 100.0,
        "stripes": totals.stripes,
        "shards": totals.shards,
        "missing_shards": totals.missing_shards,
        "corrupt_shards": totals.corrupt_shards,
        "cache_bytes": state.cache.used_bytes(),
        "cache_limit_bytes": state.cache.limit_bytes(),
        "jobs_pending": totals.pending_jobs,
        "jobs_failed": totals.failed_jobs,
        "recent_failures": recent_failures.iter().map(|f| json!({
            "kind": f.0, "error": f.1, "at": f.2
        })).collect::<Vec<_>>(),
        "providers": state.storage.nntp().stats().iter().map(|(name, s)| json!({
            "name": name, "posts": s.posts, "post_failures": s.post_failures,
            "fetches": s.fetches, "fetch_failures": s.fetch_failures,
            "bytes_posted": s.bytes_posted, "bytes_fetched": s.bytes_fetched,
            "connections_opened": s.connections_opened
        })).collect::<Vec<_>>(),
    })))
}

pub async fn users(
    State(state): State<AppState>,
    _admin: AdminUser,
) -> ApiResult<impl IntoResponse> {
    let rows = sqlx::query(
        "SELECT a.id, a.email, a.display_name, a.is_admin, a.disabled, a.quota_bytes, a.created_at,
                (SELECT count(*) FROM devices d WHERE d.account_id = a.id AND d.revoked_at IS NULL) AS devices,
                (SELECT COALESCE(SUM(c.plaintext_len),0) FROM chunks c WHERE c.account_id = a.id) AS used
         FROM accounts a ORDER BY a.created_at",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(json!({
        "users": rows.iter().map(|r| json!({
            "id": r.get::<Uuid, _>("id"),
            "email": r.get::<String, _>("email"),
            "display_name": r.get::<String, _>("display_name"),
            "is_admin": r.get::<bool, _>("is_admin"),
            "disabled": r.get::<bool, _>("disabled"),
            "quota_bytes": r.get::<Option<i64>, _>("quota_bytes"),
            "used_bytes": r.get::<i64, _>("used"),
            "devices": r.get::<i64, _>("devices"),
            "created_at": r.get::<DateTime<Utc>, _>("created_at"),
        })).collect::<Vec<_>>()
    })))
}

#[derive(Deserialize)]
pub struct PatchUser {
    pub disabled: Option<bool>,
    pub quota_bytes: Option<i64>,
    pub is_admin: Option<bool>,
}

pub async fn patch_user(
    State(state): State<AppState>,
    admin: AdminUser,
    Path(id): Path<Uuid>,
    Json(body): Json<PatchUser>,
) -> ApiResult<impl IntoResponse> {
    if id == admin.0.account_id && body.disabled == Some(true) {
        return Err(ApiError::BadRequest(
            "cannot disable your own account".into(),
        ));
    }
    if body.quota_bytes.map(|q| q < 0).unwrap_or(false) {
        return Err(ApiError::BadRequest("quota cannot be negative".into()));
    }
    let affected = sqlx::query(
        "UPDATE accounts SET
            disabled = COALESCE($2, disabled),
            quota_bytes = COALESCE($3, quota_bytes),
            is_admin = COALESCE($4, is_admin),
            updated_at = now()
         WHERE id = $1",
    )
    .bind(id)
    .bind(body.disabled)
    .bind(body.quota_bytes)
    .bind(body.is_admin)
    .execute(&state.pool)
    .await?
    .rows_affected();
    if affected == 0 {
        return Err(ApiError::NotFound);
    }
    if body.disabled == Some(true) {
        sqlx::query(
            "UPDATE api_tokens SET revoked_at = now() WHERE account_id = $1 AND revoked_at IS NULL",
        )
        .bind(id)
        .execute(&state.pool)
        .await?;
    }
    Ok(Json(json!({ "status": "updated" })))
}

pub async fn list_providers(
    State(state): State<AppState>,
    _admin: AdminUser,
) -> ApiResult<impl IntoResponse> {
    let rows = sqlx::query(
        "SELECT id, name, host, port, tls, username, max_connections, role, priority, groups,
                retention_days, enabled, created_at FROM providers ORDER BY priority",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(json!({
        "providers": rows.iter().map(|r| json!({
            "id": r.get::<Uuid, _>("id"),
            "name": r.get::<String, _>("name"),
            "host": r.get::<String, _>("host"),
            "port": r.get::<i32, _>("port"),
            "tls": r.get::<bool, _>("tls"),
            "username": r.get::<Option<String>, _>("username"),
            "max_connections": r.get::<i32, _>("max_connections"),
            "role": r.get::<String, _>("role"),
            "priority": r.get::<i32, _>("priority"),
            "groups": r.get::<Vec<String>, _>("groups"),
            "retention_days": r.get::<Option<i32>, _>("retention_days"),
            "enabled": r.get::<bool, _>("enabled"),
            "created_at": r.get::<DateTime<Utc>, _>("created_at"),
        })).collect::<Vec<_>>(),
        "note": "Provider changes are persisted and applied on the next backend restart."
    })))
}

#[derive(Deserialize)]
pub struct NewProvider {
    pub name: String,
    pub host: String,
    pub port: u16,
    #[serde(default = "default_true")]
    pub tls: bool,
    pub username: Option<String>,
    pub password: Option<String>,
    #[serde(default = "default_connections")]
    pub max_connections: usize,
    #[serde(default = "default_role")]
    pub role: String,
    #[serde(default = "default_priority")]
    pub priority: u8,
    #[serde(default = "default_groups")]
    pub groups: Vec<String>,
    pub retention_days: Option<u32>,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_true() -> bool {
    true
}
fn default_connections() -> usize {
    4
}
fn default_role() -> String {
    "both".into()
}
fn default_priority() -> u8 {
    100
}
fn default_groups() -> Vec<String> {
    vec!["alt.binaries.nntdrive".into()]
}

pub async fn create_provider(
    State(state): State<AppState>,
    _admin: AdminUser,
    Json(body): Json<NewProvider>,
) -> ApiResult<impl IntoResponse> {
    if body.host.trim().is_empty() || body.name.trim().is_empty() {
        return Err(ApiError::BadRequest("name and host are required".into()));
    }
    if !(1..=65535).contains(&body.port) {
        return Err(ApiError::BadRequest("invalid port".into()));
    }
    if body.groups.is_empty() {
        return Err(ApiError::BadRequest(
            "at least one group is required".into(),
        ));
    }
    if !matches!(
        body.role.as_str(),
        "both" | "posting_only" | "retrieval_only"
    ) {
        return Err(ApiError::BadRequest(
            "role must be both, posting_only or retrieval_only".into(),
        ));
    }
    if body.username.is_some() != body.password.is_some() {
        return Err(ApiError::BadRequest(
            "username and password must be provided together".into(),
        ));
    }
    let password_enc = body
        .password
        .as_ref()
        .map(|p| seal_provider_password(&state, p));
    let id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO providers (id, name, host, port, tls, username, password_enc, max_connections,
                                role, priority, groups, retention_days, enabled)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
    )
    .bind(id)
    .bind(body.name.trim())
    .bind(body.host.trim())
    .bind(body.port as i32)
    .bind(body.tls)
    .bind(&body.username)
    .bind(&password_enc)
    .bind(body.max_connections as i32)
    .bind(&body.role)
    .bind(body.priority as i32)
    .bind(&body.groups)
    .bind(body.retention_days.map(|d| d as i32))
    .bind(body.enabled)
    .execute(&state.pool)
    .await
    .map_err(|e| match e.as_database_error() {
        Some(db) if db.is_unique_violation() => ApiError::Conflict("provider name exists".into()),
        _ => ApiError::Db(e),
    })?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "id": id, "restart_required": true })),
    ))
}

pub async fn delete_provider(
    State(state): State<AppState>,
    _admin: AdminUser,
    Path(id): Path<Uuid>,
) -> ApiResult<impl IntoResponse> {
    let n = sqlx::query("DELETE FROM providers WHERE id = $1")
        .bind(id)
        .execute(&state.pool)
        .await?
        .rows_affected();
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(Json(
        json!({ "status": "deleted", "restart_required": true }),
    ))
}

#[derive(Deserialize)]
pub struct EnqueueJob {
    pub kind: String,
    #[serde(default)]
    pub payload: Value,
}

pub async fn enqueue_job(
    State(state): State<AppState>,
    _admin: AdminUser,
    Json(body): Json<EnqueueJob>,
) -> ApiResult<impl IntoResponse> {
    if !matches!(
        body.kind.as_str(),
        "health_sweep" | "repair_stripe" | "refresh_sweep"
    ) {
        return Err(ApiError::BadRequest("unsupported job kind".into()));
    }
    let id = jobs::enqueue(&state.pool, &body.kind, None, body.payload, 0).await?;
    Ok((StatusCode::CREATED, Json(json!({ "job_id": id }))))
}

pub async fn list_jobs(
    State(state): State<AppState>,
    _admin: AdminUser,
) -> ApiResult<impl IntoResponse> {
    let rows = sqlx::query(
        "SELECT id, kind, state, attempts, max_attempts, run_after, last_error, created_at, updated_at
         FROM jobs ORDER BY created_at DESC LIMIT 200",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(json!({
        "jobs": rows.iter().map(|r| json!({
            "id": r.get::<Uuid, _>("id"),
            "kind": r.get::<String, _>("kind"),
            "state": r.get::<String, _>("state"),
            "attempts": r.get::<i32, _>("attempts"),
            "max_attempts": r.get::<i32, _>("max_attempts"),
            "run_after": r.get::<DateTime<Utc>, _>("run_after"),
            "last_error": r.get::<Option<String>, _>("last_error"),
            "created_at": r.get::<DateTime<Utc>, _>("created_at"),
            "updated_at": r.get::<DateTime<Utc>, _>("updated_at"),
        })).collect::<Vec<_>>()
    })))
}
