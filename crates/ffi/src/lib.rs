//! C ABI for the Flutter clients.
//!
//! All functions take/return UTF-8 JSON and never expose raw key material. Keys
//! stay in a process-local handle table; Dart only sees an integer handle. The
//! long-running upload/download calls block and are meant to run in a Dart
//! isolate.

use nntdrive_client::{download_file, upload_file, ApiClient};
use nntdrive_crypto::{
    derive_auth_verifier, AccountKey, DeviceKeypair, Envelope, KeyFile, MasterKeyRing, RecoveryKit,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::runtime::Runtime;
use uuid::Uuid;

mod overview;

static HANDLES: OnceLock<Mutex<HashMap<u64, Arc<MasterKeyRing>>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn handles() -> &'static Mutex<HashMap<u64, Arc<MasterKeyRing>>> {
    HANDLES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

fn key(handle: u64) -> Result<Arc<MasterKeyRing>, String> {
    handles()
        .lock()
        .map_err(|_| "key registry poisoned".to_string())?
        .get(&handle)
        .cloned()
        .ok_or_else(|| "invalid or locked key handle".to_string())
}

unsafe fn arg(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("null string argument".into());
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(|s| s.to_string())
        .map_err(|_| "argument is not valid UTF-8".to_string())
}

fn out(value: Value) -> *mut c_char {
    let text = value.to_string();
    CString::new(text)
        .unwrap_or_else(|_| CString::new("{\"ok\":false,\"error\":\"nul byte\"}").unwrap())
        .into_raw()
}

fn fail(message: impl Into<String>) -> *mut c_char {
    out(json!({ "ok": false, "error": message.into() }))
}

fn ok(value: Value) -> *mut c_char {
    let mut map = serde_json::Map::new();
    map.insert("ok".into(), Value::Bool(true));
    if let Value::Object(inner) = value {
        for (k, v) in inner {
            map.insert(k, v);
        }
    }
    out(Value::Object(map))
}

fn guard(f: impl FnOnce() -> Result<Value, String>) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => ok(v),
        Ok(Err(e)) => fail(e),
        Err(_) => fail("internal panic in native bridge"),
    }
}

/// One live scan batch. Relative local paths only: nothing here is sent to the
/// backend, and the client keeps at most a small prefix of it.
fn scan_event(paths: &[nntdrive_sync::ScannedPath]) -> String {
    let items: Vec<Value> = paths
        .iter()
        .map(|scanned| json!({"path":scanned.path,"is_dir":scanned.is_dir}))
        .collect();
    json!({"phase":"scan","items":items}).to_string()
}

/// One live compare batch: relative remote paths the snapshot has already
/// listed. Names were decrypted locally; nothing here is sent to the backend.
fn snapshot_event(paths: &[nntdrive_sync::ScannedPath]) -> String {
    let items: Vec<Value> = paths
        .iter()
        .map(|compared| json!({"path":compared.path,"is_dir":compared.is_dir}))
        .collect();
    json!({"phase":"compare","items":items}).to_string()
}

/// Frees a string returned by any `nntdrive_*` function.
///
/// # Safety
/// `ptr` must be null or a pointer previously returned by this library.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// Version marker so the Dart side can detect a wrong/missing library.
#[no_mangle]
pub extern "C" fn nntdrive_abi_version() -> u32 {
    1
}

/// Free bytes available to this process on the filesystem that holds `path`.
///
/// The client shows this next to its own cache size so a user can see real
/// device headroom. It is a read-only syscall wrapper: the path and the result
/// stay on the device and nothing is sent to the backend.
///
/// # Safety
/// `path` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_free_space(path: *const c_char) -> *mut c_char {
    guard(|| {
        let raw = arg(path)?;
        free_space_bytes(Path::new(&raw)).map(|free| json!({ "freeBytes": free }))
    })
}

/// Available bytes for the filesystem containing `path`.
///
/// `f_bavail` (not `f_bfree`) is used on Unix: it is the space an ordinary
/// process may actually write, so the number cannot promise reserved blocks.
fn free_space_bytes(path: &Path) -> Result<u64, String> {
    #[cfg(unix)]
    {
        let stats = rustix::fs::statvfs(path)
            .map_err(|_| "cannot read this device's free space".to_string())?;
        let block = if stats.f_frsize > 0 {
            stats.f_frsize
        } else {
            stats.f_bsize
        };
        Ok(stats.f_bavail.saturating_mul(block))
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
        wide.push(0);
        let mut available: u64 = 0;
        let ok = windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(
            wide.as_ptr(),
            &mut available,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        );
        if ok == 0 {
            return Err("cannot read this device's free space".to_string());
        }
        Ok(available)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        Err("free space is not supported on this platform".to_string())
    }
}

/// Creates a new account identity: keyfile, recovery kit and server verifier.
///
/// # Safety
/// `password` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_generate_account(password: *const c_char) -> *mut c_char {
    guard(|| {
        let password = arg(password)?;
        if password.len() < 8 {
            return Err("password must be at least 8 characters".into());
        }
        let account_id = Uuid::new_v4();
        let (keyfile, master) =
            KeyFile::create(&password, account_id).map_err(|e| e.to_string())?;
        let (kit, recovery_code) =
            RecoveryKit::create(&master, Some("NNTDrive recovery kit".into()))
                .map_err(|e| e.to_string())?;
        let verifier = derive_auth_verifier(&password, account_id);
        Ok(json!({
            "account_id": account_id,
            "verifier": verifier,
            "keyfile": keyfile,
            "recovery_kit": kit,
            "recovery_code": recovery_code,
        }))
    })
}

/// Derives the login verifier without creating a keyfile.
///
/// # Safety
/// Both arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_derive_verifier(
    password: *const c_char,
    account_id: *const c_char,
) -> *mut c_char {
    guard(|| {
        let password = arg(password)?;
        let account_id: Uuid = arg(account_id)?
            .parse()
            .map_err(|_| "invalid account id".to_string())?;
        Ok(json!({ "verifier": derive_auth_verifier(&password, account_id) }))
    })
}

/// Unlocks a password-wrapped keyfile and stores the master key in memory.
///
/// # Safety
/// Both arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_unlock(
    keyfile_json: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    guard(|| {
        let keyfile_json = arg(keyfile_json)?;
        let password = arg(password)?;
        let keyfile: KeyFile =
            serde_json::from_str(&keyfile_json).map_err(|_| "invalid keyfile".to_string())?;
        // Keep every retained epoch: revisions sealed before an AMK rotation
        // stay readable, while new content is always sealed with the current
        // epoch. A keyfile without retained epochs yields a single-key ring.
        let ring = keyfile.unlock_ring(&password).map_err(|e| e.to_string())?;
        let account_id = ring.account_id();
        let epoch = ring.epoch();
        let epochs: Vec<u32> = ring.epochs().collect();
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        handles()
            .lock()
            .map_err(|_| "key registry poisoned".to_string())?
            .insert(handle, Arc::new(ring));
        Ok(json!({
            "handle": handle,
            "account_id": account_id,
            "epoch": epoch,
            "epochs": epochs,
        }))
    })
}

/// Drops the master key for a handle.
#[no_mangle]
pub extern "C" fn nntdrive_lock(handle: u64) {
    if let Ok(mut map) = handles().lock() {
        map.remove(&handle);
        // Same lock order as overview admission/publication. A revoked handle
        // cannot retain plaintext results or publish a late completed snapshot.
        overview::revoke(handle);
    }
}

/// Returns an X25519 device identity. The secret must be kept in the platform
/// keystore by the caller.
///
/// # Safety
/// Returns a pointer that must be released with `nntdrive_string_free`.
#[no_mangle]
pub extern "C" fn nntdrive_device_identity() -> *mut c_char {
    guard(|| {
        let device = DeviceKeypair::generate();
        Ok(json!({
            "secret": device.to_bytes(),
            "public_key": base64_key(&device.public().0),
        }))
    })
}

/// Returns a client-local comparison key, never a server-visible equality tag.
/// NFC before and after Unicode lowercase makes canonical equivalents compare
/// equally without rewriting the user's encrypted spelling. This deliberately
/// does not implement compatibility normalization or full Unicode case folding.
///
/// # Safety
/// `name` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_name_collision_key(name: *const c_char) -> *mut c_char {
    guard(|| {
        use unicode_normalization::UnicodeNormalization;
        let name = arg(name)?;
        let normalized: String = name.nfc().collect();
        let comparison: String = normalized.to_lowercase().nfc().collect();
        Ok(json!({ "comparison": comparison }))
    })
}

/// Seals a plaintext node name with the account name key.
///
/// # Safety
/// Arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_seal_name(
    handle: u64,
    node_id: *const c_char,
    name: *const c_char,
) -> *mut c_char {
    guard(|| {
        let master = key(handle)?;
        let node_id: Uuid = arg(node_id)?
            .parse()
            .map_err(|_| "invalid node id".to_string())?;
        let name = arg(name)?;
        let sealed = master
            .seal_name(node_id, &name)
            .map_err(|e| e.to_string())?;
        Ok(json!({ "name_enc": base64_bytes(&sealed.to_bytes()) }))
    })
}

/// Opens a sealed node name.
///
/// # Safety
/// Arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_open_name(
    handle: u64,
    node_id: *const c_char,
    name_enc_b64: *const c_char,
) -> *mut c_char {
    guard(|| {
        let master = key(handle)?;
        let node_id: Uuid = arg(node_id)?
            .parse()
            .map_err(|_| "invalid node id".to_string())?;
        let bytes = decode_b64(&arg(name_enc_b64)?)?;
        let envelope = Envelope::from_bytes(&bytes).map_err(|e| e.to_string())?;
        let name = master
            .open_name(node_id, &envelope)
            .map_err(|_| "cannot decrypt name (wrong key or tampered data)".to_string())?;
        Ok(json!({ "name": name }))
    })
}

/// Encrypts, uploads and commits a revision. Blocking: call from an isolate.
///
/// # Safety
/// All string arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn nntdrive_upload(
    handle: u64,
    base_url: *const c_char,
    token: *const c_char,
    file_id: *const c_char,
    revision_id: *const c_char,
    parent_revision: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    guard(|| {
        let master = key(handle)?;
        let base_url = arg(base_url)?;
        let token = arg(token)?;
        let file_id: Uuid = arg(file_id)?
            .parse()
            .map_err(|_| "invalid file id".to_string())?;
        let revision_id: Uuid = arg(revision_id)?
            .parse()
            .map_err(|_| "invalid revision id".to_string())?;
        let parent = arg(parent_revision)?;
        let parent = if parent.is_empty() {
            None
        } else {
            Some(
                parent
                    .parse::<Uuid>()
                    .map_err(|_| "invalid parent revision")?,
            )
        };
        let path = arg(path)?;
        let mut api = ApiClient::new(base_url).map_err(|e| e.to_string())?;
        api.set_token(token);
        let result = runtime()
            .block_on(upload_file(
                &api,
                &master,
                file_id,
                revision_id,
                parent,
                Path::new(&path),
            ))
            .map_err(|e| e.to_string())?;
        serde_json::to_value(result).map_err(|e| e.to_string())
    })
}

/// Downloads, verifies and decrypts a revision. Blocking: call from an isolate.
///
/// # Safety
/// All string arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn nntdrive_download(
    handle: u64,
    base_url: *const c_char,
    token: *const c_char,
    file_id: *const c_char,
    revision_id: *const c_char,
    destination: *const c_char,
) -> *mut c_char {
    guard(|| {
        let master = key(handle)?;
        let base_url = arg(base_url)?;
        let token = arg(token)?;
        let file_id: Uuid = arg(file_id)?
            .parse()
            .map_err(|_| "invalid file id".to_string())?;
        let revision = arg(revision_id)?;
        let revision = if revision.is_empty() {
            None
        } else {
            Some(
                revision
                    .parse::<Uuid>()
                    .map_err(|_| "invalid revision id")?,
            )
        };
        let destination = arg(destination)?;
        let mut api = ApiClient::new(base_url).map_err(|e| e.to_string())?;
        api.set_token(token);
        let result = runtime()
            .block_on(download_file(
                &api,
                &master,
                file_id,
                revision,
                Path::new(&destination),
            ))
            .map_err(|e| e.to_string())?;
        serde_json::to_value(result).map_err(|e| e.to_string())
    })
}

/// Inspect an existing local journal and freshly hash one confined file.
/// No network access or journal initialization; errors never imply equality.
///
/// # Safety
/// `request` must be a valid NUL-terminated UTF-8 JSON string.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_local_file_matches(request: *const c_char) -> *mut c_char {
    guard(|| {
        let config: serde_json::Value =
            serde_json::from_str(&arg(request)?).map_err(|_| "invalid inspection request")?;
        let _master = key(config["handle"].as_u64().ok_or("missing handle")?)?;
        let text = |name: &str| config[name].as_str().ok_or("invalid inspection field");
        let revision = text("revision")?.parse().map_err(|_| "invalid revision")?;
        let size = config["size"].as_u64().ok_or("invalid size")?;
        let matches = runtime().block_on(nntdrive_sync::Journal::file_matches(
            Path::new(text("journalPath")?),
            Path::new(text("localPath")?),
            text("relativePath")?,
            revision,
            size,
        ));
        Ok(json!({"matches": matches}))
    })
}

/// Runs one synchronization pass for a local folder and a remote root node.
///
/// # Safety
/// All string arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn nntdrive_sync_run(
    handle: u64,
    base_url: *const c_char,
    token: *const c_char,
    root_id: *const c_char,
    local_path: *const c_char,
    journal_path: *const c_char,
    device_name: *const c_char,
) -> *mut c_char {
    guard(|| {
        let master = key(handle)?;
        let base_url = arg(base_url)?;
        let token = arg(token)?;
        let root_id: Uuid = arg(root_id)?
            .parse()
            .map_err(|_| "invalid remote root id".to_string())?;
        let local_path = arg(local_path)?;
        let journal_path = arg(journal_path)?;
        let device_name = arg(device_name)?;
        let path = Path::new(&local_path);
        if !path.is_dir() {
            return Err(format!(
                "sync folder {local_path} does not exist or is not a directory"
            ));
        }
        let mut api = ApiClient::new(base_url).map_err(|e| e.to_string())?;
        api.set_token(token);
        let cache_path = std::path::PathBuf::from(format!("{journal_path}.remote-hashes.json"));
        let mut remote = nntdrive_client::HttpRemote::with_cache(
            api,
            master.as_ref().clone(),
            root_id,
            cache_path,
        );
        let journal = runtime()
            .block_on(nntdrive_sync::Journal::open(&journal_path))
            .map_err(|e| e.to_string())?;
        let engine = nntdrive_sync::SyncEngine::new(device_name);
        let now = chrono::Utc::now().format("%Y-%m-%dT%H%M%SZ").to_string();
        let report = runtime()
            .block_on(engine.run_once(&mut remote, path, &journal, &now))
            .map_err(|e| e.to_string())?;
        serde_json::to_value(report).map_err(|e| e.to_string())
    })
}

/// Read-only comparison of one sync folder with the account.
///
/// Returns the plan a real sync would apply (uploads, downloads, deletes,
/// moves, conflicts and revisions) without writing local files, the journal or
/// remote state. A pending folder move is reported as `folder_moves_pending`
/// instead of a misleading per-file plan. The transport may refresh its own
/// local content-hash cache, exactly as a real sync run does.
///
/// # Safety
/// `request` must be NUL-terminated UTF-8 JSON. Free the result exactly once
/// with `nntdrive_string_free`. Invoke off the UI thread.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_sync_inspect(handle: u64, request: *const c_char) -> *mut c_char {
    guard(|| {
        let config: serde_json::Value =
            serde_json::from_str(&arg(request)?).map_err(|e| e.to_string())?;
        let text = |name: &str| {
            config[name]
                .as_str()
                .ok_or_else(|| format!("missing {name}"))
        };
        let master = key(handle)?;
        let root_id = text("remoteRootId")?
            .parse()
            .map_err(|_| "invalid remote root id")?;
        let local = text("localPath")?;
        let journal_path = text("journalPath")?;
        let mut api = ApiClient::new(text("baseUrl")?).map_err(|e| e.to_string())?;
        api.set_token(text("token")?);
        let mut remote = nntdrive_client::HttpRemote::with_cache(
            api,
            master.as_ref().clone(),
            root_id,
            format!("{journal_path}.remote-hashes.json"),
        );
        let excluded: Vec<String> =
            serde_json::from_value(config.get("excluded").cloned().unwrap_or(json!([])))
                .map_err(|e| e.to_string())?;
        let engine = nntdrive_sync::SyncEngine::new(text("deviceName")?).with_exclusions(excluded);
        let now = chrono::Utc::now().format("%Y-%m-%dT%H%M%SZ").to_string();
        let inspection = runtime()
            .block_on(engine.inspect(&mut remote, Path::new(local), Path::new(journal_path), &now))
            .map_err(|e| e.to_string())?;
        serde_json::to_value(inspection).map_err(|e| e.to_string())
    })
}

/// Sync variant with selective-sync exclusions (JSON array of relative paths).
///
/// # Safety
/// All string arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn nntdrive_sync_run_ex(
    handle: u64,
    base_url: *const c_char,
    token: *const c_char,
    root_id: *const c_char,
    local_path: *const c_char,
    journal_path: *const c_char,
    device_name: *const c_char,
    excluded_json: *const c_char,
) -> *mut c_char {
    guard(|| {
        let master = key(handle)?;
        let base_url = arg(base_url)?;
        let token = arg(token)?;
        let root_id: Uuid = arg(root_id)?
            .parse()
            .map_err(|_| "invalid remote root id".to_string())?;
        let local_path = arg(local_path)?;
        let journal_path = arg(journal_path)?;
        let device_name = arg(device_name)?;
        let excluded_raw = arg(excluded_json)?;
        let excluded: Vec<String> = if excluded_raw.trim().is_empty() {
            Vec::new()
        } else {
            serde_json::from_str(&excluded_raw).map_err(|_| "invalid exclusions JSON")?
        };
        let path = Path::new(&local_path);
        if !path.is_dir() {
            return Err(format!(
                "sync folder {local_path} does not exist or is not a directory"
            ));
        }
        let mut api = ApiClient::new(base_url).map_err(|e| e.to_string())?;
        api.set_token(token);
        let cache_path = std::path::PathBuf::from(format!("{journal_path}.remote-hashes.json"));
        let mut remote = nntdrive_client::HttpRemote::with_cache(
            api,
            master.as_ref().clone(),
            root_id,
            cache_path,
        );
        let journal = runtime()
            .block_on(nntdrive_sync::Journal::open(&journal_path))
            .map_err(|e| e.to_string())?;
        let engine = nntdrive_sync::SyncEngine::new(device_name).with_exclusions(excluded);
        let now = chrono::Utc::now().format("%Y-%m-%dT%H%M%SZ").to_string();
        let report = runtime()
            .block_on(engine.run_once(&mut remote, path, &journal, &now))
            .map_err(|e| e.to_string())?;
        serde_json::to_value(report).map_err(|e| e.to_string())
    })
}

/// Sync/resolve request with live events. Callback strings are owned by the
/// receiver and MUST be freed with `nntdrive_string_free`. The final event is
/// `{"finished":true}` even on an error; no callback occurs after it.
///
/// # Safety
/// `request` is NUL-terminated UTF-8 JSON. Callback must accept calls from any
/// thread, remain valid through the final event, and never unwind into Rust.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_sync_request(
    handle: u64,
    request: *const c_char,
    callback: Option<extern "C" fn(*mut c_char)>,
) -> *mut c_char {
    let result = guard(|| {
        let config: serde_json::Value =
            serde_json::from_str(&arg(request)?).map_err(|e| e.to_string())?;
        let text = |name: &str| {
            config[name]
                .as_str()
                .ok_or_else(|| format!("missing {name}"))
        };
        let master = key(handle)?;
        let root_id = text("remoteRootId")?
            .parse()
            .map_err(|_| "invalid remote root id")?;
        let local = text("localPath")?;
        let journal_path = text("journalPath")?;
        if !Path::new(local).is_dir() {
            return Err("sync folder is missing".into());
        }
        let mut api = ApiClient::new(text("baseUrl")?).map_err(|e| e.to_string())?;
        api.set_token(text("token")?);
        let mut remote = nntdrive_client::HttpRemote::with_cache(api, master.as_ref().clone(), root_id,
            format!("{journal_path}.remote-hashes.json")).with_progress(move |path, direction, bytes, total, complete| {
                if let Some(cb) = callback {
                    let event = json!({"path":path,"direction":direction,"bytes":bytes,"total":total,"complete":complete});
                    cb(CString::new(event.to_string()).expect("JSON contains no NUL").into_raw());
                }
            });
        let excluded: Vec<String> =
            serde_json::from_value(config.get("excluded").cloned().unwrap_or(json!([])))
                .map_err(|e| e.to_string())?;
        let engine = nntdrive_sync::SyncEngine::new(text("deviceName")?)
            .with_exclusions(excluded)
            .with_scan_observer(std::sync::Arc::new(move |paths| {
                if let Some(cb) = callback {
                    // Bounded batches of local paths the scan examined, for a
                    // live "scanning" view before any plan exists. Relative
                    // local paths only; nothing is sent to the backend.
                    cb(CString::new(scan_event(paths))
                        .expect("JSON contains no NUL")
                        .into_raw());
                }
            }))
            .with_snapshot_observer(std::sync::Arc::new(move |paths| {
                if let Some(cb) = callback {
                    // Bounded batches of remote paths the snapshot has already
                    // compared, for a live "comparing" view after the scan.
                    // Names are decrypted locally; nothing goes to the server.
                    cb(CString::new(snapshot_event(paths))
                        .expect("JSON contains no NUL")
                        .into_raw());
                }
            }))
            .with_plan_observer(std::sync::Arc::new(move |items, total| {
                if let Some(cb) = callback {
                    // Bounded batches only: the engine never sends more than
                    // its item limit, and `total` keeps truncation visible.
                    let event = json!({"phase":"plan","items":items,"total":total});
                    cb(CString::new(event.to_string())
                        .expect("JSON contains no NUL")
                        .into_raw());
                }
            }));
        let report = runtime().block_on(async {
            let journal = nntdrive_sync::Journal::open(journal_path)
                .await
                .map_err(|e| e.to_string())?;
            if let Some(choice) = config.get("choice").and_then(|v| v.as_str()) {
                engine
                    .resolve_conflict(
                        &mut remote,
                        Path::new(local),
                        &journal,
                        text("original")?,
                        text("copy")?,
                        choice,
                    )
                    .await
                    .map_err(|e| e.to_string())
            } else {
                let now = chrono::Utc::now().format("%Y-%m-%dT%H%M%SZ").to_string();
                engine
                    .run_once(&mut remote, Path::new(local), &journal, &now)
                    .await
                    .map_err(|e| e.to_string())
            }
        })?;
        serde_json::to_value(report).map_err(|e| e.to_string())
    });
    if let Some(cb) = callback {
        cb(CString::new("{\"finished\":true}").unwrap().into_raw());
    }
    result
}

/// Bounded, explicit reference backfill for the authenticated token's account.
/// No callback is retained; only the returned owned JSON string crosses the ABI.
///
/// # Safety
/// `request` must be NUL-terminated UTF-8 JSON. Free the result exactly once with
/// `nntdrive_string_free`. Invoke off the UI thread.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_backfill_references(
    handle: u64,
    request: *const c_char,
) -> *mut c_char {
    guard(|| {
        let master = key(handle)?;
        let config: serde_json::Value =
            serde_json::from_str(&arg(request)?).map_err(|_| "invalid backfill request")?;
        let mut api = ApiClient::new(config["baseUrl"].as_str().ok_or("missing baseUrl")?)
            .map_err(|_| "invalid backend URL")?;
        api.set_token(config["token"].as_str().ok_or("missing token")?);
        Ok(runtime().block_on(nntdrive_client::backfill_reference_batch(&api, &master)))
    })
}

/// Copies a current file or bounded folder subtree using guarded SDK protocols.
///
/// # Safety
/// `request` is NUL-terminated UTF-8 JSON. Free the owned result exactly once.
/// Blocking: invoke from a worker isolate. Errors never return server diagnostics.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_copy_file(handle: u64, request: *const c_char) -> *mut c_char {
    guard(|| {
        let master = key(handle)?;
        #[derive(serde::Deserialize)]
        struct Request {
            #[serde(rename = "baseUrl")]
            base_url: String,
            token: String,
            source: nntdrive_client::FileDto,
            parent_id: Option<Uuid>,
        }
        let request = arg(request)?;
        if request.len() > 32768 {
            return Err("invalid copy request".into());
        }
        let config: Request = serde_json::from_str(&request).map_err(|_| "invalid copy request")?;
        let mut api = ApiClient::new(config.base_url).map_err(|_| "invalid backend URL")?;
        api.set_token(config.token);
        let result = if config.source.is_dir {
            runtime()
                .block_on(api.copy_folder_checked(&master, &config.source, config.parent_id))
                .map(|id| (id, None))
        } else {
            runtime()
                .block_on(api.copy_file_checked(&master, &config.source, config.parent_id))
                .map(|(id, revision)| (id, Some(revision)))
        };
        let (id, revision_id) = result
            .map_err(|_| "Copy was not confirmed. The name may collide or the source or destination changed, or the folder exceeds the supported bounds. Refresh the destination before starting another copy; a lost response may already have committed.")?;
        Ok(json!({"id": id, "revision_id": revision_id}))
    })
}

/// Creates a recovery kit for an unlocked account.
///
/// The kit covers every epoch the unlocked session holds, so it can still
/// restore revisions sealed before a key rotation.
///
/// # Safety
/// Returned pointer must be freed with `nntdrive_string_free`.
#[no_mangle]
pub extern "C" fn nntdrive_recovery_kit(handle: u64) -> *mut c_char {
    guard(|| {
        let ring = key(handle)?;
        let (kit, code) =
            RecoveryKit::create_with_ring(&ring, Some("NNTDrive recovery kit".into()))
                .map_err(|e| e.to_string())?;
        Ok(json!({ "recovery_kit": kit, "recovery_code": code }))
    })
}

/// Rotates the account master key from an unlocked session and publishes it.
///
/// The request carries `baseUrl`, `token`, the password-wrapped `keyfile` this
/// device holds, the unlock `password` and optionally the account's
/// `recoveryCode` (plus a `note` for the replacement kit). The password must
/// open the supplied keyfile, and that keyfile must be the one the live handle
/// was unlocked with: rotation derives a new key-encrypting key from it, so a
/// stale or foreign keyfile would publish a keyfile this account cannot open.
///
/// An account that stores a recovery kit cannot be rotated without its current
/// recovery code, because the old kit cannot read post-rotation content. The
/// first attempt therefore returns `{"status":"recovery_code_required"}` with
/// the kit epoch; the caller asks the user for the code and retries. A
/// successful rotation returns the new keyfile, the new epoch, and — when a kit
/// was replaced — the new kit together with its one-time recovery code.
///
/// The live handle adopts the rotated ring, so the session keeps sealing with
/// the new epoch while every retained epoch stays readable.
///
/// # Safety
/// `request` is NUL-terminated UTF-8 JSON. Free the result exactly once with
/// `nntdrive_string_free`. Blocking (two KDF runs plus HTTP): invoke from a
/// worker isolate. Errors never carry key material or server diagnostics.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_rotate_account_key(
    handle: u64,
    request: *const c_char,
) -> *mut c_char {
    guard(|| {
        let ring = key(handle)?;
        #[derive(serde::Deserialize)]
        struct Request {
            #[serde(rename = "baseUrl")]
            base_url: String,
            token: String,
            keyfile: String,
            password: String,
            #[serde(rename = "recoveryCode", default)]
            recovery_code: Option<String>,
            #[serde(default)]
            note: Option<String>,
        }
        let raw = arg(request)?;
        if raw.len() > 65536 {
            return Err("invalid rotation request".into());
        }
        let config: Request = serde_json::from_str(&raw).map_err(|_| "invalid rotation request")?;
        let keyfile: KeyFile =
            serde_json::from_str(&config.keyfile).map_err(|_| "invalid keyfile")?;
        if keyfile.account_id != ring.account_id() {
            return Err("keyfile belongs to a different account".into());
        }
        if keyfile.epoch != ring.epoch() {
            return Err(
                "the stored keyfile does not match this session; unlock again before rotating"
                    .into(),
            );
        }
        // Prove the password opens this keyfile before anything is published: a
        // wrong password would otherwise seal the new epoch under a key the
        // account can never derive again.
        let master = keyfile.unlock(&config.password).map_err(|_| {
            "the password does not open this keyfile; nothing was rotated".to_string()
        })?;
        if master.epoch() != ring.epoch() {
            return Err("the stored keyfile does not match this session".into());
        }
        let mut api = ApiClient::new(config.base_url).map_err(|_| "invalid backend URL")?;
        api.set_token(config.token);
        let code = config
            .recovery_code
            .as_deref()
            .map(str::trim)
            .filter(|code| !code.is_empty());
        let note = config.note.clone();
        let outcome = runtime().block_on(async {
            match code {
                Some(code) => {
                    let kit = api
                        .recovery_kit()
                        .await
                        .map_err(|e| e.to_string())?
                        .ok_or_else(|| "this account stores no recovery kit".to_string())?;
                    let rotated = nntdrive_client::rotate_account_key_with_recovery_kit(
                        &api,
                        &keyfile,
                        &master,
                        &config.password,
                        &kit,
                        code,
                        note.clone(),
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                    Ok(json!({
                        "status": "rotated",
                        "keyfile": rotated.keyfile,
                        "epoch": rotated.keyfile.epoch,
                        "recovery_kit": rotated.recovery_kit,
                        "recovery_code": rotated.recovery_code,
                    }))
                }
                None => match nntdrive_client::rotate_account_key(
                    &api,
                    &keyfile,
                    &master,
                    &config.password,
                )
                .await
                {
                    Ok((rotated, _master)) => Ok(json!({
                        "status": "rotated",
                        "keyfile": rotated,
                        "epoch": rotated.epoch,
                    })),
                    Err(nntdrive_client::ClientError::RecoveryKitRequired { kit_epoch }) => {
                        Ok(json!({
                            "status": "recovery_code_required",
                            "kit_epoch": kit_epoch,
                        }))
                    }
                    Err(_) => Err(
                        "the account key was not rotated; another device may have rotated it, or the request did not reach the server"
                            .to_string(),
                    ),
                },
            }
        })?;
        // Adopt the rotated ring so this unlocked session seals with the new
        // epoch and still reads every retained one. If the handle disappeared
        // meanwhile (lock raced the rotation) the caller keeps the keyfile and
        // is told to unlock again.
        let mut adopted = false;
        if let Some(keyfile_json) = outcome.get("keyfile") {
            let rotated: KeyFile = serde_json::from_value(keyfile_json.clone())
                .map_err(|_| "the rotated keyfile is unreadable".to_string())?;
            let ring = rotated
                .unlock_ring(&config.password)
                .map_err(|_| "the rotated keyfile could not be opened".to_string())?;
            if let Ok(mut map) = handles().lock() {
                if let Some(slot) = map.get_mut(&handle) {
                    *slot = Arc::new(ring);
                    adopted = true;
                }
            }
        }
        let mut result = outcome;
        if let Value::Object(ref mut map) = result {
            map.insert("adopted".into(), Value::Bool(adopted));
        }
        Ok(result)
    })
}

fn base64_key(bytes: &[u8]) -> String {
    base64_bytes(bytes)
}

fn base64_bytes(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn decode_b64(value: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(value)
        .map_err(|_| "invalid base64".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_sync_rejects_locked_handle(handle: u64) {
        // A cold-start worker has no key handle. It must not touch a journal,
        // contact the backend, or attempt conflict resolution while locked.
        let root = std::env::temp_dir().join(format!("nntdrive-locked-{}", Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let server = CString::new(format!("http://{}", listener.local_addr().unwrap())).unwrap();
        let token = CString::new("test-token-not-a-real-credential").unwrap();
        let remote = CString::new(Uuid::new_v4().to_string()).unwrap();
        let local = CString::new(root.to_str().unwrap()).unwrap();
        let journal_path = root.join("journal.sqlite");
        let journal = CString::new(journal_path.to_str().unwrap()).unwrap();
        let device = CString::new("locked-worker-test").unwrap();
        let exclusions = CString::new("[]").unwrap();
        let assert_locked = |result| {
            let text = unsafe { CString::from_raw(result) };
            let value: Value = serde_json::from_slice(text.as_bytes()).unwrap();
            assert_eq!(
                value,
                json!({"ok": false, "error": "invalid or locked key handle"})
            );
        };
        unsafe {
            assert_locked(nntdrive_sync_run(
                handle,
                server.as_ptr(),
                token.as_ptr(),
                remote.as_ptr(),
                local.as_ptr(),
                journal.as_ptr(),
                device.as_ptr(),
            ));
            assert_locked(nntdrive_sync_run_ex(
                handle,
                server.as_ptr(),
                token.as_ptr(),
                remote.as_ptr(),
                local.as_ptr(),
                journal.as_ptr(),
                device.as_ptr(),
                exclusions.as_ptr(),
            ));
        }
        for choice in [None, Some("both")] {
            let mut request = json!({
                "baseUrl": server.to_str().unwrap(), "token": token.to_str().unwrap(),
                "remoteRootId": remote.to_str().unwrap(), "localPath": root,
                "journalPath": journal_path, "deviceName": "locked-worker-test", "excluded": []
            });
            if let Some(choice) = choice {
                request["choice"] = json!(choice);
                request["original"] = json!("file.txt");
                request["copy"] = json!("file (conflict test).txt");
            }
            let request = CString::new(request.to_string()).unwrap();
            unsafe {
                assert_locked(nntdrive_sync_request(handle, request.as_ptr(), None));
            }
        }
        assert_eq!(
            std::fs::read_dir(&root).unwrap().count(),
            0,
            "locked sync wrote local state"
        );
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        std::fs::remove_dir(root).unwrap();
    }

    #[test]
    fn unlock_keeps_retained_epochs_readable_through_the_bridge() {
        let password = "correct horse battery staple";
        let account_id = Uuid::new_v4();
        let (keyfile, master) = KeyFile::create(password, account_id).unwrap();
        let node = Uuid::new_v4();
        // A name sealed before another device rotates the account master key.
        let old_name = master.seal_name(node, "before rotation.txt").unwrap();
        let (rotated_keyfile, _rotated_master) = keyfile.rotate(&master, password).unwrap();
        assert_eq!(rotated_keyfile.retained.len(), 1);

        let keyfile_json = CString::new(serde_json::to_string(&rotated_keyfile).unwrap()).unwrap();
        let password_c = CString::new(password).unwrap();
        let unlocked = unsafe { nntdrive_unlock(keyfile_json.as_ptr(), password_c.as_ptr()) };
        let text = unsafe { CStr::from_ptr(unlocked).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(unlocked) };
        let unlocked: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(unlocked["ok"], true);
        assert_eq!(unlocked["epoch"], 1);
        assert_eq!(unlocked["epochs"], json!([1, 0]));
        let handle = unlocked["handle"].as_u64().unwrap();

        // The unlock keeps the previous epoch, so the old revision still opens.
        let node_c = CString::new(node.to_string()).unwrap();
        let old_b64 = CString::new(base64_bytes(&old_name.to_bytes())).unwrap();
        let opened = unsafe { nntdrive_open_name(handle, node_c.as_ptr(), old_b64.as_ptr()) };
        let opened_text = unsafe { CStr::from_ptr(opened).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(opened) };
        let opened: Value = serde_json::from_str(&opened_text).unwrap();
        assert_eq!(opened["name"], "before rotation.txt");

        // New content is sealed with the current epoch: the bridge can read it
        // back, while the pre-rotation key alone cannot authenticate it.
        let name_c = CString::new("after rotation.txt").unwrap();
        let sealed = unsafe { nntdrive_seal_name(handle, node_c.as_ptr(), name_c.as_ptr()) };
        let sealed_text = unsafe { CStr::from_ptr(sealed).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(sealed) };
        let sealed: Value = serde_json::from_str(&sealed_text).unwrap();
        let new_b64 = CString::new(sealed["name_enc"].as_str().unwrap()).unwrap();
        let envelope =
            Envelope::from_bytes(&decode_b64(new_b64.to_str().unwrap()).unwrap()).unwrap();
        assert!(master.open_name(node, &envelope).is_err());
        let reopened = unsafe { nntdrive_open_name(handle, node_c.as_ptr(), new_b64.as_ptr()) };
        let reopened_text = unsafe { CStr::from_ptr(reopened).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(reopened) };
        let reopened: Value = serde_json::from_str(&reopened_text).unwrap();
        assert_eq!(reopened["name"], "after rotation.txt");

        nntdrive_lock(handle);
        let locked = unsafe { nntdrive_open_name(handle, node_c.as_ptr(), new_b64.as_ptr()) };
        let locked_text = unsafe { CStr::from_ptr(locked).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(locked) };
        let locked: Value = serde_json::from_str(&locked_text).unwrap();
        assert_eq!(locked["error"], "invalid or locked key handle");
    }

    /// Minimal blocking JSON API for rotation tests: one canned response per
    /// (method, path) and a log of what the bridge actually sent. Requests are
    /// answered on a background thread so the bridge runs exactly as it does in
    /// the app (real reqwest call, no mocked SDK).
    struct TestApi {
        base_url: String,
        requests: Arc<Mutex<Vec<(String, String, String)>>>,
        stop: Arc<std::sync::atomic::AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    impl TestApi {
        fn start(routes: Vec<(&'static str, &'static str, Value)>) -> Self {
            use std::io::{Read, Write};
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let base_url = format!("http://{}", listener.local_addr().unwrap());
            let requests = Arc::new(Mutex::new(Vec::new()));
            let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let log = requests.clone();
            let halt = stop.clone();
            let routes: Vec<(String, String, String)> = routes
                .into_iter()
                .map(|(method, path, body)| (method.into(), path.into(), body.to_string()))
                .collect();
            let thread = std::thread::spawn(move || loop {
                if halt.load(Ordering::SeqCst) {
                    break;
                }
                let (mut stream, _) = match listener.accept() {
                    Ok(pair) => pair,
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(5));
                        continue;
                    }
                    Err(_) => break,
                };
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .unwrap();
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                let mut parsed = None;
                loop {
                    let read = match stream.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(n) => n,
                        Err(_) => break,
                    };
                    buf.extend_from_slice(&chunk[..read]);
                    if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..pos]).to_string();
                        let length = head
                            .lines()
                            .find_map(|line| {
                                let lower = line.to_ascii_lowercase();
                                lower
                                    .strip_prefix("content-length:")
                                    .map(|value| value.trim().parse::<usize>().unwrap_or(0))
                            })
                            .unwrap_or(0);
                        while buf.len() < pos + 4 + length {
                            match stream.read(&mut chunk) {
                                Ok(0) | Err(_) => break,
                                Ok(n) => buf.extend_from_slice(&chunk[..n]),
                            }
                        }
                        let body = String::from_utf8_lossy(&buf[pos + 4..]).to_string();
                        let mut parts = head.lines().next().unwrap_or("").split_whitespace();
                        parsed = Some((
                            parts.next().unwrap_or("").to_string(),
                            parts.next().unwrap_or("").to_string(),
                            body,
                        ));
                        break;
                    }
                }
                let Some((method, path, body)) = parsed else {
                    continue;
                };
                log.lock()
                    .unwrap()
                    .push((method.clone(), path.clone(), body));
                let reply = routes
                    .iter()
                    .find(|(m, p, _)| *m == method && *p == path)
                    .map(|(_, _, body)| (200, body.clone()))
                    .unwrap_or((404, "{\"message\":\"not found\"}".to_string()));
                let response = format!(
                    "HTTP/1.1 {} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    reply.0,
                    reply.1.len(),
                    reply.1
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            });
            Self {
                base_url,
                requests,
                stop,
                thread: Some(thread),
            }
        }

        fn sent(&self) -> Vec<(String, String, String)> {
            self.requests.lock().unwrap().clone()
        }
    }

    impl Drop for TestApi {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }

    fn call(ptr: *mut c_char) -> Value {
        let text = unsafe { CStr::from_ptr(ptr).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(ptr) };
        serde_json::from_str(&text).unwrap()
    }

    fn unlock_handle(keyfile: &KeyFile, password: &str) -> u64 {
        let keyfile = CString::new(serde_json::to_string(keyfile).unwrap()).unwrap();
        let password = CString::new(password).unwrap();
        let unlocked = call(unsafe { nntdrive_unlock(keyfile.as_ptr(), password.as_ptr()) });
        assert_eq!(unlocked["ok"], true, "{unlocked}");
        unlocked["handle"].as_u64().unwrap()
    }

    fn rotate_request(
        handle: u64,
        base_url: &str,
        keyfile: &KeyFile,
        password: &str,
        code: Option<&str>,
    ) -> Value {
        let mut request = json!({
            "baseUrl": base_url,
            "token": "test-token-not-a-real-credential",
            "keyfile": serde_json::to_string(keyfile).unwrap(),
            "password": password,
        });
        if let Some(code) = code {
            request["recoveryCode"] = json!(code);
        }
        let request = CString::new(request.to_string()).unwrap();
        call(unsafe { nntdrive_rotate_account_key(handle, request.as_ptr()) })
    }

    #[test]
    fn rotation_requires_the_recovery_code_and_keeps_the_live_session_readable() {
        let password = "correct horse battery staple";
        let (keyfile, master) = KeyFile::create(password, Uuid::new_v4()).unwrap();
        let (kit, code) = RecoveryKit::create(&master, Some("test kit".into())).unwrap();
        let node = Uuid::new_v4();
        let old_name = master.seal_name(node, "before rotation.txt").unwrap();
        let api = TestApi::start(vec![
            (
                "GET",
                "/api/v1/account/keyfile",
                json!({ "keyfile": keyfile, "recovery_kit": kit }),
            ),
            ("POST", "/api/v1/account/keyfile", json!({ "epoch": 1 })),
        ]);
        let handle = unlock_handle(&keyfile, password);

        // An account that stores a kit cannot be rotated silently: the old kit
        // would stop reading new content, so the bridge asks for the code first
        // and publishes nothing.
        let first = rotate_request(handle, &api.base_url, &keyfile, password, None);
        assert_eq!(first["ok"], true, "{first}");
        assert_eq!(first["status"], "recovery_code_required");
        assert_eq!(first["kit_epoch"], 0);
        assert_eq!(first["adopted"], false);
        assert!(
            !api.sent().iter().any(|(method, _, _)| method == "POST"),
            "a rotation without the recovery code published a keyfile"
        );

        // A wrong code must not publish either.
        let wrong = rotate_request(handle, &api.base_url, &keyfile, password, Some("wrong-kit"));
        assert_eq!(wrong["ok"], false, "{wrong}");
        assert!(
            !api.sent().iter().any(|(method, _, _)| method == "POST"),
            "a rotation with a wrong recovery code published a keyfile"
        );

        let rotated = rotate_request(handle, &api.base_url, &keyfile, password, Some(&code));
        assert_eq!(rotated["ok"], true, "{rotated}");
        assert_eq!(rotated["status"], "rotated");
        assert_eq!(rotated["epoch"], 1);
        assert_eq!(rotated["adopted"], true);
        let new_code = rotated["recovery_code"].as_str().unwrap();
        assert_ne!(new_code, code, "the rotation reused the old recovery code");
        let published = rotated["keyfile"].clone();
        assert_eq!(published["epoch"], 1);
        assert_eq!(published["retained"].as_array().unwrap().len(), 1);
        let posts: Vec<_> = api
            .sent()
            .into_iter()
            .filter(|(method, _, _)| method == "POST")
            .collect();
        assert_eq!(posts.len(), 1, "expected exactly one publish");
        let body: Value = serde_json::from_str(&posts[0].2).unwrap();
        assert_eq!(body["expected_epoch"], 0);
        assert_eq!(body["keyfile"]["epoch"], 1);
        assert_eq!(
            body["recovery_kit"]["epoch"], 1,
            "the publish did not replace the stored recovery kit"
        );

        // The live handle adopted the rotated ring: the pre-rotation name still
        // opens, while a name sealed now cannot be read by the old key alone.
        let node_c = CString::new(node.to_string()).unwrap();
        let old_b64 = CString::new(base64_bytes(&old_name.to_bytes())).unwrap();
        let opened = call(unsafe { nntdrive_open_name(handle, node_c.as_ptr(), old_b64.as_ptr()) });
        assert_eq!(opened["name"], "before rotation.txt");
        let name_c = CString::new("after rotation.txt").unwrap();
        let sealed = call(unsafe { nntdrive_seal_name(handle, node_c.as_ptr(), name_c.as_ptr()) });
        let envelope =
            Envelope::from_bytes(&decode_b64(sealed["name_enc"].as_str().unwrap()).unwrap())
                .unwrap();
        assert!(
            master.open_name(node, &envelope).is_err(),
            "the session sealed new content with the pre-rotation key"
        );
        let new_b64 = CString::new(sealed["name_enc"].as_str().unwrap()).unwrap();
        let reopened =
            call(unsafe { nntdrive_open_name(handle, node_c.as_ptr(), new_b64.as_ptr()) });
        assert_eq!(reopened["name"], "after rotation.txt");
        nntdrive_lock(handle);
    }

    #[test]
    fn rotation_without_a_stored_kit_publishes_only_the_keyfile() {
        let password = "correct horse battery staple";
        let (keyfile, _master) = KeyFile::create(password, Uuid::new_v4()).unwrap();
        let api = TestApi::start(vec![
            (
                "GET",
                "/api/v1/account/keyfile",
                json!({ "keyfile": keyfile, "recovery_kit": null }),
            ),
            ("POST", "/api/v1/account/keyfile", json!({ "epoch": 1 })),
        ]);
        let handle = unlock_handle(&keyfile, password);
        let rotated = rotate_request(handle, &api.base_url, &keyfile, password, None);
        assert_eq!(rotated["ok"], true, "{rotated}");
        assert_eq!(rotated["status"], "rotated");
        assert_eq!(rotated["epoch"], 1);
        assert_eq!(rotated["adopted"], true);
        assert!(rotated.get("recovery_code").is_none());
        let posts: Vec<_> = api
            .sent()
            .into_iter()
            .filter(|(method, _, _)| method == "POST")
            .collect();
        let body: Value = serde_json::from_str(&posts[0].2).unwrap();
        assert!(body.get("recovery_kit").is_none());
        nntdrive_lock(handle);
    }

    #[test]
    fn rotation_refuses_a_wrong_password_before_publishing_anything() {
        let password = "correct horse battery staple";
        let (keyfile, _master) = KeyFile::create(password, Uuid::new_v4()).unwrap();
        let api = TestApi::start(vec![
            (
                "GET",
                "/api/v1/account/keyfile",
                json!({ "keyfile": keyfile, "recovery_kit": null }),
            ),
            ("POST", "/api/v1/account/keyfile", json!({ "epoch": 1 })),
        ]);
        let handle = unlock_handle(&keyfile, password);
        let refused = rotate_request(handle, &api.base_url, &keyfile, "wrong password", None);
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(
            refused["error"],
            "the password does not open this keyfile; nothing was rotated"
        );
        assert!(
            api.sent().is_empty(),
            "a wrong password still contacted the server"
        );
        let ring = key(handle).unwrap();
        assert_eq!(ring.epoch(), 0);
        nntdrive_lock(handle);
    }

    #[test]
    fn rotation_refuses_stale_and_foreign_keyfiles() {
        let password = "correct horse battery staple";
        let account = Uuid::new_v4();
        let (keyfile, master) = KeyFile::create(password, account).unwrap();
        let api = TestApi::start(vec![
            (
                "GET",
                "/api/v1/account/keyfile",
                json!({ "keyfile": keyfile, "recovery_kit": null }),
            ),
            ("POST", "/api/v1/account/keyfile", json!({ "epoch": 1 })),
        ]);
        let handle = unlock_handle(&keyfile, password);
        let (other_keyfile, _) = KeyFile::create(password, Uuid::new_v4()).unwrap();
        let foreign = rotate_request(handle, &api.base_url, &other_keyfile, password, None);
        assert_eq!(foreign["ok"], false, "{foreign}");
        assert_eq!(foreign["error"], "keyfile belongs to a different account");

        // Move the live session to epoch 1, then offer the old epoch-0 keyfile.
        let (rotated_keyfile, _) = keyfile.rotate(&master, password).unwrap();
        let keyfile_json = CString::new(serde_json::to_string(&rotated_keyfile).unwrap()).unwrap();
        let password_c = CString::new(password).unwrap();
        let unlocked = call(unsafe { nntdrive_unlock(keyfile_json.as_ptr(), password_c.as_ptr()) });
        let rotated_handle = unlocked["handle"].as_u64().unwrap();
        let stale = rotate_request(rotated_handle, &api.base_url, &keyfile, password, None);
        assert_eq!(stale["ok"], false, "{stale}");
        assert_eq!(
            stale["error"],
            "the stored keyfile does not match this session; unlock again before rotating"
        );
        assert!(
            !api.sent().iter().any(|(method, _, _)| method == "POST"),
            "a refused rotation published a keyfile"
        );
        nntdrive_lock(handle);
        nntdrive_lock(rotated_handle);
    }

    #[test]
    fn cold_start_sync_requires_unlock_before_network_or_journal_access() {
        assert_sync_rejects_locked_handle(0);
    }

    #[test]
    fn copy_bridge_rejects_locked_malformed_and_folder_requests() {
        fn invoke(handle: u64, request: &str) -> Value {
            let request = CString::new(request).unwrap();
            let result = unsafe { nntdrive_copy_file(handle, request.as_ptr()) };
            let value =
                unsafe { serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()).unwrap() };
            unsafe { nntdrive_string_free(result) };
            value
        }
        assert_eq!(invoke(0, "{}")["error"], "invalid or locked key handle");
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        handles().lock().unwrap().insert(
            handle,
            Arc::new(MasterKeyRing::from(nntdrive_crypto::MasterKey::generate(
                Uuid::new_v4(),
                0,
            ))),
        );
        assert_eq!(invoke(handle, "not json")["error"], "invalid copy request");
        assert_eq!(
            invoke(handle, &"x".repeat(32769))["error"],
            "invalid copy request"
        );
        let request = json!({"baseUrl": "invalid", "token": "private-fixture",
            "source": {"id": Uuid::new_v4(), "parent_id": null, "name_enc": "opaque",
                "is_dir": true, "size": 0, "favorite": false, "revision": 1, "current_version": null},
            "parent_id": null});
        assert!(invoke(handle, &request.to_string())["error"]
            .as_str()
            .unwrap()
            .contains("Refresh"));
        nntdrive_lock(handle);
    }

    #[test]
    fn abi_version_is_stable() {
        assert_eq!(nntdrive_abi_version(), 1);
    }

    #[test]
    fn canonical_name_comparison_policy() {
        fn comparison(name: &str) -> Value {
            let name = CString::new(name).unwrap();
            let result = unsafe { nntdrive_name_collision_key(name.as_ptr()) };
            let value =
                unsafe { serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()) }.unwrap();
            unsafe { nntdrive_string_free(result) };
            value
        }
        for (a, b) in [
            ("Café.TXT", "CAFE\u{301}.txt"),
            ("a\u{323}\u{302}", "a\u{302}\u{323}"),
            ("가", "\u{1100}\u{1161}"),
            ("İ", "i\u{307}"),
        ] {
            let key = comparison(a);
            assert_eq!(key["ok"], true);
            assert_eq!(key, comparison(b));
            assert_eq!(key, comparison(key["comparison"].as_str().unwrap()));
        }
        for (a, b) in [("cafe", "café"), ("①", "1"), ("ß", "ss"), ("ς", "σ")] {
            assert_ne!(comparison(a), comparison(b));
        }
        let result = unsafe { nntdrive_name_collision_key(std::ptr::null()) };
        let value: Value =
            unsafe { serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()) }.unwrap();
        unsafe { nntdrive_string_free(result) };
        assert_eq!(value["ok"], false);
    }

    #[test]
    fn account_creation_and_sealing_roundtrip() {
        let password = CString::new("correct horse battery staple").unwrap();
        let created = unsafe { nntdrive_generate_account(password.as_ptr()) };
        let text = unsafe { CStr::from_ptr(created).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(created) };
        let value: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["ok"], true);
        assert!(value["recovery_code"]
            .as_str()
            .unwrap()
            .starts_with("NNTR-"));

        let keyfile = value["keyfile"].to_string();
        let keyfile_c = CString::new(keyfile).unwrap();
        let unlocked = unsafe { nntdrive_unlock(keyfile_c.as_ptr(), password.as_ptr()) };
        let text = unsafe { CStr::from_ptr(unlocked).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(unlocked) };
        let unlocked: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(unlocked["ok"], true);
        let handle = unlocked["handle"].as_u64().unwrap();

        let node = Uuid::new_v4();
        let node_c = CString::new(node.to_string()).unwrap();
        let name_c = CString::new("Steuererklärung 2025.pdf").unwrap();
        let sealed = unsafe { nntdrive_seal_name(handle, node_c.as_ptr(), name_c.as_ptr()) };
        let sealed_text = unsafe { CStr::from_ptr(sealed).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(sealed) };
        let sealed: Value = serde_json::from_str(&sealed_text).unwrap();
        let b64 = CString::new(sealed["name_enc"].as_str().unwrap()).unwrap();

        let opened = unsafe { nntdrive_open_name(handle, node_c.as_ptr(), b64.as_ptr()) };
        let opened_text = unsafe { CStr::from_ptr(opened).to_str().unwrap().to_string() };
        unsafe { nntdrive_string_free(opened) };
        let opened: Value = serde_json::from_str(&opened_text).unwrap();
        assert_eq!(opened["name"], "Steuererklärung 2025.pdf");
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        std::fs::create_dir(&root).unwrap();
        let empty = root.join("empty");
        std::fs::write(&empty, b"").unwrap();
        let journal = dir.path().join("journal.sqlite");
        let revision = Uuid::new_v4();
        runtime().block_on(async {
            let j = nntdrive_sync::Journal::open(&journal).await.unwrap();
            j.upsert(&nntdrive_sync::BaselineEntry {
                path: "empty".into(),
                size: 0,
                revision: Some(revision),
                content_hash: Some(nntdrive_sync::scanner::hash_file(&empty).unwrap()),
                ..Default::default()
            })
            .await
            .unwrap();
        });
        let inspect = |revision: Uuid| {
            let request = CString::new(
                json!({
                    "handle": handle, "journalPath": journal, "localPath": root,
                    "relativePath": "empty", "revision": revision, "size": 0,
                })
                .to_string(),
            )
            .unwrap();
            let result = unsafe { nntdrive_local_file_matches(request.as_ptr()) };
            let value: Value =
                unsafe { serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()).unwrap() };
            unsafe { nntdrive_string_free(result) };
            value
        };
        assert_eq!(inspect(revision)["matches"], true);
        assert_eq!(inspect(Uuid::new_v4())["matches"], false);
        nntdrive_lock(handle);
        assert_eq!(inspect(revision)["ok"], false);
        assert!(key(handle).is_err());
        assert_sync_rejects_locked_handle(handle);
    }

    #[test]
    fn scan_event_names_relative_paths_and_directory_flags_only() {
        let paths = vec![
            nntdrive_sync::ScannedPath {
                path: "notes".into(),
                is_dir: true,
            },
            nntdrive_sync::ScannedPath {
                path: "notes/todo.txt".into(),
                is_dir: false,
            },
        ];
        let value: Value = serde_json::from_str(&scan_event(&paths)).unwrap();
        assert_eq!(value["phase"], "scan");
        assert_eq!(
            value["items"],
            json!([
                {"path": "notes", "is_dir": true},
                {"path": "notes/todo.txt", "is_dir": false},
            ])
        );
        let empty: Value = serde_json::from_str(&scan_event(&[])).unwrap();
        assert_eq!(empty["phase"], "scan");
        assert_eq!(
            empty["items"],
            json!([]),
            "an empty batch stays a valid event"
        );
    }

    #[test]
    fn snapshot_event_names_compared_remote_paths_only() {
        let paths = vec![
            nntdrive_sync::ScannedPath {
                path: "notes".into(),
                is_dir: true,
            },
            nntdrive_sync::ScannedPath {
                path: "notes/todo.txt".into(),
                is_dir: false,
            },
        ];
        let value: Value = serde_json::from_str(&snapshot_event(&paths)).unwrap();
        assert_eq!(value["phase"], "compare");
        assert_eq!(
            value["items"],
            json!([
                {"path": "notes", "is_dir": true},
                {"path": "notes/todo.txt", "is_dir": false},
            ])
        );
        let empty: Value = serde_json::from_str(&snapshot_event(&[])).unwrap();
        assert_eq!(empty["phase"], "compare");
        assert_eq!(empty["items"], json!([]));
    }

    #[test]
    fn free_space_reports_a_positive_available_byte_count() {
        // A real statfs/GetDiskFreeSpaceEx read on a directory that exists.
        let dir = std::env::temp_dir().join(format!("nntdrive-free-space-{}", Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let free = free_space_bytes(&dir);
        std::fs::remove_dir(&dir).unwrap();
        let free = free.expect("the temp filesystem should report free space");
        assert!(free > 0, "free space should be a positive byte count");
    }

    #[test]
    fn free_space_reports_null_for_a_missing_directory() {
        let missing = std::env::temp_dir().join(format!("nntdrive-missing-{}", Uuid::new_v4()));
        let path = CString::new(missing.to_str().unwrap()).unwrap();
        let text = unsafe { CString::from_raw(nntdrive_free_space(path.as_ptr())) };
        let value: Value = serde_json::from_slice(text.as_bytes()).unwrap();
        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().is_some());
        assert!(value.get("freeBytes").is_none());
    }
}
