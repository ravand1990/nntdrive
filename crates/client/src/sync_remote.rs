//! HTTP implementation of the synchronization `Remote` interface.
//!
//! A sync root is a remote folder node. Paths below it are reconstructed by
//! walking the encrypted tree and decrypting names locally; the server only
//! sees opaque node ids and sealed name blobs.

use crate::{download_file, upload_file, ApiClient, ClientError};
use nntdrive_crypto::{Envelope, MasterKey};
use nntdrive_storage::manifest::FileManifest;
use nntdrive_sync::{Remote, RemoteEntry, SyncError};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use uuid::Uuid;

#[derive(Debug, Clone)]
struct Node {
    id: Uuid,
    revision: Option<Uuid>,
    is_dir: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CachedHash {
    revision: String,
    hash: String,
}

/// Number of files/directories we are willing to walk in one snapshot. Guards
/// against a pathological or malicious remote tree.
const MAX_NODES: usize = 100_000;

pub struct HttpRemote {
    api: ApiClient,
    master: MasterKey,
    root_id: Uuid,
    nodes: HashMap<String, Node>,
    cache_path: Option<PathBuf>,
    hashes: HashMap<String, CachedHash>,
}

impl HttpRemote {
    pub fn new(api: ApiClient, master: MasterKey, root_id: Uuid) -> Self {
        Self {
            api,
            master,
            root_id,
            nodes: HashMap::new(),
            cache_path: None,
            hashes: HashMap::new(),
        }
    }

    /// Enables a small on-disk cache of remote content hashes. Without it,
    /// remote entries have no hash and renames are detected as delete+recreate.
    pub fn with_cache(
        api: ApiClient,
        master: MasterKey,
        root_id: Uuid,
        cache_path: impl Into<PathBuf>,
    ) -> Self {
        let mut this = Self::new(api, master, root_id);
        this.cache_path = Some(cache_path.into());
        this
    }

    async fn load_hash_cache(&mut self) {
        let Some(path) = &self.cache_path else { return };
        if let Ok(data) = tokio::fs::read(path).await {
            match serde_json::from_slice::<HashMap<String, CachedHash>>(&data) {
                Ok(cache) => self.hashes = cache,
                Err(e) => tracing::warn!(error = %e, "ignoring malformed sync hash cache"),
            }
        }
    }

    async fn save_hash_cache(&self, cache: &HashMap<String, CachedHash>) {
        let Some(path) = &self.cache_path else { return };
        if let Some(parent) = path.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        let tmp = path.with_extension("tmp");
        if let Ok(data) = serde_json::to_vec(cache) {
            if tokio::fs::write(&tmp, data).await.is_ok() {
                let _ = tokio::fs::rename(&tmp, path).await;
            }
        }
    }

    async fn content_hash(&self, id: Uuid, revision: Uuid) -> Option<String> {
        let (sealed, rev) = self.api.manifest(id, Some(revision)).await.ok()?;
        let envelope = Envelope::from_bytes(&sealed).ok()?;
        let plain = self.master.open_manifest(id, rev, &envelope).ok()?;
        let manifest = FileManifest::from_bytes(&plain).ok()?;
        Some(manifest.content_hash)
    }

    fn remote_error(e: impl std::fmt::Display) -> SyncError {
        SyncError::Remote(e.to_string())
    }

    fn child_path(parent: &str, name: &str) -> String {
        if parent.is_empty() {
            name.to_string()
        } else {
            format!("{parent}/{name}")
        }
    }

    fn parent_path(path: &str) -> &str {
        path.rsplit_once('/').map(|(p, _)| p).unwrap_or("")
    }

    fn base_name(path: &str) -> &str {
        path.rsplit_once('/').map(|(_, n)| n).unwrap_or(path)
    }

    fn validate_name(name: &str) -> Result<(), SyncError> {
        if name.is_empty()
            || name == "."
            || name == ".."
            || name.contains('/')
            || name.contains('\\')
            || name.contains('\0')
        {
            return Err(SyncError::Remote(format!(
                "unsafe remote node name {name:?}"
            )));
        }
        Ok(())
    }

    async fn snapshot_tree(&mut self) -> Result<Vec<RemoteEntry>, SyncError> {
        self.load_hash_cache().await;
        self.nodes.clear();
        self.nodes.insert(
            String::new(),
            Node {
                id: self.root_id,
                revision: None,
                is_dir: true,
            },
        );
        let mut entries = Vec::new();
        let mut stack = vec![(String::new(), self.root_id, 0usize)];
        let mut new_cache: HashMap<String, CachedHash> = HashMap::new();
        let mut hash_budget = 2000usize;
        while let Some((parent_path, parent_id, depth)) = stack.pop() {
            if depth > 128 {
                return Err(Self::remote_error("remote tree is too deep"));
            }
            let children = self
                .api
                .list_files(Some(parent_id))
                .await
                .map_err(Self::remote_error)?;
            for file in children {
                let name = self
                    .master
                    .open_name(
                        file.id,
                        &nntdrive_crypto::Envelope::from_bytes(
                            &base64_decode(&file.name_enc).map_err(Self::remote_error)?,
                        )
                        .map_err(Self::remote_error)?,
                    )
                    .map_err(|_| {
                        Self::remote_error(format!(
                            "cannot decrypt the name of node {} (different key epoch?)",
                            file.id
                        ))
                    })?;
                Self::validate_name(&name)?;
                let path = Self::child_path(&parent_path, &name);
                if self.nodes.len() >= MAX_NODES {
                    return Err(Self::remote_error("remote folder contains too many nodes"));
                }
                self.nodes.insert(
                    path.clone(),
                    Node {
                        id: file.id,
                        revision: file.current_version,
                        is_dir: file.is_dir,
                    },
                );
                let mut content_hash = None;
                if !file.is_dir {
                    if let Some(rev) = file.current_version {
                        let cached = self
                            .hashes
                            .get(&path)
                            .filter(|c| c.revision == rev.to_string())
                            .map(|c| c.hash.clone());
                        if let Some(hash) = cached {
                            new_cache.insert(
                                path.clone(),
                                CachedHash {
                                    revision: rev.to_string(),
                                    hash: hash.clone(),
                                },
                            );
                            content_hash = Some(hash);
                        } else if hash_budget > 0 {
                            hash_budget -= 1;
                            if let Some(hash) = self.content_hash(file.id, rev).await {
                                new_cache.insert(
                                    path.clone(),
                                    CachedHash {
                                        revision: rev.to_string(),
                                        hash: hash.clone(),
                                    },
                                );
                                content_hash = Some(hash);
                            }
                        }
                    }
                }
                entries.push(RemoteEntry {
                    path: path.clone(),
                    revision: file.current_version,
                    parent_revision: None,
                    is_dir: file.is_dir,
                    size: file.size.max(0) as u64,
                    content_hash,
                    deleted: false,
                });
                if file.is_dir {
                    stack.push((path, file.id, depth + 1));
                }
            }
        }
        self.hashes = new_cache.clone();
        self.save_hash_cache(&new_cache).await;
        Ok(entries)
    }

    async fn ensure_dir(&mut self, dir: &str) -> Result<Uuid, SyncError> {
        if dir.is_empty() {
            return Ok(self.root_id);
        }
        let mut current = String::new();
        let mut parent_id = self.root_id;
        for part in dir.split('/') {
            Self::validate_name(part)?;
            let next = Self::child_path(&current, part);
            if let Some(node) = self.nodes.get(&next) {
                if !node.is_dir {
                    return Err(Self::remote_error(format!(
                        "remote path {next} exists but is not a folder"
                    )));
                }
                parent_id = node.id;
                current = next;
                continue;
            }
            let id = Uuid::new_v4();
            let sealed = self
                .master
                .seal_name(id, part)
                .map_err(Self::remote_error)?
                .to_bytes();
            self.api
                .create_file(id, Some(parent_id), sealed, true)
                .await
                .map_err(Self::remote_error)?;
            self.nodes.insert(
                next.clone(),
                Node {
                    id,
                    revision: None,
                    is_dir: true,
                },
            );
            parent_id = id;
            current = next;
        }
        Ok(parent_id)
    }
}

impl Remote for HttpRemote {
    async fn snapshot(&mut self) -> Result<Vec<RemoteEntry>, SyncError> {
        self.snapshot_tree().await
    }

    async fn upload(
        &mut self,
        path: &str,
        source: &std::path::Path,
        base_revision: Option<Uuid>,
    ) -> Result<RemoteEntry, SyncError> {
        let parent = Self::parent_path(path).to_string();
        let name = Self::base_name(path).to_string();
        Self::validate_name(&name)?;
        let parent_id = self.ensure_dir(&parent).await?;
        let existing = self.nodes.get(path).cloned();
        let size = tokio::fs::metadata(source)
            .await
            .map_err(Self::remote_error)?
            .len();

        let file_id = existing.as_ref().map(|n| n.id).unwrap_or_else(Uuid::new_v4);
        let result = async {
            if existing.is_none() {
                let sealed = self
                    .master
                    .seal_name(file_id, &name)
                    .map_err(Self::remote_error)?
                    .to_bytes();
                self.api
                    .create_file(file_id, Some(parent_id), sealed, false)
                    .await
                    .map_err(Self::remote_error)?;
            }
            let revision = Uuid::new_v4();
            let parent_revision =
                base_revision.or_else(|| existing.as_ref().and_then(|n| n.revision));
            upload_file(
                &self.api,
                &self.master,
                file_id,
                revision,
                parent_revision,
                source,
            )
            .await
            .map_err(Self::remote_error)?;
            Ok::<Uuid, SyncError>(revision)
        }
        .await;

        match result {
            Ok(revision) => {
                self.nodes.insert(
                    path.to_string(),
                    Node {
                        id: file_id,
                        revision: Some(revision),
                        is_dir: false,
                    },
                );
                Ok(RemoteEntry {
                    path: path.to_string(),
                    revision: Some(revision),
                    parent_revision: base_revision,
                    is_dir: false,
                    size,
                    content_hash: None,
                    deleted: false,
                })
            }
            Err(e) => {
                if existing.is_none() {
                    // Best-effort cleanup of the empty node created above.
                    let _ = self.api.delete_file(file_id).await;
                }
                Err(e)
            }
        }
    }

    async fn download(
        &mut self,
        path: &str,
        revision: Uuid,
        destination: &std::path::Path,
    ) -> Result<(), SyncError> {
        let node = self.nodes.get(path).cloned().ok_or_else(|| {
            Self::remote_error(format!("remote file {path} is not in the snapshot"))
        })?;
        if node.is_dir {
            return Err(Self::remote_error(format!("{path} is a folder")));
        }
        download_file(
            &self.api,
            &self.master,
            node.id,
            Some(revision),
            destination,
        )
        .await
        .map_err(Self::remote_error)?;
        Ok(())
    }

    async fn delete(&mut self, path: &str) -> Result<(), SyncError> {
        let node = self.nodes.get(path).cloned().ok_or_else(|| {
            Self::remote_error(format!("remote node {path} is not in the snapshot"))
        })?;
        self.api
            .delete_file(node.id)
            .await
            .map_err(Self::remote_error)?;
        let prefix = format!("{path}/");
        self.nodes
            .retain(|p, _| p != path && !p.starts_with(&prefix));
        Ok(())
    }

    async fn mkdir(&mut self, path: &str) -> Result<(), SyncError> {
        self.ensure_dir(path).await.map(|_| ())
    }

    async fn move_path(&mut self, from: &str, to: &str) -> Result<(), SyncError> {
        let node = self.nodes.get(from).cloned().ok_or_else(|| {
            Self::remote_error(format!("remote node {from} is not in the snapshot"))
        })?;
        let target_parent = Self::parent_path(to).to_string();
        let target_name = Self::base_name(to).to_string();
        Self::validate_name(&target_name)?;
        let parent_id = self.ensure_dir(&target_parent).await?;
        let sealed = self
            .master
            .seal_name(node.id, &target_name)
            .map_err(Self::remote_error)?
            .to_bytes();
        self.api
            .rename_file(node.id, &base64_encode(&sealed))
            .await
            .map_err(Self::remote_error)?;
        self.api
            .move_file(node.id, Some(parent_id))
            .await
            .map_err(Self::remote_error)?;

        // Re-key this node and any descendants.
        let old_prefix = format!("{from}/");
        let moved: Vec<(String, Node)> = self
            .nodes
            .iter()
            .filter(|(p, _)| *p == from || p.starts_with(&old_prefix))
            .map(|(p, n)| (p.clone(), n.clone()))
            .collect();
        for (p, n) in moved {
            self.nodes.remove(&p);
            let suffix = p.strip_prefix(from).unwrap_or("");
            self.nodes.insert(format!("{to}{suffix}"), n);
        }
        Ok(())
    }
}

fn base64_encode(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn base64_decode(value: &str) -> Result<Vec<u8>, ClientError> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(value)
        .map_err(|_| ClientError::Protocol("invalid base64 name".into()))
}
