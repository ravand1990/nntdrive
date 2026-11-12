//! Fixed account roots: one account-wide Global space and one root per device.
//!
//! The backend never seals a name. A client sends the sealed `name_enc` for a
//! root exactly like any other folder; the server stores it opaquely and keeps
//! only fixed node IDs. Bootstrap is idempotent so two clients (or two fresh
//! installs) converge on the same root instead of creating duplicates.

use crate::api::{append_event, lock_namespace};
use crate::auth::Auth;
use crate::error::{b64, unb64, ApiError, ApiResult};
use crate::state::AppState;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use uuid::Uuid;

/// Matches the namespace limit for every other sealed name.
const MAX_NAME_ENC: usize = 8192;

/// A device root is reported stale once its device has not logged in or been
/// upserted for this long. `last_seen_at` is updated on login/enrollment, not
/// per request, so this is a coarse marker. Staleness is informative only: the
/// root stays listed and usable.
const DEVICE_ONLINE_WINDOW_SECS: i64 = 86_400;

#[derive(Deserialize)]
pub struct BootstrapRoot {
    pub kind: String,
    pub name_enc: String,
}

/// Create the account's Global root or the current device's root, once.
///
/// Repeating the call (a different client, a retry, a reinstall) returns the
/// existing root with its original sealed name, so all clients agree on the
/// same node ID and envelope. Concurrent callers serialize on the account
/// namespace lock and the unique indexes.
pub async fn bootstrap_root(
    State(state): State<AppState>,
    auth: Auth,
    Json(body): Json<BootstrapRoot>,
) -> ApiResult<impl IntoResponse> {
    let name_enc = unb64(&body.name_enc)?;
    if name_enc.is_empty() || name_enc.len() > MAX_NAME_ENC {
        return Err(ApiError::BadRequest(format!(
            "name_enc must be 1..{MAX_NAME_ENC} bytes"
        )));
    }
    let device_id = match body.kind.as_str() {
        "global" => None,
        "device" => Some(auth.device_id.ok_or_else(|| {
            ApiError::BadRequest("a device-bound token is required for a device root".into())
        })?),
        other => return Err(ApiError::BadRequest(format!("unknown root kind: {other}"))),
    };

    let mut tx = state.pool.begin().await?;
    lock_namespace(&mut tx, auth.account_id).await?;
    if let Some(existing) = load_root(&mut tx, auth.account_id, &body.kind, device_id).await? {
        tx.commit().await?;
        return Ok((StatusCode::OK, Json(existing)));
    }

    let root_id = Uuid::new_v4();
    let node_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO files (id, account_id, parent_id, name_enc, is_dir)
         VALUES ($1, $2, NULL, $3, TRUE)",
    )
    .bind(node_id)
    .bind(auth.account_id)
    .bind(&name_enc)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO account_roots (id, account_id, kind, device_id, node_id)
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(root_id)
    .bind(auth.account_id)
    .bind(&body.kind)
    .bind(device_id)
    .bind(node_id)
    .execute(&mut *tx)
    .await
    .map_err(|e| match e.as_database_error() {
        Some(db) if db.is_unique_violation() => {
            ApiError::Conflict("root already exists; refresh and retry".into())
        }
        _ => ApiError::Db(e),
    })?;
    append_event(
        &mut tx,
        auth.account_id,
        auth.device_id,
        node_id,
        None,
        "create",
        json!({ "is_dir": true, "root": body.kind }),
    )
    .await?;
    tx.commit().await?;

    Ok((
        StatusCode::CREATED,
        Json(json!({
            "root_id": root_id,
            "kind": body.kind,
            "node_id": node_id,
            "name_enc": b64(&name_enc),
            "device_id": device_id,
        })),
    ))
}

/// Every fixed root of the account, Global first. Device roots stay listed
/// after their device goes offline or is revoked, marked stale.
pub async fn list_roots(State(state): State<AppState>, auth: Auth) -> ApiResult<impl IntoResponse> {
    let rows = sqlx::query(
        "SELECT r.id, r.kind, r.node_id, f.name_enc, f.created_at, r.device_id,
                d.name AS device_name, d.platform AS device_platform,
                d.last_seen_at AS device_last_seen_at, d.revoked_at AS device_revoked_at
         FROM account_roots r
         JOIN files f ON f.account_id = r.account_id AND f.id = r.node_id AND f.deleted = FALSE
         LEFT JOIN devices d ON d.account_id = r.account_id AND d.id = r.device_id
         WHERE r.account_id = $1
         ORDER BY (r.kind = 'device'), r.created_at, r.id",
    )
    .bind(auth.account_id)
    .fetch_all(&state.pool)
    .await?;
    let now = Utc::now();
    let roots: Vec<Value> = rows
        .iter()
        .map(|r| {
            let kind: String = r.get("kind");
            let revoked_at: Option<DateTime<Utc>> = r.get("device_revoked_at");
            let last_seen_at: Option<DateTime<Utc>> = r.get("device_last_seen_at");
            let stale = kind == "device"
                && (revoked_at.is_some()
                    || last_seen_at
                        .is_none_or(|seen| (now - seen).num_seconds() > DEVICE_ONLINE_WINDOW_SECS));
            json!({
                "root_id": r.get::<Uuid, _>("id"),
                "kind": kind,
                "node_id": r.get::<Uuid, _>("node_id"),
                "name_enc": b64(&r.get::<Vec<u8>, _>("name_enc")),
                "created_at": r.get::<DateTime<Utc>, _>("created_at"),
                "device_id": r.get::<Option<Uuid>, _>("device_id"),
                "device_name": r.get::<Option<String>, _>("device_name"),
                "device_platform": r.get::<Option<String>, _>("device_platform"),
                "device_last_seen_at": last_seen_at,
                "device_revoked": revoked_at.is_some(),
                "stale": stale,
            })
        })
        .collect();
    Ok(Json(json!({ "roots": roots })))
}

async fn load_root(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: Uuid,
    kind: &str,
    device_id: Option<Uuid>,
) -> ApiResult<Option<Value>> {
    let row = sqlx::query(
        "SELECT r.id, r.kind, r.node_id, f.name_enc
         FROM account_roots r
         JOIN files f ON f.account_id = r.account_id AND f.id = r.node_id AND f.deleted = FALSE
         WHERE r.account_id = $1 AND r.kind = $2
           AND ((r.device_id IS NULL AND $3::uuid IS NULL) OR r.device_id = $3)
         LIMIT 1",
    )
    .bind(account_id)
    .bind(kind)
    .bind(device_id)
    .fetch_optional(&mut **tx)
    .await?;
    Ok(row.map(|r| {
        json!({
            "root_id": r.get::<Uuid, _>("id"),
            "kind": r.get::<String, _>("kind"),
            "node_id": r.get::<Uuid, _>("node_id"),
            "name_enc": b64(&r.get::<Vec<u8>, _>("name_enc")),
            "device_id": device_id,
        })
    }))
}
