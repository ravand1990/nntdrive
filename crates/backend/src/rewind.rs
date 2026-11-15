//! Bulk rewind: put a folder or the whole account back to an earlier date.
//!
//! Rewind uses only versions that already exist. Each affected file's current
//! content pointer moves back to the newest version committed at or before the
//! chosen date, while newer versions and their chunk references are kept, so a
//! rewind never deletes history and never destroys concurrent work. Nothing is
//! uploaded, downloaded or retracted: articles already posted to Usenet cannot
//! be removed and deletion stays logical.
//!
//! Trashed items are not part of a rewind. Restoring them is the trash feature,
//! and a rewind never silently resurrects deleted metadata.
//!
//! Everything is account-scoped, names stay sealed envelopes, and the preview
//! and the confirmed apply use the same account namespace lock as other writers.

use crate::api::{append_event, lock_namespace};
use crate::auth::Auth;
use crate::error::{b64, ApiError, ApiResult};
use crate::state::AppState;
use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use uuid::Uuid;

/// One preview page never returns more than this many items.
pub const PREVIEW_LIMIT: i64 = 200;
/// One confirmed rewind applies at most this many items.
pub const APPLY_LIMIT: usize = 200;

#[derive(Deserialize)]
pub struct PreviewQuery {
    /// Rewind target instant (RFC 3339). Only versions committed at or before
    /// it are considered.
    pub before: String,
    /// Folder to rewind. Omit for the whole account.
    pub scope: Option<Uuid>,
    /// Keyset cursor: only files with an id greater than this are returned.
    pub after: Option<Uuid>,
}

/// Errors out unless the folder is a live folder of this account; `None` means
/// the whole account and needs no lookup.
async fn check_scope(
    state: &AppState,
    account_id: Uuid,
    scope: Option<Uuid>,
) -> ApiResult<Option<Uuid>> {
    let Some(id) = scope else { return Ok(None) };
    let row = sqlx::query("SELECT is_dir, deleted FROM files WHERE account_id = $1 AND id = $2")
        .bind(account_id)
        .bind(id)
        .fetch_optional(&state.pool)
        .await?;
    let Some(row) = row else {
        return Err(ApiError::NotFound);
    };
    if !row.get::<bool, _>("is_dir") {
        return Err(ApiError::BadRequest("the scope is not a folder".into()));
    }
    if row.get::<bool, _>("deleted") {
        return Err(ApiError::Conflict(
            "the folder is in the trash; restore it first".into(),
        ));
    }
    Ok(Some(id))
}

fn parse_before(value: &str) -> ApiResult<DateTime<Utc>> {
    let before = DateTime::parse_from_rfc3339(value)
        .map_err(|_| ApiError::BadRequest("invalid rewind date".into()))?
        .with_timezone(&Utc);
    if before > Utc::now() + chrono::Duration::minutes(5) {
        return Err(ApiError::BadRequest(
            "the rewind date is in the future".into(),
        ));
    }
    Ok(before)
}

/// `GET /rewind/preview` — what a rewind to `before` would change, paged.
///
/// Only files whose current content differs from the newest version at or
/// before the date are listed. Counts cover the whole scope so the caller can
/// say how many files a rewind would change, leave alone or skip; skipped means
/// the file has no usable version at that date (it was created later, or its
/// stored references are still pending) and is never touched.
pub async fn preview(
    State(state): State<AppState>,
    auth: Auth,
    Query(q): Query<PreviewQuery>,
) -> ApiResult<impl IntoResponse> {
    let before = parse_before(&q.before)?;
    let scope = check_scope(&state, auth.account_id, q.scope).await?;

    let counts = sqlx::query(
        "WITH RECURSIVE sub AS (
             SELECT f0.id FROM files f0
             WHERE f0.account_id = $1
               AND ($2::uuid IS NULL OR f0.id = $2::uuid)
             UNION
             SELECT c.id FROM files c JOIN sub s ON c.parent_id = s.id
             WHERE c.account_id = $1
         )
         SELECT
             count(*) FILTER (WHERE t.revision_id IS NULL) AS created_after,
             count(*) FILTER (WHERE t.revision_id IS NOT NULL
                                AND NOT t.references_complete) AS pending,
             count(*) FILTER (WHERE t.references_complete
                                AND t.revision_id = f.current_version) AS unchanged,
             count(*) FILTER (WHERE t.references_complete
                                AND t.revision_id IS DISTINCT FROM f.current_version) AS rewind
         FROM files f
         LEFT JOIN LATERAL (
             SELECT v.revision_id, v.references_complete
             FROM file_versions v
             WHERE v.account_id = f.account_id AND v.file_id = f.id
               AND v.created_at <= $3 AND NOT v.deleted
             ORDER BY v.created_at DESC, v.id DESC
             LIMIT 1
         ) t ON TRUE
         WHERE f.account_id = $1 AND NOT f.is_dir AND NOT f.deleted
           AND f.id IN (SELECT id FROM sub)",
    )
    .bind(auth.account_id)
    .bind(scope)
    .bind(before)
    .fetch_one(&state.pool)
    .await?;

    let rows = sqlx::query(
        "WITH RECURSIVE sub AS (
             SELECT f0.id FROM files f0
             WHERE f0.account_id = $1
               AND ($2::uuid IS NULL OR f0.id = $2::uuid)
             UNION
             SELECT c.id FROM files c JOIN sub s ON c.parent_id = s.id
             WHERE c.account_id = $1
         )
         SELECT f.id, f.parent_id, f.name_enc, f.size AS current_size,
                f.current_version, t.revision_id AS target_revision,
                t.size AS target_size, t.created_at AS target_created_at
         FROM files f
         JOIN LATERAL (
             SELECT v.revision_id, v.size, v.created_at, v.references_complete
             FROM file_versions v
             WHERE v.account_id = f.account_id AND v.file_id = f.id
               AND v.created_at <= $3 AND NOT v.deleted
             ORDER BY v.created_at DESC, v.id DESC
             LIMIT 1
         ) t ON TRUE
         WHERE f.account_id = $1 AND NOT f.is_dir AND NOT f.deleted
           AND f.id IN (SELECT id FROM sub)
           AND t.references_complete
           AND t.revision_id IS DISTINCT FROM f.current_version
           AND ($4::uuid IS NULL OR f.id > $4)
         ORDER BY f.id
         LIMIT $5",
    )
    .bind(auth.account_id)
    .bind(scope)
    .bind(before)
    .bind(q.after)
    .bind(PREVIEW_LIMIT + 1)
    .fetch_all(&state.pool)
    .await?;

    let more = rows.len() as i64 > PREVIEW_LIMIT;
    let rows = &rows[..rows.len().min(PREVIEW_LIMIT as usize)];
    let items: Vec<Value> = rows
        .iter()
        .map(|r| {
            json!({
                "id": r.get::<Uuid, _>("id"),
                "parent_id": r.get::<Option<Uuid>, _>("parent_id"),
                "name_enc": b64(&r.get::<Vec<u8>, _>("name_enc")),
                "current_version": r.get::<Option<Uuid>, _>("current_version"),
                "target_revision": r.get::<Uuid, _>("target_revision"),
                "current_size": r.get::<i64, _>("current_size"),
                "target_size": r.get::<i64, _>("target_size"),
                "target_created_at": r.get::<DateTime<Utc>, _>("target_created_at"),
            })
        })
        .collect();

    Ok(Json(json!({
        "scope": scope,
        "before": before,
        "counts": {
            "rewind": counts.get::<i64, _>("rewind"),
            "unchanged": counts.get::<i64, _>("unchanged"),
            "created_after": counts.get::<i64, _>("created_after"),
            "pending_references": counts.get::<i64, _>("pending"),
        },
        "items": items,
        "next": if more { rows.last().map(|r| r.get::<Uuid, _>("id")) } else { None },
    })))
}

#[derive(Deserialize)]
pub struct RewindItem {
    pub id: Uuid,
    pub target_revision: Uuid,
}

#[derive(Deserialize)]
pub struct RewindBody {
    pub before: String,
    pub scope: Option<Uuid>,
    pub items: Vec<RewindItem>,
}

/// `POST /rewind` — apply a confirmed preview.
///
/// Each item is checked again under the account namespace lock: the file must
/// still be a live file of this account, and `target_revision` must still be
/// the newest version at or before `before`. A stale plan is rejected per item
/// instead of silently rewinding something the user never saw. Applying is
/// idempotent-ish: a file already at that content reports `unchanged`.
pub async fn apply(
    State(state): State<AppState>,
    auth: Auth,
    Json(body): Json<RewindBody>,
) -> ApiResult<impl IntoResponse> {
    let before = parse_before(&body.before)?;
    let scope = check_scope(&state, auth.account_id, body.scope).await?;
    if body.items.is_empty() {
        return Err(ApiError::BadRequest("no items to rewind".into()));
    }
    if body.items.len() > APPLY_LIMIT {
        return Err(ApiError::BadRequest(
            "too many items in one rewind request".into(),
        ));
    }
    let mut seen = std::collections::BTreeSet::new();
    if let Some(duplicate) = body.items.iter().find(|i| !seen.insert(i.id)) {
        return Err(ApiError::BadRequest(format!(
            "duplicate item {}",
            duplicate.id
        )));
    }

    let mut applied = 0usize;
    let mut unchanged = 0usize;
    let mut failed: Vec<Value> = Vec::new();

    for item in &body.items {
        match apply_one(&state, &auth, scope, before, item).await {
            Ok(true) => applied += 1,
            Ok(false) => unchanged += 1,
            Err(reason) => failed.push(json!({ "id": item.id, "reason": reason })),
        }
    }

    Ok(Json(json!({
        "scope": scope,
        "before": before,
        "applied": applied,
        "unchanged": unchanged,
        "failed": failed,
    })))
}

/// One item in its own transaction, so a single stale or foreign id cannot
/// block the rest of a confirmed rewind. Errors are plain reasons only.
async fn apply_one(
    state: &AppState,
    auth: &Auth,
    scope: Option<Uuid>,
    before: DateTime<Utc>,
    item: &RewindItem,
) -> Result<bool, String> {
    let mut tx = state
        .pool
        .begin()
        .await
        .map_err(|_| "database unavailable".to_string())?;
    lock_namespace(&mut tx, auth.account_id)
        .await
        .map_err(|_| "database unavailable".to_string())?;

    let file = sqlx::query(
        "SELECT is_dir, deleted, current_version FROM files
         WHERE account_id = $1 AND id = $2 FOR UPDATE",
    )
    .bind(auth.account_id)
    .bind(item.id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|_| "database unavailable".to_string())?
    .ok_or_else(|| "this file is gone".to_string())?;
    if file.get::<bool, _>("is_dir") {
        return Err("this item is a folder".into());
    }
    if file.get::<bool, _>("deleted") {
        return Err("this file is in the trash; restore it instead".into());
    }
    if let Some(scope) = scope {
        let inside: bool = sqlx::query_scalar(
            "WITH RECURSIVE sub AS (
                 SELECT id FROM files WHERE account_id = $1 AND id = $2
                 UNION
                 SELECT c.id FROM files c JOIN sub s ON c.parent_id = s.id
                 WHERE c.account_id = $1
             )
             SELECT EXISTS (SELECT 1 FROM sub WHERE id = $3)",
        )
        .bind(auth.account_id)
        .bind(scope)
        .bind(item.id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|_| "database unavailable".to_string())?;
        if !inside {
            return Err("this file is outside the rewound folder".into());
        }
    }

    let target = sqlx::query(
        "SELECT revision_id, size, content_hash, references_complete
         FROM file_versions
         WHERE account_id = $1 AND file_id = $2 AND created_at <= $3 AND NOT deleted
         ORDER BY created_at DESC, id DESC
         LIMIT 1",
    )
    .bind(auth.account_id)
    .bind(item.id)
    .bind(before)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|_| "database unavailable".to_string())?;
    let Some(target) = target else {
        return Err("no version exists at that date".into());
    };
    if target.get::<Uuid, _>("revision_id") != item.target_revision {
        return Err("the file changed; preview the rewind again".into());
    }
    if !target.get::<bool, _>("references_complete") {
        return Err("this version's content references are still pending".into());
    }
    if file.get::<Option<Uuid>, _>("current_version") == Some(item.target_revision) {
        return Ok(false);
    }

    sqlx::query(
        "UPDATE files SET current_version = $3, size = $4, content_hash = $5,
                          revision = revision + 1, updated_at = now()
         WHERE account_id = $1 AND id = $2",
    )
    .bind(auth.account_id)
    .bind(item.id)
    .bind(item.target_revision)
    .bind(target.get::<i64, _>("size"))
    .bind(target.get::<Option<Vec<u8>>, _>("content_hash"))
    .execute(&mut *tx)
    .await
    .map_err(|_| "database unavailable".to_string())?;

    append_event(
        &mut tx,
        auth.account_id,
        auth.device_id,
        item.id,
        Some(item.target_revision),
        "version",
        json!({ "rewind": true }),
    )
    .await
    .map_err(|_| "database unavailable".to_string())?;
    tx.commit()
        .await
        .map_err(|_| "database unavailable".to_string())?;
    Ok(true)
}
