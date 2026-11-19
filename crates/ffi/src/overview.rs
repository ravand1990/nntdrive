//! Overview-only owned cursors. At most one admitted snapshot per unlocked
//! session; lock order is always key registry then cursor registry. Callers must
//! drain admitted operations before key revocation, as for other native work.
use super::*;
use nntdrive_sync::inspection_pages::{InspectionCursor, OVERVIEW_PAGE_LIMIT};

struct Slot {
    id: u64,
    limit: usize,
    cursor: Option<InspectionCursor>,
}
static CURSORS: OnceLock<Mutex<HashMap<u64, Slot>>> = OnceLock::new();
static NEXT_CURSOR: AtomicU64 = AtomicU64::new(1);

#[cfg(test)]
#[path = "overview_tests.rs"]
mod tests;
fn cursors() -> &'static Mutex<HashMap<u64, Slot>> {
    CURSORS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(super) fn revoke(handle: u64) {
    if let Ok(mut slots) = cursors().lock() {
        slots.remove(&handle);
    }
}

// Removes opening slots after every error or panic, but never another attempt.
struct Reservation {
    handle: u64,
    id: u64,
    published: bool,
}
impl Reservation {
    fn begin(handle: u64, limit: usize) -> Result<(Self, MasterKey), String> {
        if !(1..=OVERVIEW_PAGE_LIMIT).contains(&limit) {
            return Err("invalid overview page size".into());
        }
        let keys = handles().lock().map_err(|_| "key registry unavailable")?;
        let master = keys
            .get(&handle)
            .cloned()
            .ok_or("invalid or locked key handle")?;
        let mut slots = cursors()
            .lock()
            .map_err(|_| "overview registry unavailable")?;
        if slots.contains_key(&handle) {
            return Err("an overview inspection is already active".into());
        }
        let id = NEXT_CURSOR.fetch_add(1, Ordering::SeqCst);
        slots.insert(
            handle,
            Slot {
                id,
                limit,
                cursor: None,
            },
        );
        Ok((
            Self {
                handle,
                id,
                published: false,
            },
            master,
        ))
    }

    fn publish(mut self, cursor: InspectionCursor) -> Result<Value, String> {
        let keys = handles().lock().map_err(|_| "key registry unavailable")?;
        if !keys.contains_key(&self.handle) {
            return Err("invalid or locked key handle".into());
        }
        let mut slots = cursors()
            .lock()
            .map_err(|_| "overview registry unavailable")?;
        let slot = slots
            .get_mut(&self.handle)
            .filter(|slot| slot.id == self.id)
            .ok_or("overview inspection was cancelled")?;
        slot.cursor = Some(cursor);
        self.published = true;
        Ok(json!({"cursor": self.id}))
    }
}
impl Drop for Reservation {
    fn drop(&mut self) {
        if !self.published {
            if let Ok(mut slots) = cursors().lock() {
                if slots
                    .get(&self.handle)
                    .is_some_and(|slot| slot.id == self.id)
                {
                    slots.remove(&self.handle);
                }
            }
        }
    }
}

/// Builds a complete safe comparison before publishing a session-owned cursor.
/// No filesystem scan, remote request or journal read is repeated by paging.
/// `pageSize` is optional (default/max 256); all record arrays share that budget.
///
/// # Safety
/// `request` must be NUL-terminated UTF-8 JSON, using the legacy inspection
/// request fields plus optional `pageSize`. Free the result exactly once.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_sync_overview_open(
    handle: u64,
    request: *const c_char,
) -> *mut c_char {
    guard(|| {
        let config: Value = serde_json::from_str(&arg(request)?)
            .map_err(|_| "invalid overview inspection request")?;
        let limit = match config.get("pageSize") {
            None => OVERVIEW_PAGE_LIMIT,
            Some(value) => value
                .as_u64()
                .and_then(|n| usize::try_from(n).ok())
                .ok_or("invalid overview page size")?,
        };
        let (reservation, master) = Reservation::begin(handle, limit)?;
        let text = |name: &str| {
            config[name]
                .as_str()
                .ok_or("invalid overview inspection field")
        };
        let root_id = text("remoteRootId")?
            .parse()
            .map_err(|_| "invalid remote root id")?;
        let local = text("localPath")?;
        let journal = text("journalPath")?;
        let mut api = ApiClient::new(text("baseUrl")?).map_err(|_| "invalid overview server")?;
        api.set_token(text("token")?);
        let mut remote = nntdrive_client::HttpRemote::with_cache(
            api,
            master,
            root_id,
            format!("{journal}.remote-hashes.json"),
        );
        let excluded: Vec<String> =
            serde_json::from_value(config.get("excluded").cloned().unwrap_or(json!([])))
                .map_err(|_| "invalid overview exclusions")?;
        let engine = nntdrive_sync::SyncEngine::new(text("deviceName")?).with_exclusions(excluded);
        let now = chrono::Utc::now().format("%Y-%m-%dT%H%M%SZ").to_string();
        let cursor = runtime()
            .block_on(engine.inspect_overview(
                &mut remote,
                Path::new(local),
                Path::new(journal),
                &now,
            ))
            .map_err(|_| "overview comparison unavailable")?;
        reservation.publish(cursor)
    })
}

fn page(handle: u64, config: Value) -> Result<Value, String> {
    let id = config["cursor"].as_u64().ok_or("invalid overview cursor")?;
    let close = match config["operation"].as_str() {
        Some("next") => false,
        Some("close") => true,
        _ => return Err("invalid overview operation".into()),
    };
    let keys = handles().lock().map_err(|_| "key registry unavailable")?;
    if !keys.contains_key(&handle) {
        return Err("invalid or locked key handle".into());
    }
    let mut slots = cursors()
        .lock()
        .map_err(|_| "overview registry unavailable")?;
    // Close is idempotent after natural completion, but a foreign/stale token
    // never consumes or closes a different session's current cursor.
    if close && !slots.contains_key(&handle) {
        return Ok(json!({"closed": true}));
    }
    let slot = slots
        .get_mut(&handle)
        .filter(|slot| slot.id == id)
        .ok_or("invalid overview cursor")?;
    if close {
        slots.remove(&handle);
        return Ok(json!({"closed": true}));
    }
    let cursor = slot
        .cursor
        .as_mut()
        .ok_or("overview comparison is not ready")?;
    let page = cursor.next_page(slot.limit).map_err(str::to_string)?;
    let done = page.done;
    // Serialize while owning the registry slot, so another request cannot
    // advance before serialization completes. On failure release the snapshot.
    let result = serde_json::to_value(page).map_err(|_| "overview page unavailable".into());
    if done || result.is_err() {
        slots.remove(&handle);
    }
    result
}

/// Advances or closes an owned cursor. A terminal page frees the cursor.
/// Request: `{"cursor": <id>, "operation": "next" | "close"}`.
///
/// # Safety
/// `request` must be NUL-terminated UTF-8 JSON. Free the result exactly once.
#[no_mangle]
pub unsafe extern "C" fn nntdrive_sync_overview_page(
    handle: u64,
    request: *const c_char,
) -> *mut c_char {
    guard(|| {
        let config =
            serde_json::from_str(&arg(request)?).map_err(|_| "invalid overview page request")?;
        page(handle, config)
    })
}
