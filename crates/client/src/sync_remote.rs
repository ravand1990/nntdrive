//! HTTP implementation of the synchronization `Remote` interface.
//!
//! A sync root is a remote folder node. Paths below it are reconstructed by
//! walking the encrypted tree and decrypting names locally; the server only
//! sees opaque node ids and sealed name blobs.

use crate::{download_file, upload_file, ApiClient, ClientError};
use nntdrive_crypto::MasterKey;
use nntdrive_sync::{Remote, RemoteEntry, SyncError};
use std::collections::HashMap;
use std::path::PathBuf;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

#[derive(Debug, Clone)]
struct Node {
    id: Uuid,
    revision: Option<Uuid>,
    is_dir: bool,
}

/// Number of files/directories we are willing to walk in one snapshot. Guards
/// against a pathological or malicious remote tree.
const MAX_NODES: usize = 100_000;

pub struct HttpRemote {
    api: ApiClient,
    master: MasterKey,
    root_id: Uuid,
    nodes: HashMap<String, Node>,
}

impl HttpRemote {
    pub fn new(api: ApiClient, master: MasterKey, root_id: Uuid) -> Self {
        Self {
            api,
            master,
            root_id,
            nodes: HashMap::new(),
        }
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
                entries.push(RemoteEntry {
                    path: path.clone(),
                    revision: file.current_version,
                    parent_revision: None,
                    is_dir: file.is_dir,
                    size: file.size.max(0) as u64,
                    content_hash: None,
                    deleted: false,
                });
                if file.is_dir {
                    stack.push((path, file.id, depth + 1));
                }
            }
        }
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

    async fn write_temp(&self, content: &[u8]) -> Result<PathBuf, SyncError> {
        let path = std::env::temp_dir().join(format!("nntdrive-sync-{}", Uuid::new_v4()));
        let mut file = tokio::fs::File::create(&path)
            .await
            .map_err(Self::remote_error)?;
        file.write_all(content).await.map_err(Self::remote_error)?;
        file.flush().await.map_err(Self::remote_error)?;
        Ok(path)
    }
}

impl Remote for HttpRemote {
    async fn snapshot(&mut self) -> Result<Vec<RemoteEntry>, SyncError> {
        self.snapshot_tree().await
    }

    async fn upload(
        &mut self,
        path: &str,
        content: Vec<u8>,
        base_revision: Option<Uuid>,
    ) -> Result<RemoteEntry, SyncError> {
        let parent = Self::parent_path(path).to_string();
        let name = Self::base_name(path).to_string();
        Self::validate_name(&name)?;
        let parent_id = self.ensure_dir(&parent).await?;
        let existing = self.nodes.get(path).cloned();
        let temp = self.write_temp(&content).await?;

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
                &temp,
            )
            .await
            .map_err(Self::remote_error)?;
            Ok::<Uuid, SyncError>(revision)
        }
        .await;

        let _ = tokio::fs::remove_file(&temp).await;
        match result {
            Ok(revision) => {
                let size = content.len() as u64;
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

    async fn fetch(&mut self, path: &str, revision: Uuid) -> Result<Vec<u8>, SyncError> {
        let node = self.nodes.get(path).cloned().ok_or_else(|| {
            Self::remote_error(format!("remote file {path} is not in the snapshot"))
        })?;
        if node.is_dir {
            return Err(Self::remote_error(format!("{path} is a folder")));
        }
        let temp = std::env::temp_dir().join(format!("nntdrive-sync-dl-{}", Uuid::new_v4()));
        let result = download_file(&self.api, &self.master, node.id, Some(revision), &temp).await;
        let data = match result {
            Ok(_) => tokio::fs::read(&temp).await.map_err(Self::remote_error),
            Err(e) => Err(Self::remote_error(e)),
        };
        let _ = tokio::fs::remove_file(&temp).await;
        data
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
