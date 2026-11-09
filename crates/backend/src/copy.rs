//! Bounded, atomic same-account file Copy publication. Ciphertext remains opaque.
use crate::{
    api::NameSnapshot,
    auth::Auth,
    error::{ApiError, ApiResult},
    state::AppState,
};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use base64::Engine;
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use uuid::Uuid;

#[derive(Deserialize)]
pub struct CopyFile {
    pub source_revision: Uuid,
    pub source_parent_id: Option<Uuid>,
    pub source_name_enc: String,
    pub parent_id: Option<Uuid>,
    pub siblings: Vec<NameSnapshot>,
    pub id: Uuid,
    pub revision_id: Uuid,
    pub name_enc: String,
    pub sealed_manifest: String,
    pub size: i64,
    pub chunk_ids: Vec<Uuid>,
}
pub(super) fn decode(value: &str, max: usize) -> ApiResult<Vec<u8>> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value)
        .map_err(|_| ApiError::BadRequest("invalid ciphertext".into()))?;
    if bytes.len() < 42 || bytes.len() > max || bytes[0] != 1 {
        return Err(ApiError::BadRequest("invalid ciphertext envelope".into()));
    }
    Ok(bytes)
}

pub async fn publish(
    State(state): State<AppState>,
    auth: Auth,
    Path(source): Path<Uuid>,
    Json(body): Json<CopyFile>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    if body.siblings.len() > 4096
        || body.chunk_ids.len() > 4096
        || body.size < 0
        || body.size > 1 << 44
        || body.id == source
        || body.revision_id == body.source_revision
    {
        return Err(ApiError::BadRequest(
            "copy exceeds bounds or reuses identity".into(),
        ));
    }
    let name = decode(&body.name_enc, 8192)?;
    let source_name = decode(&body.source_name_enc, 8192)?;
    let manifest = decode(&body.sealed_manifest, 1024 * 1024)?;
    let mut expected = std::collections::BTreeMap::new();
    for entry in &body.siblings {
        let name = decode(&entry.name_enc, 8192)?;
        if expected.insert(entry.id, name).is_some() {
            return Err(ApiError::BadRequest("duplicate snapshot entry".into()));
        }
    }
    let mut tx = state.pool.begin().await?;
    // Global order: GC/version advisory lock BEFORE account row namespace lock.
    // GC can update the account's legacy-commit fence while holding its lock.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(auth.account_id.to_string())
        .execute(&mut *tx)
        .await?;
    sqlx::query("SELECT id FROM accounts WHERE id = $1 FOR UPDATE")
        .bind(auth.account_id)
        .fetch_one(&mut *tx)
        .await?;
    let row = sqlx::query("SELECT parent_id,name_enc,current_version,size,is_dir FROM files WHERE account_id=$1 AND id=$2 AND NOT deleted FOR UPDATE")
        .bind(auth.account_id).bind(source).fetch_optional(&mut *tx).await?.ok_or(ApiError::NotFound)?;
    if row.get::<bool, _>("is_dir") {
        return Err(ApiError::BadRequest("folder copy is not supported".into()));
    }
    if row.get::<Option<Uuid>, _>("parent_id") != body.source_parent_id
        || row.get::<Vec<u8>, _>("name_enc") != source_name
        || row.get::<Option<Uuid>, _>("current_version") != Some(body.source_revision)
        || row.get::<i64, _>("size") != body.size
    {
        return Err(ApiError::Conflict(
            "source changed; refresh before copying".into(),
        ));
    }
    if let Some(parent) = body.parent_id {
        let dir: Option<bool> = sqlx::query_scalar(
            "SELECT is_dir FROM files WHERE account_id=$1 AND id=$2 AND NOT deleted",
        )
        .bind(auth.account_id)
        .bind(parent)
        .fetch_optional(&mut *tx)
        .await?;
        match dir {
            Some(true) => (),
            Some(false) => return Err(ApiError::BadRequest("parent is not a folder".into())),
            None => return Err(ApiError::NotFound),
        }
    }
    let rows = sqlx::query("SELECT id,name_enc FROM files WHERE account_id=$1 AND NOT deleted AND parent_id IS NOT DISTINCT FROM $2 LIMIT 4097")
        .bind(auth.account_id).bind(body.parent_id).fetch_all(&mut *tx).await?;
    let actual: std::collections::BTreeMap<Uuid, Vec<u8>> = rows
        .iter()
        .map(|r| (r.get("id"), r.get("name_enc")))
        .collect();
    if actual != expected {
        return Err(ApiError::Conflict(
            "destination changed; refresh before copying".into(),
        ));
    }
    // Reusing IDs (including tombstoned ones) never overwrites existing data.
    let reused: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM files WHERE id=$1) OR EXISTS(SELECT 1 FROM file_versions WHERE revision_id=$2)")
        .bind(body.id).bind(body.revision_id).fetch_one(&mut *tx).await?;
    if reused {
        return Err(ApiError::Conflict("copy identity unavailable".into()));
    }
    state.check_quota_on(&mut *tx, auth.account_id, 0).await?;
    sqlx::query("INSERT INTO files(id,account_id,parent_id,name_enc,is_dir,current_version,size) VALUES($1,$2,$3,$4,FALSE,$5,$6)")
        .bind(body.id).bind(auth.account_id).bind(body.parent_id).bind(name).bind(body.revision_id).bind(body.size).execute(&mut *tx).await?;
    let version = Uuid::new_v4();
    sqlx::query("INSERT INTO file_versions(id,account_id,file_id,revision_id,device_id,size,manifest,references_complete) VALUES($1,$2,$3,$4,$5,$6,$7,TRUE)")
        .bind(version).bind(auth.account_id).bind(body.id).bind(body.revision_id).bind(auth.device_id).bind(body.size).bind(manifest).execute(&mut *tx).await?;
    nntdrive_storage::store::Store::write_references(
        &mut tx,
        auth.account_id,
        version,
        &body.chunk_ids,
    )
    .await
    .map_err(|_| ApiError::BadRequest("invalid account chunk references".into()))?;
    // Same event shape as a normal version commit; no source keys/names exposed.
    sqlx::query("INSERT INTO sync_events(account_id,seq,device_id,file_id,revision_id,kind,payload) SELECT $1,COALESCE(MAX(seq),0)+1,$2,$3,$4,'version','{}'::jsonb FROM sync_events WHERE account_id=$1")
        .bind(auth.account_id).bind(auth.device_id).bind(body.id).bind(body.revision_id).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({"id":body.id,"revision_id":body.revision_id})),
    ))
}
