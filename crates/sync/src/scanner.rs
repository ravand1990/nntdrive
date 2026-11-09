//! Filesystem scanner for synchronization.
//!
//! * stable, relative, forward-slash paths
//! * ignores temporary and lock files that are still being written
//! * rejects symlinks by default (a symlink could pull arbitrary host files
//!   into the encrypted cloud)
//! * detects case-only collisions, which cannot round-trip on Windows/macOS
//! * reuses the previous content hash when size and mtime are unchanged

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ScannedEntry {
    /// Relative path with `/` separators.
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub mtime_ms: i64,
    pub content_hash: Option<String>,
    pub read_only: bool,
}

#[derive(Debug, Default, Clone)]
pub struct ScanResult {
    pub entries: Vec<ScannedEntry>,
    pub skipped: Vec<(String, String)>,
    pub case_collisions: Vec<(String, String)>,
}

#[derive(Debug, Clone, Default)]
pub struct ScanOptions {
    pub follow_symlinks: bool,
    pub include_hidden: bool,
    /// Extra lowercase suffixes to ignore (in addition to the built-ins).
    pub ignore_suffixes: Vec<String>,
    /// Relative paths (folders or files) excluded from synchronization.
    pub excluded_paths: Vec<String>,
}

impl ScanOptions {
    pub fn is_excluded(&self, rel: &str) -> bool {
        let rel = rel.trim_matches('/');
        self.excluded_paths.iter().any(|excluded| {
            let excluded = excluded.trim().trim_matches('/').replace('\\', "/");
            !excluded.is_empty() && (rel == excluded || rel.starts_with(&format!("{excluded}/")))
        })
    }
}

pub fn is_ignored_name(name: &str, opts: &ScanOptions) -> bool {
    if name == ".nntdrive" || name == ".DS_Store" || name == "Thumbs.db" {
        return true;
    }
    if !opts.include_hidden && name.starts_with('.') {
        return true;
    }
    if name.starts_with("~$") {
        return true;
    }
    let lower = name.to_ascii_lowercase();
    const SUFFIXES: &[&str] = &[
        ".tmp",
        ".temp",
        ".part",
        ".partial",
        ".crdownload",
        ".download",
        ".swp",
        ".swx",
        ".lock",
        ".~lock",
    ];
    if SUFFIXES.iter().any(|s| lower.ends_with(s)) {
        return true;
    }
    opts.ignore_suffixes
        .iter()
        .any(|s| lower.ends_with(&s.to_ascii_lowercase()))
}

/// Scans `root`. Blocking; call from `spawn_blocking` in async contexts.
pub fn scan(
    root: &Path,
    opts: &ScanOptions,
    previous: &HashMap<String, ScannedEntry>,
) -> std::io::Result<ScanResult> {
    let mut result = ScanResult::default();
    if !fs::metadata(root)?.is_dir() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotADirectory,
            "sync root is not a directory",
        ));
    }
    let mut seen_case: HashMap<String, String> = HashMap::new();
    walk(root, root, opts, previous, &mut result, &mut seen_case)?;
    result.entries.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(result)
}

fn walk(
    root: &Path,
    dir: &Path,
    opts: &ScanOptions,
    previous: &HashMap<String, ScannedEntry>,
    out: &mut ScanResult,
    seen_case: &mut HashMap<String, String>,
) -> std::io::Result<()> {
    // An incomplete scan is not a local deletion. Abort the entire round on
    // I/O failures; `skipped` is reserved for deliberate policy decisions.
    let read = fs::read_dir(dir)?;
    for entry in read {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if is_ignored_name(&name, opts) {
            continue;
        }
        let path = entry.path();
        let rel = relative(root, &path);
        if opts.is_excluded(&rel) {
            continue;
        }
        let meta = fs::symlink_metadata(&path)?;
        if meta.file_type().is_symlink() {
            if !opts.follow_symlinks {
                out.skipped
                    .push((rel, "symbolic link skipped (follow_symlinks=false)".into()));
                continue;
            }
            // Follow but never escape the root.
            let canonical = fs::canonicalize(&path)?;
            if !canonical.starts_with(root) {
                out.skipped
                    .push((rel, "symlink escapes the sync root".into()));
                continue;
            }
        }
        let lower = rel.to_lowercase();
        if let Some(previous_path) = seen_case.insert(lower.clone(), rel.clone()) {
            if previous_path != rel {
                out.case_collisions.push((previous_path, rel.clone()));
            }
        }
        if meta.is_dir() {
            out.entries.push(ScannedEntry {
                path: rel.clone(),
                is_dir: true,
                size: 0,
                mtime_ms: 0,
                content_hash: None,
                read_only: meta.permissions().readonly(),
            });
            walk(root, &path, opts, previous, out, seen_case)?;
        } else if meta.is_file() {
            let size = meta.len();
            let mtime_ms = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            let hash = match previous.get(&rel) {
                Some(prev)
                    if prev.size == size
                        && prev.mtime_ms == mtime_ms
                        && prev.content_hash.is_some() =>
                {
                    // Permissions can change without size/mtime changing.
                    // A cached hash must not bypass the current read grant.
                    let _file = fs::File::open(&path)?;
                    prev.content_hash.clone()
                }
                _ => Some(hash_file(&path)?),
            };
            out.entries.push(ScannedEntry {
                path: rel,
                is_dir: false,
                size,
                mtime_ms,
                content_hash: hash,
                read_only: meta.permissions().readonly(),
            });
        } else {
            out.skipped.push((rel, "not a regular file".into()));
        }
    }
    Ok(())
}

pub fn hash_file(path: &Path) -> std::io::Result<String> {
    let mut f = fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = vec![0u8; 1024 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

pub fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("/")
}

/// Validates a path received from a remote peer before it touches the local
/// filesystem. Rejects absolute paths, `..`, NUL, and Windows-reserved names.
pub fn validate_relative_path(path: &str) -> Result<PathBuf, &'static str> {
    if path.is_empty() || path.starts_with('/') || path.starts_with('\\') {
        return Err("empty or absolute path");
    }
    if path.contains('\0') {
        return Err("NUL in path");
    }
    let mut out = PathBuf::new();
    for part in path.split(['/', '\\']) {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." {
            return Err("path traversal");
        }
        let lower = part.to_ascii_lowercase();
        let stem = lower.split('.').next().unwrap_or("");
        if matches!(
            stem,
            "con"
                | "prn"
                | "aux"
                | "nul"
                | "com1"
                | "com2"
                | "com3"
                | "com4"
                | "lpt1"
                | "lpt2"
                | "lpt3"
        ) {
            return Err("reserved Windows device name");
        }
        if part.contains(':') {
            return Err("colon in path");
        }
        out.push(part);
    }
    if out.as_os_str().is_empty() {
        return Err("empty path");
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Exercise read_dir failure without chmod: this remains deterministic even
    // for root and models a directory replaced between metadata and traversal.
    #[test]
    fn walk_rejects_failed_root_and_nested_directory_listings() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("not-a-directory");
        fs::write(&file, b"not a directory").unwrap();
        for root in [file.as_path(), dir.path()] {
            let mut result = ScanResult::default();
            let error = walk(
                root,
                &file,
                &ScanOptions::default(),
                &HashMap::new(),
                &mut result,
                &mut HashMap::new(),
            )
            .expect_err("an incomplete directory listing must abort the scan");
            assert_eq!(error.kind(), std::io::ErrorKind::NotADirectory);
            assert!(result.skipped.is_empty(), "I/O errors are not policy skips");
        }
    }

    // chmod alone cannot revoke root's access. Re-exec only this test with
    // dropped privileges so real permission errors are tested in root-run CI too.
    #[cfg(target_os = "linux")]
    #[test]
    fn permission_revocation_aborts_scan() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        use std::os::unix::process::CommandExt;

        const CHILD: &str = "NNTDRIVE_SCANNER_PERMISSION_TEST_CHILD";
        let capabilities = fs::read_to_string("/proc/self/status").unwrap();
        let effective = capabilities
            .lines()
            .find_map(|line| {
                line.strip_prefix("CapEff:")
                    .map(|value| u64::from_str_radix(value.trim(), 16).unwrap())
            })
            .unwrap();
        // The approved check containers drop all capabilities: uid 0 there
        // cannot bypass chmod, and cannot call setuid either.
        if fs::metadata("/proc/self").unwrap().uid() == 0 && effective & 0b110 != 0 {
            assert!(std::env::var_os(CHILD).is_none(), "privilege drop failed");
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "scanner::tests::permission_revocation_aborts_scan",
                    "--nocapture",
                ])
                .env(CHILD, "1")
                .uid(65534)
                .gid(65534)
                .status()
                .expect("run scanner permission regression without root privileges");
            assert!(
                status.success(),
                "unprivileged permission regression failed"
            );
            return;
        }

        for blocked in ["", "nested", "nested/file.txt"] {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path();
            fs::create_dir(root.join("nested")).unwrap();
            fs::write(root.join("nested/file.txt"), b"preserve remote copy").unwrap();
            let initial = scan(root, &ScanOptions::default(), &HashMap::new()).unwrap();
            let previous = initial
                .entries
                .into_iter()
                .map(|e| (e.path.clone(), e))
                .collect();
            let denied = root.join(blocked);
            let permissions = fs::metadata(&denied).unwrap().permissions();
            fs::set_permissions(&denied, fs::Permissions::from_mode(0o0)).unwrap();
            // Check both uncached hashing and unchanged size/mtime hash reuse.
            let uncached = scan(root, &ScanOptions::default(), &HashMap::new());
            let cached = scan(root, &ScanOptions::default(), &previous);
            fs::set_permissions(&denied, permissions).unwrap();
            for result in [uncached, cached] {
                assert_eq!(
                    result
                        .expect_err("unreadability must abort before reconciliation")
                        .kind(),
                    std::io::ErrorKind::PermissionDenied,
                    "revoked access to {blocked:?}"
                );
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_remain_intentional_skips() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("file.txt"), b"keep").unwrap();
        std::os::unix::fs::symlink("file.txt", dir.path().join("link")).unwrap();
        let result = scan(dir.path(), &ScanOptions::default(), &HashMap::new()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].path, "file.txt");
        assert_eq!(result.skipped.len(), 1);
        assert_eq!(result.skipped[0].0, "link");
        assert!(result.skipped[0].1.contains("symbolic link skipped"));
    }

    #[test]
    fn scanner_ignores_temp_files_and_nested_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("sub")).unwrap();
        fs::write(root.join("hello.txt"), b"hello").unwrap();
        fs::write(root.join("sub/world.bin"), b"world").unwrap();
        fs::write(root.join("draft.tmp"), b"busy").unwrap();
        fs::write(root.join("~$report.docx"), b"lock").unwrap();
        fs::write(root.join(".hidden"), b"secret").unwrap();
        fs::create_dir_all(root.join(".nntdrive")).unwrap();

        let res = scan(root, &ScanOptions::default(), &HashMap::new()).unwrap();
        let paths: Vec<&str> = res.entries.iter().map(|e| e.path.as_str()).collect();
        assert!(paths.contains(&"hello.txt"));
        assert!(paths.contains(&"sub"));
        assert!(paths.contains(&"sub/world.bin"));
        assert!(!paths.iter().any(|p| p.contains("draft.tmp")));
        assert!(!paths.iter().any(|p| p.contains("$report")));
        assert!(!paths.iter().any(|p| p.contains(".hidden")));
        assert!(!paths.iter().any(|p| p.contains(".nntdrive")));
    }

    #[test]
    fn excluded_paths_skip_files_and_entire_subtrees() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("keep/nested")).unwrap();
        fs::create_dir_all(root.join("skip/deeper")).unwrap();
        fs::write(root.join("keep/nested/ok.txt"), b"ok").unwrap();
        fs::write(root.join("skip/deeper/no.txt"), b"no").unwrap();
        fs::write(root.join("skip/file.txt"), b"no").unwrap();
        fs::write(root.join("top.txt"), b"top").unwrap();

        let opts = ScanOptions {
            excluded_paths: vec!["skip/".into(), "top.txt".into()],
            ..ScanOptions::default()
        };
        let res = scan(root, &opts, &HashMap::new()).unwrap();
        let paths: Vec<&str> = res.entries.iter().map(|e| e.path.as_str()).collect();
        assert!(paths.contains(&"keep/nested/ok.txt"));
        assert!(!paths.contains(&"top.txt"));
        assert!(!paths.iter().any(|p| p.starts_with("skip")));
    }

    #[test]
    fn hash_is_reused_when_size_and_mtime_match() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a"), b"abc").unwrap();
        let first = scan(dir.path(), &ScanOptions::default(), &HashMap::new()).unwrap();
        let previous: HashMap<String, ScannedEntry> = first
            .entries
            .into_iter()
            .map(|e| (e.path.clone(), e))
            .collect();
        // Poison the cached hash to prove it is reused, not recomputed.
        let mut prev = previous.clone();
        prev.get_mut("a").unwrap().content_hash = Some("cached".into());
        let second = scan(dir.path(), &ScanOptions::default(), &prev).unwrap();
        assert_eq!(second.entries[0].content_hash.as_deref(), Some("cached"));
    }

    #[test]
    fn case_collisions_are_reported() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("Readme.md"), b"a").unwrap();
        fs::write(dir.path().join("README.md"), b"b").unwrap();
        let res = scan(dir.path(), &ScanOptions::default(), &HashMap::new()).unwrap();
        assert_eq!(res.case_collisions.len(), 1);
    }

    #[test]
    fn path_validation_blocks_escapes() {
        assert!(validate_relative_path("docs/file.txt").is_ok());
        assert!(validate_relative_path("../etc/passwd").is_err());
        assert!(validate_relative_path("/etc/passwd").is_err());
        assert!(validate_relative_path("C:/Windows/win.ini").is_err());
        assert!(validate_relative_path("CON").is_err());
        assert!(validate_relative_path("a\0b").is_err());
    }
}
