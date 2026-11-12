//! File namespace, ciphertext chunk upload, article proxy and sync events.

use crate::auth::Auth;
use crate::error::{b64, sha256, unb64, ApiError, ApiResult};
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::{sse::Event, IntoResponse, Sse};
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use std::convert::Infallible;
use std::time::Duration;
use uuid::Uuid;

#[derive(Deserialize)]
pub struct ListQuery {
    pub parent_id: Option<Uuid>,
}

pub async fn list_files(
    State(state): State<AppState>,
    auth: Auth,
    Query(q): Query<ListQuery>,
) -> ApiResult<impl IntoResponse> {
    let rows = sqlx::query(
        "SELECT id, parent_id, name_enc, is_dir, size, favorite, revision, current_version,
                created_at, updated_at, deleted
         FROM files
         WHERE account_id = $1 AND deleted = FALSE
           AND (($2::uuid IS NULL AND parent_id IS NULL) OR parent_id = $2)
         ORDER BY is_dir DESC, name_enc",
    )
    .bind(auth.account_id)
    .bind(q.parent_id)
    .fetch_all(&state.pool)
    .await?;
    let files: Vec<Value> = rows
        .iter()
        .map(|r| {
            json!({
                "id": r.get::<Uuid, _>("id"),
                "parent_id": r.get::<Option<Uuid>, _>("parent_id"),
                "name_enc": b64(&r.get::<Vec<u8>, _>("name_enc")),
                "is_dir": r.get::<bool, _>("is_dir"),
                "size": r.get::<i64, _>("size"),
                "favorite": r.get::<bool, _>("favorite"),
                "revision": r.get::<i64, _>("revision"),
                "current_version": r.get::<Option<Uuid>, _>("current_version"),
                "created_at": r.get::<DateTime<Utc>, _>("created_at"),
                "updated_at": r.get::<DateTime<Utc>, _>("updated_at"),
            })
        })
        .collect();
    Ok(Json(json!({ "files": files })))
}

#[derive(Deserialize)]
pub struct CreateFile {
    pub id: Uuid,
    pub parent_id: Option<Uuid>,
    pub name_enc: String,
    #[serde(default)]
    pub is_dir: bool,
}

pub async fn create_file(
    State(state): State<AppState>,
    auth: Auth,
    Json(body): Json<CreateFile>,
) -> ApiResult<impl IntoResponse> {
    let name_enc = unb64(&body.name_enc)?;
    if name_enc.is_empty() || name_enc.len() > 8192 {
        return Err(ApiError::BadRequest(
            "name_enc must be 1..8192 bytes".into(),
        ));
    }
    let mut tx = state.pool.begin().await?;
    lock_namespace(&mut tx, auth.account_id).await?;
    if let Some(parent) = body.parent_id {
        let exists: Option<bool> = sqlx::query_scalar(
            "SELECT is_dir FROM files WHERE account_id = $1 AND id = $2 AND deleted = FALSE",
        )
        .bind(auth.account_id)
        .bind(parent)
        .fetch_optional(&mut *tx)
        .await?;
        match exists {
            Some(true) => {}
            Some(false) => return Err(ApiError::BadRequest("parent is not a folder".into())),
            None => return Err(ApiError::NotFound),
        }
    }
    sqlx::query(
        "INSERT INTO files (id, account_id, parent_id, name_enc, is_dir)
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(body.id)
    .bind(auth.account_id)
    .bind(body.parent_id)
    .bind(&name_enc)
    .bind(body.is_dir)
    .execute(&mut *tx)
    .await
    .map_err(|e| match e.as_database_error() {
        Some(db) if db.is_unique_violation() => ApiError::Conflict("file id already exists".into()),
        _ => ApiError::Db(e),
    })?;
    append_event(
        &mut tx,
        auth.account_id,
        auth.device_id,
        body.id,
        None,
        "create",
        json!({ "is_dir": body.is_dir }),
    )
    .await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(json!({ "id": body.id }))))
}

#[derive(Deserialize)]
pub struct MoveFile {
    pub parent_id: Option<Uuid>,
}

pub async fn move_file(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
    Json(body): Json<MoveFile>,
) -> ApiResult<impl IntoResponse> {
    move_impl(state, auth, id, body.parent_id, None).await
}

#[derive(Deserialize)]
pub struct CheckedMove {
    pub parent_id: Option<Uuid>,
    pub source_parent_id: Option<Uuid>,
    pub source_name_enc: String,
    pub siblings: Vec<NameSnapshot>,
}

pub async fn move_file_checked(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
    Json(body): Json<CheckedMove>,
) -> ApiResult<impl IntoResponse> {
    move_impl(state, auth, id, body.parent_id, Some(body)).await
}

async fn move_impl(
    state: AppState,
    auth: Auth,
    id: Uuid,
    parent_id: Option<Uuid>,
    guard: Option<CheckedMove>,
) -> ApiResult<Json<Value>> {
    let body = MoveFile { parent_id };
    let mut tx = state.pool.begin().await?;
    lock_namespace(&mut tx, auth.account_id).await?;
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM files WHERE account_id = $1 AND id = $2 AND deleted = FALSE)",
    )
    .bind(auth.account_id)
    .bind(id)
    .fetch_one(&mut *tx)
    .await?;
    if !exists {
        return Err(ApiError::NotFound);
    }
    ensure_not_fixed_root(&mut tx, auth.account_id, id).await?;
    if let Some(guard) = guard {
        if guard.siblings.len() > 4096 {
            return Err(ApiError::BadRequest(
                "folder snapshot exceeds 4096 entries".into(),
            ));
        }
        let source =
            sqlx::query("SELECT parent_id, name_enc FROM files WHERE account_id = $1 AND id = $2")
                .bind(auth.account_id)
                .bind(id)
                .fetch_one(&mut *tx)
                .await?;
        if source.get::<Option<Uuid>, _>("parent_id") != guard.source_parent_id
            || source.get::<Vec<u8>, _>("name_enc") != unb64(&guard.source_name_enc)?
        {
            return Err(ApiError::Conflict(
                "source changed; refresh and retry".into(),
            ));
        }
        let mut expected = std::collections::BTreeMap::new();
        for entry in guard.siblings {
            let sealed = unb64(&entry.name_enc)?;
            if sealed.is_empty()
                || sealed.len() > 8192
                || expected.insert(entry.id, sealed).is_some()
            {
                return Err(ApiError::BadRequest("invalid snapshot entry".into()));
            }
        }
        let rows = sqlx::query("SELECT id, name_enc FROM files WHERE account_id = $1 AND deleted = FALSE AND parent_id IS NOT DISTINCT FROM $2 LIMIT 4097")
            .bind(auth.account_id).bind(body.parent_id).fetch_all(&mut *tx).await?;
        let actual: std::collections::BTreeMap<Uuid, Vec<u8>> = rows
            .iter()
            .map(|r| (r.get("id"), r.get("name_enc")))
            .collect();
        if actual != expected {
            return Err(ApiError::Conflict(
                "destination changed; refresh and retry".into(),
            ));
        }
    }
    if let Some(parent) = body.parent_id {
        if parent == id {
            return Err(ApiError::BadRequest(
                "a folder cannot contain itself".into(),
            ));
        }
        let is_dir: Option<bool> = sqlx::query_scalar(
            "SELECT is_dir FROM files WHERE account_id = $1 AND id = $2 AND deleted = FALSE",
        )
        .bind(auth.account_id)
        .bind(parent)
        .fetch_optional(&mut *tx)
        .await?;
        match is_dir {
            Some(true) => {}
            Some(false) => return Err(ApiError::BadRequest("parent is not a folder".into())),
            None => return Err(ApiError::NotFound),
        }
        // Reject cycles using a recursive ancestor walk.
        let cycle: Option<i32> = sqlx::query_scalar(
            "WITH RECURSIVE ancestors AS (
                 SELECT id, parent_id FROM files WHERE account_id = $1 AND id = $2
                 UNION ALL
                 SELECT f.id, f.parent_id FROM files f
                 JOIN ancestors a ON f.id = a.parent_id
                 WHERE f.account_id = $1
             )
             SELECT 1 FROM ancestors WHERE id = $3 LIMIT 1",
        )
        .bind(auth.account_id)
        .bind(parent)
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?;
        if cycle.is_some() {
            return Err(ApiError::BadRequest("move would create a cycle".into()));
        }
    }
    sqlx::query(
        "UPDATE files SET parent_id = $3, updated_at = now(), revision = revision + 1
         WHERE account_id = $1 AND id = $2",
    )
    .bind(auth.account_id)
    .bind(id)
    .bind(body.parent_id)
    .execute(&mut *tx)
    .await?;
    append_event(
        &mut tx,
        auth.account_id,
        auth.device_id,
        id,
        None,
        "move",
        json!({}),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(json!({ "status": "moved" })))
}

// All namespace writers take the account row lock before reading or changing
// names/membership. This also serializes older unconditional API writers.
pub(crate) async fn lock_namespace(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: Uuid,
) -> ApiResult<()> {
    // Match version commits and GC: advisory lock first, then account row.
    // append_event also takes this advisory lock; reversing the order can
    // deadlock guarded Copy/GC against a namespace writer.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(account_id.to_string())
        .execute(&mut **tx)
        .await?;
    sqlx::query("SELECT id FROM accounts WHERE id = $1 FOR UPDATE")
        .bind(account_id)
        .fetch_one(&mut **tx)
        .await?;
    Ok(())
}

/// Fixed account roots are structural: no client may rename, move or delete
/// them through the normal file APIs. Favourite changes stay allowed.
async fn ensure_not_fixed_root(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: Uuid,
    id: Uuid,
) -> ApiResult<()> {
    let root: Option<String> =
        sqlx::query_scalar("SELECT kind FROM account_roots WHERE account_id = $1 AND node_id = $2")
            .bind(account_id)
            .bind(id)
            .fetch_optional(&mut **tx)
            .await?;
    match root {
        Some(_) => Err(ApiError::Conflict(
            "fixed account root cannot be renamed, moved or deleted".into(),
        )),
        None => Ok(()),
    }
}

#[derive(Deserialize)]
pub struct NameSnapshot {
    pub id: Uuid,
    pub name_enc: String,
}

#[derive(Deserialize)]
pub struct RenameFile {
    pub parent_id: Option<Uuid>,
    pub name_enc: String,
    pub siblings: Vec<NameSnapshot>,
}

/// Compare the complete opaque namespace checked by the client, then rename
/// under the same account lock. No deterministic name tag or plaintext is added.
/// A dedicated endpoint fails closed against servers predating this contract.
pub async fn rename_file(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
    Json(body): Json<RenameFile>,
) -> ApiResult<impl IntoResponse> {
    let name = unb64(&body.name_enc)?;
    if name.is_empty() || name.len() > 8192 {
        return Err(ApiError::BadRequest("invalid name".into()));
    }
    if body.siblings.len() > 4096 {
        return Err(ApiError::BadRequest(
            "folder snapshot exceeds 4096 entries".into(),
        ));
    }
    let mut expected = std::collections::BTreeMap::new();
    for entry in &body.siblings {
        let sealed = unb64(&entry.name_enc)?;
        if sealed.is_empty() || sealed.len() > 8192 {
            return Err(ApiError::BadRequest("invalid snapshot name".into()));
        }
        if expected.insert(entry.id, sealed).is_some() {
            return Err(ApiError::BadRequest("duplicate snapshot entry".into()));
        }
    }
    let mut tx = state.pool.begin().await?;
    lock_namespace(&mut tx, auth.account_id).await?;
    let parent: Option<Option<Uuid>> = sqlx::query_scalar(
        "SELECT parent_id FROM files WHERE account_id = $1 AND id = $2 AND deleted = FALSE",
    )
    .bind(auth.account_id)
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let parent = parent.ok_or(ApiError::NotFound)?;
    ensure_not_fixed_root(&mut tx, auth.account_id, id).await?;
    if parent != body.parent_id {
        return Err(ApiError::Conflict(
            "folder changed; refresh and retry".into(),
        ));
    }
    let rows = sqlx::query(
        "SELECT id, name_enc FROM files WHERE account_id = $1 AND deleted = FALSE
         AND parent_id IS NOT DISTINCT FROM $2 LIMIT 4097",
    )
    .bind(auth.account_id)
    .bind(parent)
    .fetch_all(&mut *tx)
    .await?;
    let actual: std::collections::BTreeMap<Uuid, Vec<u8>> = rows
        .iter()
        .map(|row| (row.get("id"), row.get("name_enc")))
        .collect();
    if actual != expected {
        return Err(ApiError::Conflict(
            "folder changed; refresh and retry".into(),
        ));
    }
    sqlx::query(
        "UPDATE files SET name_enc = $3, revision = revision + 1, updated_at = now()
                 WHERE account_id = $1 AND id = $2",
    )
    .bind(auth.account_id)
    .bind(id)
    .bind(name)
    .execute(&mut *tx)
    .await?;
    append_event(
        &mut tx,
        auth.account_id,
        auth.device_id,
        id,
        None,
        "rename",
        json!({}),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(json!({ "status": "renamed" })))
}

#[derive(Deserialize)]
pub struct PatchFile {
    pub name_enc: Option<String>,
    pub favorite: Option<bool>,
    pub deleted: Option<bool>,
}

pub async fn patch_file(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
    Json(body): Json<PatchFile>,
) -> ApiResult<impl IntoResponse> {
    ensure_file(&state, auth.account_id, id).await?;
    let name_enc = match &body.name_enc {
        Some(s) => {
            let v = unb64(s)?;
            if v.is_empty() || v.len() > 8192 {
                return Err(ApiError::BadRequest("invalid name".into()));
            }
            Some(v)
        }
        None => None,
    };
    let mut tx = state.pool.begin().await?;
    lock_namespace(&mut tx, auth.account_id).await?;
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM files WHERE account_id = $1 AND id = $2 AND deleted = FALSE)",
    )
    .bind(auth.account_id)
    .bind(id)
    .fetch_one(&mut *tx)
    .await?;
    if !exists {
        return Err(ApiError::NotFound);
    }
    if name_enc.is_some() || body.deleted == Some(true) {
        ensure_not_fixed_root(&mut tx, auth.account_id, id).await?;
    }
    if let Some(name) = &name_enc {
        sqlx::query(
            "UPDATE files SET name_enc = $3, updated_at = now(), revision = revision + 1
             WHERE account_id = $1 AND id = $2",
        )
        .bind(auth.account_id)
        .bind(id)
        .bind(name)
        .execute(&mut *tx)
        .await?;
    }
    if let Some(fav) = body.favorite {
        sqlx::query(
            "UPDATE files SET favorite = $3, updated_at = now() WHERE account_id = $1 AND id = $2",
        )
        .bind(auth.account_id)
        .bind(id)
        .bind(fav)
        .execute(&mut *tx)
        .await?;
    }
    if body.deleted == Some(true) {
        sqlx::query(
            "UPDATE files SET deleted = TRUE, updated_at = now(), revision = revision + 1
             WHERE account_id = $1 AND id = $2",
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
            "delete",
            json!({}),
        )
        .await?;
    }
    tx.commit().await?;
    Ok(Json(json!({ "status": "updated" })))
}

#[derive(Deserialize)]
pub struct CommitVersion {
    pub revision_id: Uuid,
    pub parent_revision: Option<Uuid>,
    pub base_revision: Option<Uuid>,
    pub size: i64,
    pub sealed_manifest: String,
    /// Omitted by legacy clients; never interpret omission as an empty file.
    pub chunk_ids: Option<Vec<Uuid>>,
}

pub async fn commit_version(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
    Json(body): Json<CommitVersion>,
) -> ApiResult<impl IntoResponse> {
    let file = load_file(&state, auth.account_id, id).await?;
    if file.0 {
        return Err(ApiError::BadRequest(
            "cannot store content for a folder".into(),
        ));
    }
    if body.size < 0 || body.size > 1 << 44 {
        return Err(ApiError::BadRequest("invalid size".into()));
    }
    if body.base_revision != file.1 && body.base_revision.is_some() {
        return Err(ApiError::Conflict(
            "file changed since the edit started".into(),
        ));
    }
    let sealed = unb64(&body.sealed_manifest)?;
    if sealed.is_empty() || sealed.len() > 16 * 1024 * 1024 {
        return Err(ApiError::BadRequest("invalid sealed manifest size".into()));
    }
    if sealed[0] != 1 {
        return Err(ApiError::BadRequest(
            "unsupported manifest envelope version".into(),
        ));
    }
    // Minimal structural envelope check; content remains opaque.
    if sealed.len() < 42 {
        return Err(ApiError::BadRequest("truncated sealed manifest".into()));
    }
    state
        .check_quota(auth.account_id, body.size.max(0) as u64)
        .await?;
    let manifest = nntdrive_storage::FileManifest {
        version: nntdrive_storage::MANIFEST_VERSION,
        file_id: id,
        revision_id: body.revision_id,
        size: body.size as u64,
        content_hash: String::new(),
        created_at: Utc::now(),
        chunks: Vec::new(),
    };
    // Opaque API manifests use only the identity/size/timestamp header here;
    // references come from the explicit client declaration, never this dummy
    // empty chunk list. Omission must stay incomplete for legacy compatibility.
    state
        .store
        .insert_version_with_references(
            auth.account_id,
            id,
            &manifest,
            &sealed,
            auth.device_id,
            body.parent_revision,
            body.chunk_ids.as_deref(),
        )
        .await
        .map_err(reference_error)?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "revision_id": body.revision_id })),
    ))
}

fn reference_error(error: nntdrive_storage::StoreError) -> ApiError {
    match error {
        nntdrive_storage::StoreError::NotFound => ApiError::NotFound,
        nntdrive_storage::StoreError::Invalid(reason) => ApiError::BadRequest(reason),
        other => ApiError::Store(other),
    }
}

#[derive(Deserialize)]
pub struct BackfillPage {
    pub after: Option<Uuid>,
}

/// Includes historical/conflict/tombstoned versions, not only the current tree.
pub async fn incomplete_references(
    State(state): State<AppState>,
    auth: Auth,
    Query(q): Query<BackfillPage>,
) -> ApiResult<impl IntoResponse> {
    let rows = sqlx::query("SELECT id, file_id, revision_id FROM file_versions WHERE account_id = $1 AND NOT references_complete AND ($2::uuid IS NULL OR id > $2) ORDER BY id LIMIT 200")
        .bind(auth.account_id).bind(q.after).fetch_all(&state.pool).await?;
    let versions: Vec<Value> = rows.iter().map(|r| json!({"id":r.get::<Uuid,_>("id"),"file_id":r.get::<Uuid,_>("file_id"),"revision_id":r.get::<Uuid,_>("revision_id")})).collect();
    let next = if rows.len() == 200 {
        rows.last().map(|r| r.get::<Uuid, _>("id"))
    } else {
        None
    };
    Ok(Json(json!({"versions":versions,"next":next})))
}

#[derive(Deserialize)]
pub struct BackfillReferences {
    pub chunk_ids: Vec<Uuid>,
}

pub async fn backfill_references(
    State(state): State<AppState>,
    auth: Auth,
    Path((file_id, revision_id)): Path<(Uuid, Uuid)>,
    Json(body): Json<BackfillReferences>,
) -> ApiResult<impl IntoResponse> {
    state
        .store
        .backfill_references(auth.account_id, file_id, revision_id, &body.chunk_ids)
        .await
        .map_err(reference_error)?;
    Ok(Json(json!({ "references_complete": true })))
}

pub async fn list_versions(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
) -> ApiResult<impl IntoResponse> {
    ensure_file(&state, auth.account_id, id).await?;
    let rows = sqlx::query(
        "SELECT revision_id, parent_revision, size, created_at, deleted
         FROM file_versions WHERE account_id = $1 AND file_id = $2
         ORDER BY created_at DESC LIMIT 200",
    )
    .bind(auth.account_id)
    .bind(id)
    .fetch_all(&state.pool)
    .await?;
    let versions: Vec<Value> = rows
        .iter()
        .map(|r| {
            json!({
                "revision_id": r.get::<Uuid, _>("revision_id"),
                "parent_revision": r.get::<Option<Uuid>, _>("parent_revision"),
                "size": r.get::<i64, _>("size"),
                "created_at": r.get::<DateTime<Utc>, _>("created_at"),
                "deleted": r.get::<bool, _>("deleted"),
            })
        })
        .collect();
    Ok(Json(json!({ "versions": versions })))
}

#[derive(Deserialize)]
pub struct RevisionQuery {
    pub revision: Option<Uuid>,
}

pub async fn get_manifest(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
    Query(q): Query<RevisionQuery>,
) -> ApiResult<impl IntoResponse> {
    // Exact revisions remain readable for authenticated backfill/restore even
    // after logical namespace deletion; latest-tree reads still hide tombstones.
    if q.revision.is_none() {
        ensure_file(&state, auth.account_id, id).await?;
    }
    let version = state.store.version(auth.account_id, id, q.revision).await?;
    let mut resp = (StatusCode::OK, version.manifest).into_response();
    resp.headers_mut().insert(
        "x-nntdrive-revision",
        version.revision_id.to_string().parse().unwrap(),
    );
    Ok(resp)
}

#[derive(Deserialize)]
pub struct ChunkLookup {
    pub hash: String,
    pub len: u64,
}

/// Returns the article locations for one chunk so an authenticated client can
/// reconstruct it (directly from Usenet or through the article proxy).
pub async fn get_chunk(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
) -> ApiResult<impl IntoResponse> {
    let (chunk, stripes) = state.store.load_chunk(auth.account_id, id).await?;
    let compression = chunk.compression as u8;
    let mut stripe_json = Vec::with_capacity(stripes.len());
    for (stripe, shards) in stripes {
        let mut shard_json = Vec::with_capacity(shards.len());
        for s in shards {
            shard_json.push(json!({
                "index": s.shard_index,
                "message_id": s.message_id,
                "sha256": s.sha256,
                "size": s.size,
                "status": s.status,
            }));
        }
        stripe_json.push(json!({
            "id": stripe.id,
            "index": stripe.stripe_index,
            "data_shards": stripe.data_shards,
            "parity_shards": stripe.parity_shards,
            "shard_len": stripe.shard_len,
            "ciphertext_len": stripe.ciphertext_len,
            "shards": shard_json,
        }));
    }
    Ok(Json(json!({
        "chunk": {
            "id": chunk.id,
            "plaintext_len": chunk.plaintext_len,
            "ciphertext_len": chunk.ciphertext_len,
            "compression": compression,
        },
        "stripes": stripe_json,
    })))
}

pub async fn lookup_chunk(
    State(state): State<AppState>,
    auth: Auth,
    Query(q): Query<ChunkLookup>,
) -> ApiResult<impl IntoResponse> {
    let hash =
        hex_decode(&q.hash).ok_or_else(|| ApiError::BadRequest("hash must be hex".into()))?;
    if hash.len() != 32 {
        return Err(ApiError::BadRequest("hash must be 32 bytes".into()));
    }
    match state
        .store
        .find_chunk(auth.account_id, &hash, q.len)
        .await?
    {
        Some(chunk) => {
            let entry = state
                .store
                .chunk_entry(auth.account_id, &chunk, 0, 0)
                .await?;
            Ok((StatusCode::OK, Json(json!({ "chunk": entry }))).into_response())
        }
        None => Ok((StatusCode::NOT_FOUND, Json(json!({ "error": "not_found" }))).into_response()),
    }
}

#[derive(Deserialize)]
pub struct PublishChunk {
    pub chunk_id: Uuid,
    pub index: u32,
    pub offset: u64,
    pub plaintext_hash: String,
    pub plaintext_len: u64,
    pub compression: u8,
    pub ciphertext: String,
}

/// Accepts one client-encrypted chunk. The backend erasure-codes and posts the
/// ciphertext; it has no key and no plaintext.
pub async fn publish_chunk(
    State(state): State<AppState>,
    auth: Auth,
    Json(body): Json<PublishChunk>,
) -> ApiResult<impl IntoResponse> {
    let hash = hex_decode(&body.plaintext_hash)
        .ok_or_else(|| ApiError::BadRequest("plaintext_hash must be hex".into()))?;
    if hash.len() != 32 {
        return Err(ApiError::BadRequest(
            "plaintext_hash must be 32 bytes".into(),
        ));
    }
    if body.plaintext_len == 0 || body.plaintext_len > 64 * 1024 * 1024 {
        return Err(ApiError::BadRequest("invalid chunk length".into()));
    }
    let ciphertext = unb64(&body.ciphertext)?;
    if ciphertext.is_empty() || ciphertext.len() > 96 * 1024 * 1024 {
        return Err(ApiError::BadRequest("invalid ciphertext".into()));
    }
    if nntdrive_storage::Compression::from_u8(body.compression).is_none() {
        return Err(ApiError::BadRequest("unknown compression codec".into()));
    }
    state
        .check_quota(auth.account_id, body.plaintext_len)
        .await?;
    let prepared = nntdrive_storage::PreparedChunk {
        id: body.chunk_id,
        index: body.index,
        offset: body.offset,
        plaintext_len: body.plaintext_len,
        plaintext_hash: hash,
        ciphertext_len: ciphertext.len() as u64,
        compression: nntdrive_storage::Compression::from_u8(body.compression).unwrap(),
        ciphertext,
    };
    let (entry, stats) = state
        .storage
        .publish_prepared(auth.account_id, &prepared)
        .await?;
    Ok(Json(json!({ "chunk": entry, "stats": stats })))
}

pub async fn get_article(
    State(state): State<AppState>,
    auth: Auth,
    Path(message_id): Path<String>,
) -> ApiResult<impl IntoResponse> {
    if message_id.len() > 512 {
        return Err(ApiError::BadRequest("invalid message id".into()));
    }
    // Authorization is resolved from the database before touching the cache or
    // network, so one tenant can never read another tenant's article.
    let shard = state
        .store
        .find_article(auth.account_id, &message_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let data = if let Some(cached) = state.cache.get(&message_id).await {
        cached
    } else {
        let fetched = state.storage.nntp().fetch(&message_id).await?;
        if hex(&sha256(&fetched)) != shard.sha256 {
            return Err(ApiError::Storage(
                nntdrive_storage::StorageError::Integrity(
                    "article hash does not match metadata".into(),
                ),
            ));
        }
        let _ = state.cache.put(&message_id, &fetched).await;
        fetched
    };
    let mut resp = (StatusCode::OK, data).into_response();
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        "application/octet-stream".parse().unwrap(),
    );
    resp.headers_mut().insert(
        header::CACHE_CONTROL,
        "private, max-age=31536000, immutable".parse().unwrap(),
    );
    Ok(resp)
}

#[derive(Deserialize)]
pub struct SinceQuery {
    #[serde(default)]
    pub since: i64,
}

pub async fn list_events(
    State(state): State<AppState>,
    auth: Auth,
    Query(q): Query<SinceQuery>,
) -> ApiResult<impl IntoResponse> {
    let events = fetch_events(&state, auth.account_id, q.since, 500).await?;
    Ok(Json(json!({ "events": events })))
}

// Poll and authorization lease are short even for idle or backpressured bodies.
// See docs/SECURITY.md for in-flight frames and the database deadline.
const SSE_AUTH_INTERVAL: Duration = Duration::from_secs(2);

pub async fn stream_events(
    State(state): State<AppState>,
    auth: Auth,
    Query(q): Query<SinceQuery>,
) -> Sse<impl tokio_stream::Stream<Item = Result<Event, Infallible>>> {
    let stream = async_stream::stream! {
        let mut last = q.since;
        let mut idle = 0u32;
        loop {
            let mut checked_at = tokio::time::Instant::now();
            let batch = tokio::time::timeout(SSE_AUTH_INTERVAL, async {
                auth.revalidate(&state).await?;
                fetch_events(&state, auth.account_id, last, 200).await
            }).await;
            // Invalid credentials, database errors and deadlines all fail closed.
            // Do not send database diagnostics or credential details over SSE.
            let Ok(Ok(events)) = batch else { return };
            for e in events {
                // A suspended body may resume long after this batch was fetched.
                // Never drain an indefinitely stale authorization snapshot.
                if checked_at.elapsed() >= SSE_AUTH_INTERVAL {
                    checked_at = tokio::time::Instant::now();
                    if !matches!(tokio::time::timeout(SSE_AUTH_INTERVAL, auth.revalidate(&state)).await, Ok(Ok(()))) {
                        return;
                    }
                }
                if let Some(seq) = e.get("seq").and_then(|s| s.as_i64()) {
                    last = last.max(seq);
                }
                yield Ok(Event::default().event("change").data(e.to_string()));
                idle = 0;
            }
            idle += 1;
            if idle % 15 == 0 {
                yield Ok(Event::default().comment("keepalive"));
            }
            // Count processing time toward the poll bound rather than adding
            // another full interval after a slow batch.
            tokio::time::sleep_until(checked_at + SSE_AUTH_INTERVAL).await;
        }
    };
    Sse::new(stream).keep_alive(axum::response::sse::KeepAlive::default())
}

async fn fetch_events(
    state: &AppState,
    account_id: Uuid,
    since: i64,
    limit: i64,
) -> ApiResult<Vec<Value>> {
    let rows = sqlx::query(
        "SELECT seq, file_id, revision_id, kind, device_id, payload, created_at
         FROM sync_events WHERE account_id = $1 AND seq > $2
         ORDER BY seq LIMIT $3",
    )
    .bind(account_id)
    .bind(since)
    .bind(limit)
    .fetch_all(&state.pool)
    .await?;
    Ok(rows
        .iter()
        .map(|r| {
            json!({
                "seq": r.get::<i64, _>("seq"),
                "file_id": r.get::<Option<Uuid>, _>("file_id"),
                "revision_id": r.get::<Option<Uuid>, _>("revision_id"),
                "device_id": r.get::<Option<Uuid>, _>("device_id"),
                "kind": r.get::<String, _>("kind"),
                "payload": r.get::<Value, _>("payload"),
                "created_at": r.get::<DateTime<Utc>, _>("created_at"),
            })
        })
        .collect())
}

pub(crate) async fn append_event(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: Uuid,
    device_id: Option<Uuid>,
    file_id: Uuid,
    revision_id: Option<Uuid>,
    kind: &str,
    payload: Value,
) -> ApiResult<()> {
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(account_id.to_string())
        .execute(&mut **tx)
        .await?;
    let seq: i64 = sqlx::query_scalar(
        "SELECT COALESCE(MAX(seq), 0) + 1 FROM sync_events WHERE account_id = $1",
    )
    .bind(account_id)
    .fetch_one(&mut **tx)
    .await?;
    sqlx::query(
        "INSERT INTO sync_events (account_id, seq, device_id, file_id, revision_id, kind, payload)
         VALUES ($1, $2, $3, $4, $5, $6, $7)",
    )
    .bind(account_id)
    .bind(seq)
    .bind(device_id)
    .bind(file_id)
    .bind(revision_id)
    .bind(kind)
    .bind(payload)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn ensure_file(state: &AppState, account_id: Uuid, id: Uuid) -> ApiResult<()> {
    let exists: Option<Uuid> = sqlx::query_scalar(
        "SELECT id FROM files WHERE account_id = $1 AND id = $2 AND deleted = FALSE",
    )
    .bind(account_id)
    .bind(id)
    .fetch_optional(&state.pool)
    .await?;
    exists.map(|_| ()).ok_or(ApiError::NotFound)
}

async fn load_file(
    state: &AppState,
    account_id: Uuid,
    id: Uuid,
) -> ApiResult<(bool, Option<Uuid>)> {
    let row = sqlx::query(
        "SELECT is_dir, current_version FROM files WHERE account_id = $1 AND id = $2 AND deleted = FALSE",
    )
    .bind(account_id)
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(ApiError::NotFound)?;
    Ok((row.get("is_dir"), row.get("current_version")))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let bytes = s.as_bytes();
    for pair in bytes.chunks(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
}

pub async fn health(State(state): State<AppState>) -> impl IntoResponse {
    match sqlx::query_scalar::<_, i32>("SELECT 1")
        .fetch_one(&state.pool)
        .await
    {
        Ok(_) => (StatusCode::OK, Json(json!({ "status": "ok" }))),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "status": "degraded" })),
        ),
    }
}
