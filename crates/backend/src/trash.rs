//! Trash view and restore for logically deleted namespace nodes.
//!
//! Deletion never removes metadata or content here: a node keeps its versions,
//! and its rows stay restorable until the retention window has passed. This
//! module never purges anything; it only lists and restores.
//!
//! Everything is account-scoped. Names stay sealed envelopes, so the server
//! cannot read them and returns exactly the same bytes it stored.

use crate::api::{append_event, lock_namespace};
use crate::auth::Auth;
use crate::error::{b64, ApiError, ApiResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use uuid::Uuid;

/// `GET /trash` — the deleted top-level nodes of this account, newest first.
///
/// A node whose parent is also deleted is not listed separately: restoring the
/// listed ancestor brings the whole subtree back.
pub async fn list_trash(State(state): State<AppState>, auth: Auth) -> ApiResult<impl IntoResponse> {
    let retention_days = state.config.trash_retention_days as i64;
    let rows = sqlx::query(
        "SELECT f.id, f.parent_id, f.name_enc, f.is_dir, f.size,
                COALESCE(f.deleted_at, f.updated_at) AS deleted_at,
                COALESCE(f.deleted_at, f.updated_at) + ($2::bigint * interval '1 day') AS expires_at,
                CASE WHEN f.parent_id IS NULL THEN TRUE
                     ELSE EXISTS (
                         SELECT 1 FROM files p
                         WHERE p.account_id = f.account_id
                           AND p.id = f.parent_id
                           AND p.deleted = FALSE
                     )
                END AS parent_present
         FROM files f
         WHERE f.account_id = $1 AND f.deleted = TRUE
           AND (f.parent_id IS NULL OR NOT EXISTS (
                 SELECT 1 FROM files p
                 WHERE p.account_id = f.account_id
                   AND p.id = f.parent_id
                   AND p.deleted = TRUE
           ))
         ORDER BY deleted_at DESC, f.id",
    )
    .bind(auth.account_id)
    .bind(retention_days)
    .fetch_all(&state.pool)
    .await?;

    let now = Utc::now();
    let files: Vec<Value> = rows
        .iter()
        .map(|r| {
            let deleted_at: DateTime<Utc> = r.get("deleted_at");
            let expires_at: DateTime<Utc> = r.get("expires_at");
            let left = expires_at - now;
            let seconds = left.num_seconds();
            let days_left = if seconds <= 0 {
                0
            } else {
                (seconds + 86_399) / 86_400
            };
            json!({
                "id": r.get::<Uuid, _>("id"),
                "parent_id": r.get::<Option<Uuid>, _>("parent_id"),
                "name_enc": b64(&r.get::<Vec<u8>, _>("name_enc")),
                "is_dir": r.get::<bool, _>("is_dir"),
                "size": r.get::<i64, _>("size"),
                "deleted_at": deleted_at,
                "expires_at": expires_at,
                "days_left": days_left,
                "expired": seconds <= 0,
                "parent_present": r.get::<bool, _>("parent_present"),
            })
        })
        .collect();

    Ok(Json(json!({
        "retention_days": retention_days,
        "files": files,
    })))
}

#[derive(Deserialize, Default)]
pub struct RestoreFile {
    /// Destination folder. Omitting the field keeps the original parent,
    /// `null` restores to the account root, and a value moves the item there.
    /// A destination is required when the original parent is gone.
    #[serde(default, deserialize_with = "present_option")]
    pub parent_id: Option<Option<Uuid>>,
}

/// Distinguish an absent field from an explicit `null` value.
fn present_option<'de, D>(deserializer: D) -> Result<Option<Option<Uuid>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<Uuid>::deserialize(deserializer).map(Some)
}

/// `POST /files/{id}/restore` — clear the delete flag of a node and its subtree.
///
/// The original parent must still be present unless the caller names a
/// destination; the destination must be a live folder of the same account and
/// must not be the restored node or one of its descendants.
pub async fn restore_file(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
    Json(body): Json<RestoreFile>,
) -> ApiResult<impl IntoResponse> {
    let retention_days = state.config.trash_retention_days as i64;
    let mut tx = state.pool.begin().await?;
    lock_namespace(&mut tx, auth.account_id).await?;

    let row = sqlx::query(
        "SELECT parent_id, deleted, COALESCE(deleted_at, updated_at) AS deleted_at
         FROM files WHERE account_id = $1 AND id = $2 FOR UPDATE",
    )
    .bind(auth.account_id)
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let Some(row) = row else {
        return Err(ApiError::NotFound);
    };
    if !row.get::<bool, _>("deleted") {
        return Err(ApiError::Conflict("this item is not in the trash".into()));
    }
    let deleted_at: DateTime<Utc> = row.get("deleted_at");
    if deleted_at + chrono::Duration::days(retention_days) <= Utc::now() {
        return Err(ApiError::Gone(
            "this item passed the trash retention window".into(),
        ));
    }

    let destination: Option<Option<Uuid>> = match body.parent_id {
        Some(Some(dest)) => {
            let target =
                sqlx::query("SELECT is_dir, deleted FROM files WHERE account_id = $1 AND id = $2")
                    .bind(auth.account_id)
                    .bind(dest)
                    .fetch_optional(&mut *tx)
                    .await?;
            match target {
                None => return Err(ApiError::NotFound),
                Some(t) if t.get::<bool, _>("deleted") => {
                    return Err(ApiError::Conflict(
                        "the destination folder is in the trash".into(),
                    ))
                }
                Some(t) if !t.get::<bool, _>("is_dir") => {
                    return Err(ApiError::BadRequest("destination is not a folder".into()))
                }
                Some(_) => {}
            }
            if inside_subtree(&mut tx, auth.account_id, id, dest).await? {
                return Err(ApiError::BadRequest(
                    "cannot restore an item inside itself".into(),
                ));
            }
            Some(Some(dest))
        }
        Some(None) => Some(None),
        None => {
            if let Some(parent) = row.get::<Option<Uuid>, _>("parent_id") {
                let live: Option<bool> = sqlx::query_scalar(
                    "SELECT deleted = FALSE FROM files WHERE account_id = $1 AND id = $2",
                )
                .bind(auth.account_id)
                .bind(parent)
                .fetch_optional(&mut *tx)
                .await?;
                if live != Some(true) {
                    return Err(ApiError::Conflict(
                        "the original folder is gone; choose where to restore this item".into(),
                    ));
                }
            }
            None
        }
    };

    if let Some(dest) = destination {
        sqlx::query(
            "UPDATE files SET parent_id = $3, updated_at = now(), revision = revision + 1
             WHERE account_id = $1 AND id = $2",
        )
        .bind(auth.account_id)
        .bind(id)
        .bind(dest)
        .execute(&mut *tx)
        .await?;
    }

    let restored = sqlx::query(
        "WITH RECURSIVE subtree AS (
             SELECT id FROM files WHERE account_id = $1 AND id = $2
             UNION ALL
             SELECT f.id FROM files f JOIN subtree s ON f.parent_id = s.id
             WHERE f.account_id = $1 AND f.deleted = TRUE
         )
         UPDATE files SET deleted = FALSE, deleted_at = NULL,
                          updated_at = now(), revision = revision + 1
         WHERE account_id = $1 AND id IN (SELECT id FROM subtree) AND deleted = TRUE",
    )
    .bind(auth.account_id)
    .bind(id)
    .execute(&mut *tx)
    .await?;

    append_event(
        &mut tx,
        auth.account_id,
        auth.device_id,
        id,
        None,
        "restore",
        json!({ "parent_id": destination }),
    )
    .await?;
    tx.commit().await?;

    Ok(Json(json!({
        "status": "restored",
        "id": id,
        "parent_id": destination,
        "restored": restored.rows_affected(),
    })))
}

/// True when `candidate` is `root` or sits below it in the same account.
async fn inside_subtree(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: Uuid,
    root: Uuid,
    candidate: Uuid,
) -> ApiResult<bool> {
    let found: bool = sqlx::query_scalar(
        "WITH RECURSIVE subtree AS (
             SELECT id FROM files WHERE account_id = $1 AND id = $2
             UNION ALL
             SELECT f.id FROM files f JOIN subtree s ON f.parent_id = s.id
             WHERE f.account_id = $1
         )
         SELECT EXISTS (SELECT 1 FROM subtree WHERE id = $3)",
    )
    .bind(account_id)
    .bind(root)
    .bind(candidate)
    .fetch_one(&mut **tx)
    .await?;
    Ok(found)
}
