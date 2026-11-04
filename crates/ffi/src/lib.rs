//! C ABI for the Flutter clients.
//!
//! All functions take/return UTF-8 JSON and never expose raw key material. Keys
//! stay in a process-local handle table; Dart only sees an integer handle. The
//! long-running upload/download calls block and are meant to run in a Dart
//! isolate.

use nntdrive_client::{download_file, upload_file, ApiClient};
use nntdrive_crypto::{
    derive_auth_verifier, DeviceKeypair, Envelope, KeyFile, MasterKey, RecoveryKit,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use tokio::runtime::Runtime;
use uuid::Uuid;

static HANDLES: OnceLock<Mutex<HashMap<u64, MasterKey>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn handles() -> &'static Mutex<HashMap<u64, MasterKey>> {
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

fn key(handle: u64) -> Result<MasterKey, String> {
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
        let master = keyfile.unlock(&password).map_err(|e| e.to_string())?;
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        handles()
            .lock()
            .map_err(|_| "key registry poisoned".to_string())?
            .insert(handle, master.clone());
        Ok(json!({
            "handle": handle,
            "account_id": master.account_id(),
            "epoch": master.epoch(),
        }))
    })
}

/// Drops the master key for a handle.
#[no_mangle]
pub extern "C" fn nntdrive_lock(handle: u64) {
    if let Ok(mut map) = handles().lock() {
        map.remove(&handle);
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
        let mut remote = nntdrive_client::HttpRemote::with_cache(api, master, root_id, cache_path);
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
        let mut remote = nntdrive_client::HttpRemote::with_cache(api, master, root_id, cache_path);
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

/// Creates a recovery kit for an unlocked account.
///
/// # Safety
/// Returned pointer must be freed with `nntdrive_string_free`.
#[no_mangle]
pub extern "C" fn nntdrive_recovery_kit(handle: u64) -> *mut c_char {
    guard(|| {
        let master = key(handle)?;
        let (kit, code) = RecoveryKit::create(&master, Some("NNTDrive recovery kit".into()))
            .map_err(|e| e.to_string())?;
        Ok(json!({ "recovery_kit": kit, "recovery_code": code }))
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

    #[test]
    fn abi_version_is_stable() {
        assert_eq!(nntdrive_abi_version(), 1);
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
        nntdrive_lock(handle);
        assert!(key(handle).is_err());
    }
}
