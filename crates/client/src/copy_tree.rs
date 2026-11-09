//! Recursive Copy uses one bounded publication, never sequential visible creates.
use crate::{
    copy::{portable_component, prepare_file_copy},
    ApiClient, ClientError, FileDto, Result,
};
use base64::Engine;
use nntdrive_crypto::{Envelope, MasterKey};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

#[derive(Deserialize, Serialize)]
struct Snapshot {
    id: Uuid,
    parent_id: Option<Uuid>,
    name_enc: String,
    is_dir: bool,
    current_version: Option<Uuid>,
    size: i64,
}
fn invalid() -> ClientError {
    ClientError::Integrity("invalid copy tree or namespace".into())
}
fn comparison(name: &str) -> String {
    name.nfc()
        .collect::<String>()
        .to_lowercase()
        .nfc()
        .collect()
}
fn open_name(master: &MasterKey, id: Uuid, name: &str) -> Result<String> {
    if name.len() > 10924 {
        return Err(invalid());
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(name)
        .map_err(|_| invalid())?;
    let plain = master.open_name(id, &Envelope::from_bytes(&bytes)?)?;
    if !portable_component(&plain) {
        return Err(invalid());
    }
    Ok(plain)
}
#[derive(Deserialize, Serialize)]
struct NameSnapshot {
    id: Uuid,
    name_enc: String,
}
#[derive(Deserialize)]
struct Destination {
    files: Vec<NameSnapshot>,
}

async fn bounded_body(mut response: reqwest::Response, max: usize) -> Result<Vec<u8>> {
    if response.status().as_u16() == 404 {
        return Err(ClientError::NotFound);
    }
    if !response.status().is_success() {
        return Err(ClientError::Api {
            status: response.status().as_u16(),
            message: "folder copy request rejected".into(),
        });
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len() + chunk.len() > max {
            return Err(invalid());
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

impl ApiClient {
    /// Copy a live folder's current subtree atomically. Bounded to 256 nodes,
    /// depth 31, 8 MiB metadata and 16384 references. No retry after ambiguity.
    pub async fn copy_folder_checked(
        &self,
        master: &MasterKey,
        source: &FileDto,
        parent: Option<Uuid>,
    ) -> Result<Uuid> {
        tokio::time::timeout(
            std::time::Duration::from_secs(120),
            self.copy_folder_inner(master, source, parent),
        )
        .await
        .map_err(|_| {
            ClientError::Protocol("folder copy timed out; refresh before another attempt".into())
        })?
    }

    async fn copy_folder_inner(
        &self,
        master: &MasterKey,
        source: &FileDto,
        parent: Option<Uuid>,
    ) -> Result<Uuid> {
        if !source.is_dir {
            return Err(invalid());
        }
        open_name(master, source.id, &source.name_enc)?;
        let response = self
            .auth(
                self.http
                    .get(self.url(&format!("/files/{}/copy-tree-snapshot", source.id))),
            )
            .send()
            .await?;
        let bytes = bounded_body(response, 3 * 1024 * 1024).await?;
        let nodes: Vec<Snapshot> = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        if nodes.is_empty() || nodes.len() > 256 {
            return Err(invalid());
        }
        let index: BTreeMap<_, _> = nodes.iter().map(|n| (n.id, n)).collect();
        if index.len() != nodes.len() {
            return Err(invalid());
        }
        let root = index.get(&source.id).ok_or_else(invalid)?;
        if !root.is_dir
            || root.parent_id != source.parent_id
            || root.name_enc != source.name_enc
            || root.current_version != source.current_version
            || root.size != source.size
            || parent.is_some_and(|p| index.contains_key(&p))
        {
            return Err(invalid());
        }
        // Authenticate every name and reject malformed structure/collisions before
        // requesting manifests. Each parent must reach the selected root.
        let mut names = BTreeMap::new();
        let mut seen = BTreeSet::new();
        for n in &nodes {
            let name = open_name(master, n.id, &n.name_enc)?;
            if !seen.insert((n.parent_id, comparison(&name))) {
                return Err(invalid());
            }
            names.insert(n.id, name);
            let mut current = n.id;
            let mut visited = BTreeSet::new();
            while current != source.id {
                if visited.len() >= 31 || !visited.insert(current) {
                    return Err(invalid());
                }
                let p = index[&current]
                    .parent_id
                    .and_then(|p| index.get(&p))
                    .ok_or_else(invalid)?;
                if !p.is_dir {
                    return Err(invalid());
                }
                current = p.id;
            }
        }
        let mut request = self.http.get(self.url("/copy-tree-destination"));
        if let Some(parent) = parent {
            request = request.query(&[("parent_id", parent)]);
        }
        let response = self.auth(request).send().await?;
        let bytes = bounded_body(response, 4 * 1024 * 1024).await?;
        let siblings = serde_json::from_slice::<Destination>(&bytes)
            .map_err(|_| invalid())?
            .files;
        if siblings.len() > 4096 {
            return Err(invalid());
        }
        let mut seen = BTreeSet::new();
        for s in &siblings {
            let name = open_name(master, s.id, &s.name_enc)?;
            let key = comparison(&name);
            if key == comparison(&names[&source.id]) || !seen.insert(key) {
                return Err(invalid());
            }
        }
        let mut candidates = Vec::new();
        let mut copied_root = None;
        let mut total_bytes = 0;
        let mut total_refs = 0;
        for n in &nodes {
            let (id, revision, name, manifest, chunks) = if n.is_dir {
                let id = Uuid::new_v4();
                (
                    id,
                    None,
                    master.seal_name(id, &names[&n.id])?.to_bytes(),
                    None,
                    Vec::new(),
                )
            } else {
                let revision = n.current_version.ok_or_else(invalid)?;
                let response = self
                    .auth(
                        self.http
                            .get(self.url(&format!("/files/{}/manifest", n.id)))
                            .query(&[("revision", revision)]),
                    )
                    .send()
                    .await?;
                let actual = response
                    .headers()
                    .get("x-nntdrive-revision")
                    .and_then(|h| h.to_str().ok())
                    .and_then(|h| h.parse::<Uuid>().ok())
                    .ok_or_else(invalid)?;
                let sealed = bounded_body(response, 1024 * 1024).await?;
                if actual != revision || sealed.len() > 1024 * 1024 {
                    return Err(invalid());
                }
                let source_name = base64::engine::general_purpose::STANDARD
                    .decode(&n.name_enc)
                    .map_err(|_| invalid())?;
                let c = prepare_file_copy(master, n.id, revision, &source_name, &sealed)?;
                if n.size < 0 || c.size != n.size as u64 || c.chunk_ids.len() > 4096 {
                    return Err(invalid());
                }
                (
                    c.file_id,
                    Some(c.revision_id),
                    c.name_enc,
                    Some(c.sealed_manifest),
                    c.chunk_ids,
                )
            };
            total_bytes += name.len() + manifest.as_ref().map_or(0, Vec::len);
            total_refs += chunks.len();
            if total_bytes > 8 * 1024 * 1024 || total_refs > 16384 {
                return Err(invalid());
            }
            if n.id == source.id {
                copied_root = Some(id);
            }
            candidates.push(json!({"source_id":n.id,"id":id,"name_enc":crate::b64(&name),"revision_id":revision,"sealed_manifest":manifest.as_ref().map(|m|crate::b64(m)),"chunk_ids":chunks}));
        }
        let body = json!({"source":nodes,"parent_id":parent,"siblings":siblings.iter().map(|s|json!({"id":s.id,"name_enc":s.name_enc})).collect::<Vec<_>>(),"nodes":candidates});
        let bytes = serde_json::to_vec(&body).map_err(|_| invalid())?;
        if bytes.len() > 12 * 1024 * 1024 {
            return Err(invalid());
        }
        let response = self
            .auth(
                self.http
                    .post(self.url(&format!("/files/{}/copy-tree-checked", source.id))),
            )
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(bytes)
            .send()
            .await?;
        bounded_body(response, 1024).await?;
        copied_root.ok_or_else(invalid)
    }
}
