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
use nntdrive_nntp::Provider;
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
                (SELECT COALESCE(SUM(c.plaintext_len),0)::bigint FROM chunks c WHERE c.account_id = a.id) AS used
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
    pub display_name: Option<String>,
    pub disabled: Option<bool>,
    pub quota_bytes: Option<i64>,
    /// Explicitly removes the quota (sets it back to unlimited).
    #[serde(default)]
    pub unlimited_quota: bool,
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
    if id == admin.0.account_id && body.is_admin == Some(false) {
        return Err(ApiError::BadRequest(
            "cannot remove your own administrator role".into(),
        ));
    }
    if body.quota_bytes.map(|q| q < 0).unwrap_or(false) {
        return Err(ApiError::BadRequest("quota cannot be negative".into()));
    }
    let display_name = body.display_name.map(|n| n.trim().to_string());
    if display_name.as_deref() == Some("") {
        return Err(ApiError::BadRequest("display name cannot be empty".into()));
    }
    let affected = sqlx::query(
        "UPDATE accounts SET
            display_name = COALESCE($2, display_name),
            disabled = COALESCE($3, disabled),
            quota_bytes = CASE WHEN $6 THEN NULL ELSE COALESCE($4, quota_bytes) END,
            is_admin = COALESCE($5, is_admin),
            updated_at = now()
         WHERE id = $1",
    )
    .bind(id)
    .bind(&display_name)
    .bind(body.disabled)
    .bind(body.quota_bytes)
    .bind(body.is_admin)
    .bind(body.unlimited_quota)
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
        "note": "Provider changes are applied immediately on this backend."
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

async fn create_provider_inner(
    State(state): State<AppState>,
    _admin: AdminUser,
    Json(body): Json<NewProvider>,
) -> ApiResult<impl IntoResponse> {
    let _guard = state.provider_mutations.lock().await;
    let mut tx = state.pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(706847102)")
        .execute(&mut *tx)
        .await?;

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
    if !(1..=200).contains(&body.max_connections)
        || body.retention_days.is_some_and(|d| d > i32::MAX as u32)
    {
        return Err(ApiError::BadRequest("invalid provider limits".into()));
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
    .execute(&mut *tx)
    .await
    .map_err(|e| match e.as_database_error() {
        Some(db) if db.is_unique_violation() => ApiError::Conflict("provider name exists".into()),
        _ => ApiError::Db(e),
    })?;
    let pool = crate::load_db_providers(&mut tx, &state.config.secret_key)
        .await
        .map_err(|_| {
            ApiError::BadRequest("invalid provider configuration or credentials".into())
        })?;
    sqlx::query("INSERT INTO provider_management VALUES (true) ON CONFLICT DO NOTHING")
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    // The detached mutation task finishes publication even if the request disconnects.
    state.storage.replace_nntp(std::sync::Arc::new(pool));
    Ok((
        StatusCode::CREATED,
        Json(json!({ "id": id, "restart_required": false, "applied": true })),
    ))
}

#[derive(Deserialize)]
pub struct PatchProvider {
    pub name: Option<String>,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub tls: Option<bool>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub max_connections: Option<usize>,
    pub role: Option<String>,
    pub priority: Option<u8>,
    pub groups: Option<Vec<String>>,
    pub retention_days: Option<u32>,
    pub enabled: Option<bool>,
}

/// Edits a provider in place. Fields left out keep their current value. A blank
/// password keeps the stored one; clearing the username clears both.
async fn patch_provider_inner(
    State(state): State<AppState>,
    _admin: AdminUser,
    Path(id): Path<Uuid>,
    Json(body): Json<PatchProvider>,
) -> ApiResult<impl IntoResponse> {
    let _guard = state.provider_mutations.lock().await;
    let mut tx = state.pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(706847102)")
        .execute(&mut *tx)
        .await?;

    let row = sqlx::query(
        "SELECT name, host, port, tls, username, password_enc, max_connections, role,
                priority, groups, retention_days, enabled FROM providers WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(ApiError::NotFound)?;

    let name = body
        .name
        .map(|n| n.trim().to_string())
        .unwrap_or_else(|| row.get("name"));
    let host = body
        .host
        .map(|h| h.trim().to_string())
        .unwrap_or_else(|| row.get("host"));
    if name.is_empty() || host.is_empty() {
        return Err(ApiError::BadRequest("name and host are required".into()));
    }
    let role = body.role.unwrap_or_else(|| row.get("role"));
    if !matches!(role.as_str(), "both" | "posting_only" | "retrieval_only") {
        return Err(ApiError::BadRequest(
            "role must be both, posting_only or retrieval_only".into(),
        ));
    }
    let groups = body.groups.unwrap_or_else(|| row.get("groups"));
    if groups.is_empty() {
        return Err(ApiError::BadRequest(
            "at least one group is required".into(),
        ));
    }
    let max_connections = body
        .max_connections
        .unwrap_or_else(|| row.get::<i32, _>("max_connections").max(1) as usize);
    if !(1..=200).contains(&max_connections)
        || body.retention_days.is_some_and(|d| d > i32::MAX as u32)
    {
        return Err(ApiError::BadRequest(
            "max connections must be at least 1".into(),
        ));
    }
    let username_provided = body.username.is_some();
    let username = match body.username {
        Some(value) => {
            let value = value.trim();
            if value.is_empty() {
                None
            } else {
                Some(value.to_string())
            }
        }
        None => row.get::<Option<String>, _>("username"),
    };
    let password_enc = match body
        .password
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())
    {
        Some(password) => Some(seal_provider_password(&state, password)),
        None if username_provided && username.is_none() => None,
        None => row.get::<Option<Vec<u8>>, _>("password_enc"),
    };
    if username.is_some() != password_enc.is_some() {
        return Err(ApiError::BadRequest(
            "username and password must be provided together".into(),
        ));
    }
    let port = body.port.map(i32::from).unwrap_or_else(|| row.get("port"));
    let retention_days = body
        .retention_days
        .map(|d| d as i32)
        .or_else(|| row.get("retention_days"));

    sqlx::query(
        "UPDATE providers SET name = $2, host = $3, port = $4, tls = $5, username = $6,
                password_enc = $7, max_connections = $8, role = $9, priority = $10,
                groups = $11, retention_days = $12, enabled = $13
         WHERE id = $1",
    )
    .bind(id)
    .bind(&name)
    .bind(&host)
    .bind(port)
    .bind(body.tls.unwrap_or_else(|| row.get("tls")))
    .bind(&username)
    .bind(&password_enc)
    .bind(max_connections as i32)
    .bind(&role)
    .bind(
        body.priority
            .map(i32::from)
            .unwrap_or_else(|| row.get("priority")),
    )
    .bind(&groups)
    .bind(retention_days)
    .bind(body.enabled.unwrap_or_else(|| row.get("enabled")))
    .execute(&mut *tx)
    .await
    .map_err(|e| match e.as_database_error() {
        Some(db) if db.is_unique_violation() => ApiError::Conflict("provider name exists".into()),
        _ => ApiError::Db(e),
    })?;

    let pool = crate::load_db_providers(&mut tx, &state.config.secret_key)
        .await
        .map_err(|_| {
            ApiError::BadRequest("invalid provider configuration or credentials".into())
        })?;
    sqlx::query("INSERT INTO provider_management VALUES (true) ON CONFLICT DO NOTHING")
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    // The detached mutation task finishes publication even if the request disconnects.
    state.storage.replace_nntp(std::sync::Arc::new(pool));
    Ok(Json(json!({
        "id": id,
        "status": "updated",
        "restart_required": false, "applied": true
    })))
}

async fn delete_provider_inner(
    State(state): State<AppState>,
    _admin: AdminUser,
    Path(id): Path<Uuid>,
) -> ApiResult<impl IntoResponse> {
    let _guard = state.provider_mutations.lock().await;
    let mut tx = state.pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(706847102)")
        .execute(&mut *tx)
        .await?;

    let n = sqlx::query("DELETE FROM providers WHERE id = $1")
        .bind(id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    let pool = crate::load_db_providers(&mut tx, &state.config.secret_key)
        .await
        .map_err(|_| {
            ApiError::BadRequest("invalid provider configuration or credentials".into())
        })?;
    sqlx::query("INSERT INTO provider_management VALUES (true) ON CONFLICT DO NOTHING")
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    // The detached mutation task finishes publication even if the request disconnects.
    state.storage.replace_nntp(std::sync::Arc::new(pool));
    Ok(Json(
        json!({ "status": "deleted", "restart_required": false, "applied": true }),
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

/// Gracefully stops the backend so the container manager restarts it. Used to
/// apply provider configuration changes without shell access. The response is
/// sent first; the process shuts down ~400 ms later.
/// Verifies recently posted articles are retrievable from the configured
/// retrieval providers. This is a real NNTP STAT, not a database read.
pub async fn verify_recent_articles(
    State(state): State<AppState>,
    _admin: AdminUser,
) -> ApiResult<impl IntoResponse> {
    let rows = sqlx::query(
        "SELECT message_id, provider, status, size, posted_at FROM shards
         ORDER BY posted_at DESC LIMIT 20",
    )
    .fetch_all(&state.pool)
    .await?;
    let nntp = state.storage.nntp();
    let mut items = Vec::with_capacity(rows.len());
    let mut available = 0usize;
    let mut provider_names: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for row in rows {
        let message_id: String = row.get("message_id");
        let found_on = nntp.available_on(&message_id).await;
        if !found_on.is_empty() {
            available += 1;
            provider_names.extend(found_on.iter().cloned());
        }
        items.push(json!({
            "message_id": message_id,
            "posted_by_provider": row.get::<Option<String>, _>("provider"),
            "db_status": row.get::<String, _>("status"),
            "size": row.get::<i64, _>("size"),
            "posted_at": row.get::<DateTime<Utc>, _>("posted_at"),
            "available_on": found_on,
        }));
    }
    let total = items.len();
    Ok(Json(json!({
        "total": total,
        "available": available,
        "missing": total - available,
        "all_available": total > 0 && available == total,
        "providers": provider_names.into_iter().collect::<Vec<_>>(),
        "items": items,
    })))
}

/// Connects and authenticates to a stored provider without posting. Returns a
/// clear result so operators can fix host/port/credentials before an upload.
pub async fn test_provider(
    State(state): State<AppState>,
    _admin: AdminUser,
    Path(id): Path<Uuid>,
) -> ApiResult<impl IntoResponse> {
    let row = sqlx::query(
        "SELECT name, host, port, tls, username, password_enc, max_connections, role,
                priority, groups, retention_days FROM providers WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(ApiError::NotFound)?;
    let config = crate::provider_config(&row, &state.config.secret_key).map_err(|_| {
        ApiError::BadRequest("invalid provider configuration or credentials".into())
    })?;
    let provider = Provider::new(config).map_err(|e| ApiError::BadRequest(e.to_string()))?;
    match provider.stat("nntdrive-connectivity-probe@invalid").await {
        Ok(_) => Ok(Json(json!({
            "ok": true,
            "message": "connected and authenticated; the test article is not expected to exist",
            "posting_note": "posting permission is only confirmed by an actual upload"
        }))),
        Err(e) => Ok(Json(json!({
            "ok": false,
            "message": e.to_string()
        }))),
    }
}

pub async fn restart_backend(
    State(state): State<AppState>,
    _admin: AdminUser,
) -> ApiResult<impl IntoResponse> {
    let notify = state.restart.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        tracing::warn!("admin requested backend restart");
        notify.notify_waiters();
    });
    Ok(Json(json!({
        "status": "restarting",
        "message": "backend is restarting; retry in a few seconds"
    })))
}

/// Finish an admitted mutation even if its HTTP request is cancelled during COMMIT.
pub async fn create_provider(
    State(state): State<AppState>,
    admin: AdminUser,
    Json(body): Json<NewProvider>,
) -> ApiResult<axum::response::Response> {
    tokio::spawn(async move {
        create_provider_inner(State(state), admin, Json(body))
            .await
            .map(IntoResponse::into_response)
    })
    .await
    .map_err(|_| ApiError::Internal(anyhow::anyhow!("provider mutation task failed")))?
}

/// Finish an admitted mutation even if its HTTP request is cancelled during COMMIT.
pub async fn patch_provider(
    State(state): State<AppState>,
    admin: AdminUser,
    Path(id): Path<Uuid>,
    Json(body): Json<PatchProvider>,
) -> ApiResult<axum::response::Response> {
    tokio::spawn(async move {
        patch_provider_inner(State(state), admin, Path(id), Json(body))
            .await
            .map(IntoResponse::into_response)
    })
    .await
    .map_err(|_| ApiError::Internal(anyhow::anyhow!("provider mutation task failed")))?
}

/// Finish an admitted mutation even if its HTTP request is cancelled during COMMIT.
pub async fn delete_provider(
    State(state): State<AppState>,
    admin: AdminUser,
    Path(id): Path<Uuid>,
) -> ApiResult<axum::response::Response> {
    tokio::spawn(async move {
        delete_provider_inner(State(state), admin, Path(id))
            .await
            .map(IntoResponse::into_response)
    })
    .await
    .map_err(|_| ApiError::Internal(anyhow::anyhow!("provider mutation task failed")))?
}
