//! Bounded ciphertext-only recursive Copy. No node is visible before COMMIT.
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
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{Postgres, Row, Transaction};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

const MAX_NODES: usize = 256;
#[derive(Deserialize, Serialize, PartialEq, Eq)]
struct Snapshot {
    id: Uuid,
    parent_id: Option<Uuid>,
    name_enc: String,
    is_dir: bool,
    current_version: Option<Uuid>,
    size: i64,
}
#[derive(Deserialize)]
struct Candidate {
    source_id: Uuid,
    id: Uuid,
    name_enc: String,
    revision_id: Option<Uuid>,
    sealed_manifest: Option<String>,
    chunk_ids: Vec<Uuid>,
}
#[derive(Deserialize)]
pub struct CopyTree {
    source: Vec<Snapshot>,
    parent_id: Option<Uuid>,
    siblings: Vec<NameSnapshot>,
    nodes: Vec<Candidate>,
}
fn invalid() -> ApiError {
    ApiError::BadRequest("invalid or oversized copy tree".into())
}

// LIMIT is consumed directly (no sort/aggregate) so wide trees stop at the bound.
// Depth is bounded even for corrupt cyclic namespaces. Oversized names are not read.
async fn subtree(
    tx: &mut Transaction<'_, Postgres>,
    account: Uuid,
    root: Uuid,
) -> ApiResult<Vec<Snapshot>> {
    let rows = sqlx::query("WITH RECURSIVE tree AS (SELECT id,parent_id,is_dir,current_version,size,CASE WHEN octet_length(name_enc)<=8192 THEN name_enc END AS name_enc,0 AS depth FROM files WHERE account_id=$1 AND id=$2 AND NOT deleted UNION ALL SELECT f.id,f.parent_id,f.is_dir,f.current_version,f.size,CASE WHEN octet_length(f.name_enc)<=8192 THEN f.name_enc END,t.depth+1 FROM files f JOIN tree t ON f.parent_id=t.id WHERE f.account_id=$1 AND NOT f.deleted AND t.is_dir AND t.depth<32) SELECT * FROM tree LIMIT 257")
        .bind(account).bind(root).fetch_all(&mut **tx).await?;
    if rows.is_empty() {
        return Err(ApiError::NotFound);
    }
    if rows.len() > MAX_NODES {
        return Err(invalid());
    }
    rows.iter()
        .map(|r| {
            if r.get::<i32, _>("depth") >= 32 {
                return Err(invalid());
            }
            let name: Option<Vec<u8>> = r.get("name_enc");
            Ok(Snapshot {
                id: r.get("id"),
                parent_id: r.get("parent_id"),
                is_dir: r.get("is_dir"),
                current_version: r.get("current_version"),
                size: r.get("size"),
                name_enc: base64::engine::general_purpose::STANDARD
                    .encode(name.ok_or_else(invalid)?),
            })
        })
        .collect()
}

pub async fn snapshot(
    State(state): State<AppState>,
    auth: Auth,
    Path(root): Path<Uuid>,
) -> ApiResult<Json<Value>> {
    let mut tx = state.pool.begin().await?;
    let nodes = subtree(&mut tx, auth.account_id, root).await?;
    Ok(Json(json!(nodes)))
}

pub async fn destination_snapshot(
    State(state): State<AppState>,
    auth: Auth,
    axum::extract::Query(query): axum::extract::Query<crate::api::ListQuery>,
) -> ApiResult<Json<Value>> {
    let mut tx = state.pool.begin().await?;
    if let Some(parent) = query.parent_id {
        let dir: Option<bool> = sqlx::query_scalar(
            "SELECT is_dir FROM files WHERE account_id=$1 AND id=$2 AND NOT deleted",
        )
        .bind(auth.account_id)
        .bind(parent)
        .fetch_optional(&mut *tx)
        .await?;
        match dir {
            Some(true) => (),
            Some(false) => return Err(invalid()),
            None => return Err(ApiError::NotFound),
        }
    }
    let names = destination_names(&mut tx, auth.account_id, query.parent_id).await?;
    Ok(Json(
        json!({"files": names.into_iter().map(|(id,name)| json!({"id":id,"name_enc":base64::engine::general_purpose::STANDARD.encode(name)})).collect::<Vec<_>>()}),
    ))
}

async fn destination_names(
    tx: &mut Transaction<'_, Postgres>,
    account: Uuid,
    parent: Option<Uuid>,
) -> ApiResult<BTreeMap<Uuid, Vec<u8>>> {
    let rows = sqlx::query("SELECT id,CASE WHEN octet_length(name_enc)<=8192 THEN name_enc END AS name_enc FROM files WHERE account_id=$1 AND NOT deleted AND parent_id IS NOT DISTINCT FROM $2 LIMIT 4097")
        .bind(account).bind(parent).fetch_all(&mut **tx).await?;
    if rows.len() > 4096 {
        return Err(invalid());
    }
    let mut names = BTreeMap::new();
    let mut bytes = 0;
    for row in rows {
        let name = row
            .get::<Option<Vec<u8>>, _>("name_enc")
            .ok_or_else(invalid)?;
        bytes += name.len();
        if bytes > 2 * 1024 * 1024 {
            return Err(invalid());
        }
        names.insert(row.get("id"), name);
    }
    Ok(names)
}

pub async fn publish(
    State(state): State<AppState>,
    auth: Auth,
    Path(root): Path<Uuid>,
    Json(body): Json<CopyTree>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    if body.source.is_empty()
        || body.source.len() > MAX_NODES
        || body.nodes.len() != body.source.len()
        || body.siblings.len() > 4096
    {
        return Err(invalid());
    }
    let expected: BTreeMap<_, _> = body.source.iter().map(|n| (n.id, n)).collect();
    if expected.len() != body.source.len() {
        return Err(invalid());
    }
    let mut siblings = BTreeMap::new();
    for s in &body.siblings {
        let name = super::copy::decode(&s.name_enc, 8192)?;
        if siblings.insert(s.id, name).is_some() {
            return Err(invalid());
        }
    }
    let mut ids = BTreeSet::new();
    let mut revisions = BTreeSet::new();
    let mut prepared = BTreeMap::new();
    let mut bytes = 0usize;
    let mut references = 0usize;
    for n in &body.nodes {
        let source = expected.get(&n.source_id).ok_or_else(invalid)?;
        let name = super::copy::decode(&n.name_enc, 8192)?;
        let manifest = match (&n.sealed_manifest, n.revision_id, source.is_dir) {
            (None, None, true) if n.chunk_ids.is_empty() => None,
            (Some(m), Some(rev), false)
                if source.size >= 0
                    && source.size <= 1 << 44
                    && !body.source.iter().any(|s| s.current_version == Some(rev))
                    && revisions.insert(rev) =>
            {
                Some(super::copy::decode(m, 1024 * 1024)?)
            }
            _ => return Err(invalid()),
        };
        bytes += name.len() + manifest.as_ref().map_or(0, Vec::len);
        references += n.chunk_ids.len();
        if bytes > 8 * 1024 * 1024
            || references > 16384
            || n.chunk_ids.len() > 4096
            || expected.contains_key(&n.id)
            || !ids.insert(n.id)
            || prepared.insert(n.source_id, (n, name, manifest)).is_some()
        {
            return Err(invalid());
        }
    }
    let mut tx = state.pool.begin().await?;
    sqlx::query("SET LOCAL lock_timeout = '5s'")
        .execute(&mut *tx)
        .await?;
    sqlx::query("SET LOCAL statement_timeout = '15s'")
        .execute(&mut *tx)
        .await?;
    // Same global lock order as version commit, GC and all namespace writers.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(auth.account_id.to_string())
        .execute(&mut *tx)
        .await?;
    sqlx::query("SELECT id FROM accounts WHERE id=$1 FOR UPDATE")
        .bind(auth.account_id)
        .fetch_one(&mut *tx)
        .await?;
    let actual = subtree(&mut tx, auth.account_id, root).await?;
    let actual: BTreeMap<_, _> = actual.iter().map(|n| (n.id, n)).collect();
    if actual != expected {
        return Err(ApiError::Conflict(
            "source subtree changed; refresh before copying".into(),
        ));
    }
    if !actual[&root].is_dir {
        return Err(invalid());
    }
    if let Some(parent) = body.parent_id {
        if actual.contains_key(&parent) {
            return Err(invalid());
        }
        let dir: Option<bool> = sqlx::query_scalar(
            "SELECT is_dir FROM files WHERE account_id=$1 AND id=$2 AND NOT deleted",
        )
        .bind(auth.account_id)
        .bind(parent)
        .fetch_optional(&mut *tx)
        .await?;
        match dir {
            Some(true) => (),
            Some(false) => return Err(invalid()),
            None => return Err(ApiError::NotFound),
        }
    }
    let destination = destination_names(&mut tx, auth.account_id, body.parent_id).await?;
    if destination != siblings {
        return Err(ApiError::Conflict(
            "destination changed; refresh before copying".into(),
        ));
    }
    let reused:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM files WHERE id=ANY($1)) OR EXISTS(SELECT 1 FROM file_versions WHERE revision_id=ANY($2))").bind(ids.into_iter().collect::<Vec<_>>()).bind(revisions.into_iter().collect::<Vec<_>>()).fetch_one(&mut *tx).await?;
    if reused {
        return Err(ApiError::Conflict("copy identity unavailable".into()));
    }
    state.check_quota(auth.account_id, 0).await?;
    // Insert parents first; request ordering is never trusted.
    let mut pending: BTreeSet<Uuid> = expected.keys().copied().collect();
    let mut inserted = BTreeSet::new();
    while !pending.is_empty() {
        let source_id = *pending
            .iter()
            .find(|id| {
                **id == root
                    || expected[id]
                        .parent_id
                        .is_some_and(|p| inserted.contains(&p))
            })
            .ok_or_else(invalid)?;
        let source = expected[&source_id];
        let (n, name, manifest) = &prepared[&source_id];
        let parent = if source_id == root {
            body.parent_id
        } else {
            Some(prepared[&source.parent_id.ok_or_else(invalid)?].0.id)
        };
        sqlx::query("INSERT INTO files(id,account_id,parent_id,name_enc,is_dir,current_version,size) VALUES($1,$2,$3,$4,$5,$6,$7)").bind(n.id).bind(auth.account_id).bind(parent).bind(name).bind(source.is_dir).bind(n.revision_id).bind(source.size).execute(&mut *tx).await?;
        if let Some(manifest) = manifest {
            let version = Uuid::new_v4();
            sqlx::query("INSERT INTO file_versions(id,account_id,file_id,revision_id,device_id,size,manifest,references_complete) VALUES($1,$2,$3,$4,$5,$6,$7,TRUE)").bind(version).bind(auth.account_id).bind(n.id).bind(n.revision_id).bind(auth.device_id).bind(source.size).bind(manifest).execute(&mut *tx).await?;
            nntdrive_storage::store::Store::write_references(
                &mut tx,
                auth.account_id,
                version,
                &n.chunk_ids,
            )
            .await
            .map_err(|_| ApiError::BadRequest("invalid account chunk references".into()))?;
        }
        let kind = if source.is_dir { "create" } else { "version" };
        let payload = if source.is_dir {
            json!({"is_dir": true})
        } else {
            json!({})
        };
        sqlx::query("INSERT INTO sync_events(account_id,seq,device_id,file_id,revision_id,kind,payload) SELECT $1,COALESCE(MAX(seq),0)+1,$2,$3,$4,$5,$6 FROM sync_events WHERE account_id=$1").bind(auth.account_id).bind(auth.device_id).bind(n.id).bind(n.revision_id).bind(kind).bind(payload).execute(&mut *tx).await?;
        pending.remove(&source_id);
        inserted.insert(source_id);
    }
    tx.commit().await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({"id":prepared[&root].0.id})),
    ))
}
