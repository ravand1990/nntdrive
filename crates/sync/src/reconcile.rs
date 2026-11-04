//! Three-way reconciliation.
//!
//! Revisions, not timestamps, decide what changed. If both sides changed the
//! same path to different content, nothing is overwritten: the remote version
//! is downloaded and the local version is preserved as a conflict copy.

use crate::scanner::ScannedEntry;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default)]
pub struct BaselineEntry {
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub content_hash: Option<String>,
    pub revision: Option<Uuid>,
    pub deleted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocalChange {
    Added {
        path: String,
        is_dir: bool,
        size: u64,
        hash: Option<String>,
    },
    Modified {
        path: String,
        size: u64,
        hash: Option<String>,
    },
    Deleted {
        path: String,
    },
    Renamed {
        from: String,
        to: String,
        size: u64,
        hash: Option<String>,
    },
}

impl LocalChange {
    pub fn path(&self) -> &str {
        match self {
            Self::Added { path, .. } | Self::Modified { path, .. } | Self::Deleted { path } => path,
            Self::Renamed { to, .. } => to,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteEntry {
    pub path: String,
    pub revision: Option<Uuid>,
    pub parent_revision: Option<Uuid>,
    pub is_dir: bool,
    pub size: u64,
    pub content_hash: Option<String>,
    pub deleted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteChange {
    Added {
        path: String,
        revision: Uuid,
        is_dir: bool,
        size: u64,
        hash: Option<String>,
    },
    Modified {
        path: String,
        revision: Uuid,
        size: u64,
        hash: Option<String>,
    },
    Deleted {
        path: String,
        revision: Option<Uuid>,
    },
    Renamed {
        from: String,
        to: String,
        revision: Option<Uuid>,
    },
}

impl RemoteChange {
    pub fn path(&self) -> &str {
        match self {
            Self::Added { path, .. } | Self::Modified { path, .. } | Self::Deleted { path, .. } => {
                path
            }
            Self::Renamed { to, .. } => to,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub enum Action {
    /// Upload local content; `base_revision` is the version the local edit
    /// started from, used by the server for optimistic concurrency checks.
    Upload {
        path: String,
        base_revision: Option<Uuid>,
    },
    /// Download a remote revision to `path`.
    Download {
        path: String,
        revision: Option<Uuid>,
    },
    DeleteRemote {
        path: String,
        base_revision: Option<Uuid>,
    },
    DeleteLocal {
        path: String,
    },
    RenameLocal {
        from: String,
        to: String,
    },
    MoveRemote {
        from: String,
        to: String,
    },
    /// Preserve local content as `local_copy`, then take the remote revision.
    Conflict {
        path: String,
        local_copy: String,
        remote_revision: Option<Uuid>,
    },
}

/// Compares the last synced baseline with a fresh scan.
pub fn detect_local(
    baseline: &HashMap<String, BaselineEntry>,
    scanned: &[ScannedEntry],
) -> Vec<LocalChange> {
    let current: HashMap<&str, &ScannedEntry> =
        scanned.iter().map(|e| (e.path.as_str(), e)).collect();
    let mut added = Vec::new();
    let mut modified = Vec::new();
    for e in scanned {
        match baseline.get(&e.path) {
            None => added.push(LocalChange::Added {
                path: e.path.clone(),
                is_dir: e.is_dir,
                size: e.size,
                hash: e.content_hash.clone(),
            }),
            Some(b) if b.deleted => added.push(LocalChange::Added {
                path: e.path.clone(),
                is_dir: e.is_dir,
                size: e.size,
                hash: e.content_hash.clone(),
            }),
            Some(b) if !e.is_dir && (b.content_hash != e.content_hash || b.size != e.size) => {
                modified.push(LocalChange::Modified {
                    path: e.path.clone(),
                    size: e.size,
                    hash: e.content_hash.clone(),
                })
            }
            Some(_) => {}
        }
    }

    let mut renamed_from: BTreeSet<String> = BTreeSet::new();
    let mut renamed_to: BTreeSet<String> = BTreeSet::new();
    // Detect moves by unique (size, hash) among removed and added regular files.
    let removed: Vec<&BaselineEntry> = baseline
        .values()
        .filter(|b| !b.deleted && !b.is_dir && !current.contains_key(b.path.as_str()))
        .collect();
    let mut renames = Vec::new();
    for old in &removed {
        if let Some(hash) = &old.content_hash {
            let matches: Vec<&LocalChange> = added
                .iter()
                .filter(|a| match a {
                    LocalChange::Added {
                        is_dir,
                        size,
                        hash: h,
                        path,
                    } => {
                        !*is_dir
                            && h.as_deref() == Some(hash.as_str())
                            && *size == old.size
                            && !renamed_to.contains(path)
                    }
                    _ => false,
                })
                .collect();
            if matches.len() == 1 {
                if let LocalChange::Added { path, size, .. } = matches[0] {
                    renames.push(LocalChange::Renamed {
                        from: old.path.clone(),
                        to: path.clone(),
                        size: *size,
                        hash: Some(hash.clone()),
                    });
                    renamed_from.insert(old.path.clone());
                    renamed_to.insert(path.clone());
                }
            }
        }
    }
    added.retain(|a| match a {
        LocalChange::Added { path, .. } => !renamed_to.contains(path),
        _ => true,
    });
    let mut deleted = Vec::new();
    for old in removed {
        if !renamed_from.contains(&old.path) {
            deleted.push(LocalChange::Deleted {
                path: old.path.clone(),
            });
        }
    }
    let mut out = Vec::new();
    out.extend(added);
    out.extend(modified);
    out.extend(deleted);
    out.extend(renames);
    out.sort_by(|a, b| a.path().cmp(b.path()));
    out
}

/// Filters a remote snapshot down to changes since the baseline revision.
pub fn detect_remote(
    baseline: &HashMap<String, BaselineEntry>,
    remote: &[RemoteEntry],
) -> Vec<RemoteChange> {
    let mut changed = Vec::new();
    let mut seen = BTreeSet::new();
    for entry in remote {
        seen.insert(entry.path.clone());
        let base = baseline.get(&entry.path);
        if entry.deleted {
            if base.map(|b| !b.deleted).unwrap_or(false) {
                changed.push(RemoteChange::Deleted {
                    path: entry.path.clone(),
                    revision: entry.revision,
                });
            }
            continue;
        }
        if entry.is_dir {
            if base.is_none() {
                changed.push(RemoteChange::Added {
                    path: entry.path.clone(),
                    revision: entry.revision.unwrap_or_else(Uuid::new_v4),
                    is_dir: true,
                    size: 0,
                    hash: None,
                });
            }
            continue;
        }
        match base {
            None => changed.push(RemoteChange::Added {
                path: entry.path.clone(),
                revision: entry.revision.unwrap_or_else(Uuid::new_v4),
                is_dir: false,
                size: entry.size,
                hash: entry.content_hash.clone(),
            }),
            Some(b) if b.revision != entry.revision || b.content_hash != entry.content_hash => {
                changed.push(RemoteChange::Modified {
                    path: entry.path.clone(),
                    revision: entry.revision.unwrap_or_else(Uuid::new_v4),
                    size: entry.size,
                    hash: entry.content_hash.clone(),
                })
            }
            _ => {}
        }
    }
    // Remote deletions: paths in baseline that are no longer in the snapshot.
    for b in baseline.values() {
        if !b.deleted && !seen.contains(&b.path) {
            changed.push(RemoteChange::Deleted {
                path: b.path.clone(),
                revision: b.revision,
            });
        }
    }

    // Detect remote renames (same content removed and added).
    let mut renamed_from = BTreeSet::new();
    let mut renamed_to = BTreeSet::new();
    let deleted: Vec<(String, Option<Uuid>)> = changed
        .iter()
        .filter_map(|c| match c {
            RemoteChange::Deleted { path, revision } => Some((path.clone(), *revision)),
            _ => None,
        })
        .collect();
    let mut renames = Vec::new();
    for (old_path, rev) in deleted {
        let old = match baseline.get(&old_path) {
            Some(b) => b,
            None => continue,
        };
        if old.content_hash.is_none() {
            continue;
        }
        let matches: Vec<&RemoteChange> = changed
            .iter()
            .filter(|c| match c {
                RemoteChange::Added {
                    hash,
                    is_dir: false,
                    path,
                    ..
                } => hash == &old.content_hash && !renamed_to.contains(path),
                _ => false,
            })
            .collect();
        if matches.len() == 1 {
            if let RemoteChange::Added { path, .. } = matches[0] {
                renames.push(RemoteChange::Renamed {
                    from: old_path.clone(),
                    to: path.clone(),
                    revision: rev,
                });
                renamed_from.insert(old_path);
                renamed_to.insert(path.clone());
            }
        }
    }
    changed.retain(|c| match c {
        RemoteChange::Deleted { path, .. } => !renamed_from.contains(path),
        RemoteChange::Added { path, .. } => !renamed_to.contains(path),
        _ => true,
    });
    changed.extend(renames);
    changed.sort_by(|a, b| a.path().cmp(b.path()));
    changed
}

/// Computes the actions a client must take. Pure function: no I/O, easy to test.
pub fn reconcile(
    baseline: &HashMap<String, BaselineEntry>,
    local: &[LocalChange],
    remote: &[RemoteChange],
    conflict_device: &str,
    timestamp: &str,
) -> Vec<Action> {
    let mut actions = Vec::new();
    let mut local_by_path: BTreeMap<&str, &LocalChange> =
        local.iter().map(|c| (c.path(), c)).collect();
    let mut remote_by_path: BTreeMap<&str, &RemoteChange> =
        remote.iter().map(|c| (c.path(), c)).collect();

    // Renames that do not collide with remote changes can be propagated as moves.
    for l in local {
        if let LocalChange::Renamed { from, to, .. } = l {
            let remote_touches_old = remote_by_path.contains_key(from.as_str());
            let remote_touches_new = remote_by_path.contains_key(to.as_str());
            if !remote_touches_old && !remote_touches_new {
                actions.push(Action::MoveRemote {
                    from: from.clone(),
                    to: to.clone(),
                });
                local_by_path.remove(to.as_str());
            }
        }
    }
    for r in remote {
        if let RemoteChange::Renamed { from, to, .. } = r {
            let local_touches_old = local_by_path.contains_key(from.as_str());
            let local_touches_new = local_by_path.contains_key(to.as_str());
            if !local_touches_old && !local_touches_new {
                actions.push(Action::RenameLocal {
                    from: from.clone(),
                    to: to.clone(),
                });
                remote_by_path.remove(to.as_str());
            }
        }
    }

    let paths: BTreeSet<String> = local_by_path
        .keys()
        .chain(remote_by_path.keys())
        .map(|s| s.to_string())
        .collect();

    for path in paths {
        let l = local_by_path.get(path.as_str()).copied();
        let r = remote_by_path.get(path.as_str()).copied();
        let base = baseline.get(&path);
        match (l, r) {
            (None, Some(RemoteChange::Deleted { .. })) => {
                actions.push(Action::DeleteLocal { path });
            }
            (None, Some(RemoteChange::Added { revision, .. })) => {
                actions.push(Action::Download {
                    path,
                    revision: Some(*revision),
                });
            }
            (None, Some(RemoteChange::Modified { revision, .. })) => {
                actions.push(Action::Download {
                    path,
                    revision: Some(*revision),
                });
            }
            (None, Some(RemoteChange::Renamed { .. })) | (None, None) => {}

            (Some(LocalChange::Deleted { .. }), None) => {
                actions.push(Action::DeleteRemote {
                    path,
                    base_revision: base.and_then(|b| b.revision),
                });
            }
            (Some(LocalChange::Deleted { .. }), Some(RemoteChange::Deleted { .. })) => {}
            (Some(LocalChange::Deleted { .. }), Some(RemoteChange::Added { revision, .. })) => {
                // Re-created remotely while deleted locally: take remote.
                actions.push(Action::Download {
                    path,
                    revision: Some(*revision),
                });
            }
            (Some(LocalChange::Deleted { .. }), Some(RemoteChange::Modified { revision, .. })) => {
                // Delete vs modify: never destroy the modified remote content.
                actions.push(Action::Download {
                    path,
                    revision: Some(*revision),
                });
            }
            (Some(LocalChange::Deleted { .. }), Some(RemoteChange::Renamed { .. })) => {
                actions.push(Action::DeleteRemote {
                    path,
                    base_revision: base.and_then(|b| b.revision),
                });
            }

            (Some(LocalChange::Added { hash, is_dir, .. }), None) => {
                if !is_dir {
                    actions.push(Action::Upload {
                        path,
                        base_revision: None,
                    });
                } else if let Some(h) = hash {
                    let _ = h;
                }
            }
            (Some(LocalChange::Modified { hash, .. }), None) => {
                let _ = hash;
                actions.push(Action::Upload {
                    path,
                    base_revision: base.and_then(|b| b.revision),
                });
            }
            (
                Some(LocalChange::Added { hash, .. }),
                Some(RemoteChange::Added {
                    hash: rh, revision, ..
                }),
            )
            | (
                Some(LocalChange::Added { hash, .. }),
                Some(RemoteChange::Modified {
                    hash: rh, revision, ..
                }),
            )
            | (
                Some(LocalChange::Modified { hash, .. }),
                Some(RemoteChange::Added {
                    hash: rh, revision, ..
                }),
            )
            | (
                Some(LocalChange::Modified { hash, .. }),
                Some(RemoteChange::Modified {
                    hash: rh, revision, ..
                }),
            ) => {
                if hash.is_some() && hash == rh {
                    // Same content on both sides: converge on the remote revision.
                } else {
                    actions.push(Action::Conflict {
                        local_copy: conflict_copy_name(&path, conflict_device, timestamp),
                        path,
                        remote_revision: Some(*revision),
                    });
                }
            }
            (Some(LocalChange::Modified { .. }), Some(RemoteChange::Deleted { .. }))
            | (Some(LocalChange::Added { .. }), Some(RemoteChange::Deleted { .. })) => {
                // Local edit versus remote delete: resurrect rather than lose data.
                actions.push(Action::Upload {
                    path,
                    base_revision: None,
                });
            }
            (Some(LocalChange::Renamed { .. }), Some(_)) => {
                let rev = match r {
                    Some(RemoteChange::Modified { revision, .. })
                    | Some(RemoteChange::Added { revision, .. }) => Some(*revision),
                    _ => None,
                };
                actions.push(Action::Conflict {
                    local_copy: conflict_copy_name(&path, conflict_device, timestamp),
                    path,
                    remote_revision: rev,
                });
            }
            (Some(_), Some(RemoteChange::Renamed { .. })) => {
                actions.push(Action::Conflict {
                    local_copy: conflict_copy_name(&path, conflict_device, timestamp),
                    path,
                    remote_revision: None,
                });
            }
            (Some(LocalChange::Renamed { .. }), None) => {
                // Rename not propagated as a move because the destination also
                // exists remotely: upload the new path rather than delete data.
                actions.push(Action::Upload {
                    path,
                    base_revision: None,
                });
            }
        }
    }
    actions
}

/// `report.docx` -> `report (conflict Laptop 2026-11-04T101500Z).docx`
pub fn conflict_copy_name(path: &str, device: &str, timestamp: &str) -> String {
    let (dir, name) = match path.rsplit_once('/') {
        Some((d, n)) => (Some(d), n),
        None => (None, path),
    };
    let (stem, ext) = match name.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s, Some(e)),
        _ => (name, None),
    };
    let safe_device: String = device
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .take(32)
        .collect();
    let copy = match ext {
        Some(e) => format!("{stem} (conflict {safe_device} {timestamp}).{e}"),
        None => format!("{stem} (conflict {safe_device} {timestamp})"),
    };
    match dir {
        Some(d) => format!("{d}/{copy}"),
        None => copy,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn baseline(entries: &[(&str, &str, Option<Uuid>)]) -> HashMap<String, BaselineEntry> {
        entries
            .iter()
            .map(|(path, hash, rev)| {
                (
                    path.to_string(),
                    BaselineEntry {
                        path: path.to_string(),
                        is_dir: false,
                        size: 10,
                        content_hash: Some(hash.to_string()),
                        revision: *rev,
                        deleted: false,
                    },
                )
            })
            .collect()
    }

    fn scan(path: &str, hash: &str, size: u64) -> ScannedEntry {
        ScannedEntry {
            path: path.into(),
            is_dir: false,
            size,
            mtime_ms: 1,
            content_hash: Some(hash.into()),
            read_only: false,
        }
    }

    #[test]
    fn local_create_modify_delete_are_detected() {
        let base = baseline(&[
            ("keep", "h1", Some(Uuid::new_v4())),
            ("gone", "h2", Some(Uuid::new_v4())),
            ("mod", "h3", Some(Uuid::new_v4())),
        ]);
        let scanned = vec![
            scan("keep", "h1", 10),
            scan("mod", "h3new", 11),
            scan("new", "h4", 5),
        ];
        let changes = detect_local(&base, &scanned);
        assert!(changes
            .iter()
            .any(|c| matches!(c, LocalChange::Added { path, .. } if path == "new")));
        assert!(changes
            .iter()
            .any(|c| matches!(c, LocalChange::Modified { path, .. } if path == "mod")));
        assert!(changes
            .iter()
            .any(|c| matches!(c, LocalChange::Deleted { path } if path == "gone")));
    }

    #[test]
    fn local_rename_is_detected_by_content() {
        let rev = Uuid::new_v4();
        let base = baseline(&[("old/name.txt", "same", Some(rev))]);
        let scanned = vec![scan("new/name.txt", "same", 10)];
        let changes = detect_local(&base, &scanned);
        assert_eq!(changes.len(), 1);
        match &changes[0] {
            LocalChange::Renamed { from, to, .. } => {
                assert_eq!(from, "old/name.txt");
                assert_eq!(to, "new/name.txt");
            }
            other => panic!("expected rename, got {other:?}"),
        }
        let actions = reconcile(&base, &changes, &[], "dev", "t");
        assert!(actions.iter().any(|a| matches!(a, Action::MoveRemote { from, to } if from == "old/name.txt" && to == "new/name.txt")));
    }

    #[test]
    fn remote_new_file_is_downloaded() {
        let base = HashMap::new();
        let rev = Uuid::new_v4();
        let remote = vec![RemoteChange::Added {
            path: "docs/a.txt".into(),
            revision: rev,
            is_dir: false,
            size: 3,
            hash: Some("h".into()),
        }];
        let actions = reconcile(&base, &[], &remote, "dev", "t");
        assert_eq!(
            actions,
            vec![Action::Download {
                path: "docs/a.txt".into(),
                revision: Some(rev)
            }]
        );
    }

    #[test]
    fn concurrent_different_edits_preserve_both_versions() {
        let rev = Uuid::new_v4();
        let base = baseline(&[("report.docx", "old", Some(rev))]);
        let local = vec![LocalChange::Modified {
            path: "report.docx".into(),
            size: 20,
            hash: Some("local".into()),
        }];
        let remote = vec![RemoteChange::Modified {
            path: "report.docx".into(),
            revision: Uuid::new_v4(),
            size: 30,
            hash: Some("remote".into()),
        }];
        let actions = reconcile(&base, &local, &remote, "Laptop", "2026-11-04T101500Z");
        assert_eq!(actions.len(), 1);
        match &actions[0] {
            Action::Conflict {
                path, local_copy, ..
            } => {
                assert_eq!(path, "report.docx");
                assert_eq!(
                    local_copy,
                    "report (conflict Laptop 2026-11-04T101500Z).docx"
                );
            }
            other => panic!("expected conflict, got {other:?}"),
        }
    }

    #[test]
    fn concurrent_identical_edits_converge_without_conflict() {
        let rev = Uuid::new_v4();
        let base = baseline(&[("a.txt", "old", Some(rev))]);
        let local = vec![LocalChange::Modified {
            path: "a.txt".into(),
            size: 10,
            hash: Some("same".into()),
        }];
        let remote = vec![RemoteChange::Modified {
            path: "a.txt".into(),
            revision: Uuid::new_v4(),
            size: 10,
            hash: Some("same".into()),
        }];
        assert!(reconcile(&base, &local, &remote, "d", "t").is_empty());
    }

    #[test]
    fn delete_vs_modify_never_loses_data() {
        let rev = Uuid::new_v4();
        let base = baseline(&[("a.txt", "old", Some(rev)), ("b.txt", "old2", Some(rev))]);

        let local = vec![LocalChange::Deleted {
            path: "a.txt".into(),
        }];
        let remote = vec![RemoteChange::Modified {
            path: "a.txt".into(),
            revision: Uuid::new_v4(),
            size: 5,
            hash: Some("new".into()),
        }];
        let actions = reconcile(&base, &local, &remote, "d", "t");
        assert!(matches!(actions[0], Action::Download { .. }));

        let local = vec![LocalChange::Modified {
            path: "b.txt".into(),
            size: 9,
            hash: Some("local".into()),
        }];
        let remote = vec![RemoteChange::Deleted {
            path: "b.txt".into(),
            revision: Some(rev),
        }];
        let actions = reconcile(&base, &local, &remote, "d", "t");
        assert!(matches!(actions[0], Action::Upload { .. }));
    }

    #[test]
    fn both_deleted_is_a_noop() {
        let rev = Uuid::new_v4();
        let base = baseline(&[("a", "h", Some(rev))]);
        let actions = reconcile(
            &base,
            &[LocalChange::Deleted { path: "a".into() }],
            &[RemoteChange::Deleted {
                path: "a".into(),
                revision: Some(rev),
            }],
            "d",
            "t",
        );
        assert!(actions.is_empty());
    }

    #[test]
    fn remote_rename_becomes_local_move() {
        let rev = Uuid::new_v4();
        let base = baseline(&[("a/old.txt", "h", Some(rev))]);
        let remote = vec![RemoteChange::Renamed {
            from: "a/old.txt".into(),
            to: "a/new.txt".into(),
            revision: Some(rev),
        }];
        let actions = reconcile(&base, &[], &remote, "d", "t");
        assert_eq!(
            actions,
            vec![Action::RenameLocal {
                from: "a/old.txt".into(),
                to: "a/new.txt".into()
            }]
        );
    }

    #[test]
    fn case_conflict_name_is_sanitized() {
        assert_eq!(
            conflict_copy_name("dir/photo.JPG", "my laptop/1", "T"),
            "dir/photo (conflict my_laptop_1 T).JPG"
        );
    }
}
