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
    if !root.is_dir() {
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
    let read = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(e) => {
            out.skipped
                .push((relative(root, dir), format!("cannot read directory: {e}")));
            return Ok(());
        }
    };
    for entry in read {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                out.skipped.push((relative(root, dir), e.to_string()));
                continue;
            }
        };
        let name = entry.file_name().to_string_lossy().to_string();
        if is_ignored_name(&name, opts) {
            continue;
        }
        let path = entry.path();
        let rel = relative(root, &path);
        let meta = match fs::symlink_metadata(&path) {
            Ok(m) => m,
            Err(e) => {
                out.skipped.push((rel, e.to_string()));
                continue;
            }
        };
        if meta.file_type().is_symlink() {
            if !opts.follow_symlinks {
                out.skipped
                    .push((rel, "symbolic link skipped (follow_symlinks=false)".into()));
                continue;
            }
            // Follow but never escape the root.
            let canonical = match fs::canonicalize(&path) {
                Ok(c) => c,
                Err(e) => {
                    out.skipped.push((rel, e.to_string()));
                    continue;
                }
            };
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
                    prev.content_hash.clone()
                }
                _ => match hash_file(&path) {
                    Ok(h) => Some(h),
                    Err(e) => {
                        out.skipped
                            .push((rel.clone(), format!("locked or unreadable: {e}")));
                        None
                    }
                },
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
