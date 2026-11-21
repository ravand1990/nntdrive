use super::*;

fn unlocked() -> u64 {
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
    handles().lock().unwrap().insert(
        handle,
        Arc::new(MasterKeyRing::from(nntdrive_crypto::MasterKey::generate(
            Uuid::new_v4(),
            0,
        ))),
    );
    handle
}

fn invoke(
    f: unsafe extern "C" fn(u64, *const c_char) -> *mut c_char,
    handle: u64,
    request: Value,
) -> Value {
    let input = CString::new(request.to_string()).unwrap();
    let text = unsafe { CString::from_raw(f(handle, input.as_ptr())) };
    serde_json::from_slice(text.as_bytes()).unwrap()
}

fn blocked_request() -> Value {
    json!({
        "baseUrl": "http://127.0.0.1:1", "token": "fixture",
        "remoteRootId": Uuid::new_v4(),
        "localPath": std::env::temp_dir().join(Uuid::new_v4().to_string()),
        "journalPath": std::env::temp_dir().join(Uuid::new_v4().to_string()),
        "deviceName": "fixture", "excluded": [], "pageSize": 1
    })
}

#[test]
fn overview_abi_scopes_tokens_and_frees_terminal_pages() {
    let handle = unlocked();
    let other = unlocked();
    let request = blocked_request();
    assert_eq!(
        invoke(nntdrive_sync_overview_open, 0, request.clone())["ok"],
        false
    );
    let opened = invoke(nntdrive_sync_overview_open, handle, request.clone());
    assert_eq!(opened["ok"], true, "{opened}");
    let id = opened["cursor"].clone();
    assert_eq!(
        invoke(nntdrive_sync_overview_open, handle, request.clone())["ok"],
        false
    );
    for operation in ["next", "close"] {
        let value = invoke(
            nntdrive_sync_overview_page,
            other,
            json!({"cursor": id, "operation": operation}),
        );
        if operation == "next" {
            assert_eq!(value["ok"], false);
        }
        assert!(cursors().lock().unwrap().contains_key(&handle));
    }
    // A wrong token on the owning session must not consume the first page.
    assert_eq!(
        invoke(
            nntdrive_sync_overview_page,
            handle,
            json!({"cursor": 0, "operation": "next"})
        )["ok"],
        false
    );
    let page = invoke(
        nntdrive_sync_overview_page,
        handle,
        json!({"cursor": id, "operation": "next"}),
    );
    assert_eq!(page["ok"], true);
    assert_eq!(page["done"], true);
    assert_eq!(page["filesystem_blocked"], "not_found");
    assert_eq!(page["delivered"], 0);
    assert!(!cursors().lock().unwrap().contains_key(&handle));
    let opened = invoke(nntdrive_sync_overview_open, handle, request);
    assert_eq!(opened["ok"], true);
    nntdrive_lock(handle);
    assert!(!cursors().lock().unwrap().contains_key(&handle));
    assert_eq!(
        invoke(
            nntdrive_sync_overview_page,
            handle,
            json!({"cursor": opened["cursor"], "operation": "next"})
        )["ok"],
        false
    );
    nntdrive_lock(other);
}

#[test]
fn overview_failed_open_and_reservation_drop_allow_retry() {
    let handle = unlocked();
    let mut request = blocked_request();
    request["remoteRootId"] = json!("bad");
    assert_eq!(
        invoke(nntdrive_sync_overview_open, handle, request)["ok"],
        false
    );
    assert!(!cursors().lock().unwrap().contains_key(&handle));
    let (reservation, _) = Reservation::begin(handle, 1).unwrap();
    assert!(Reservation::begin(handle, 1).is_err());
    drop(reservation);
    let (reservation, _) = Reservation::begin(handle, 1).unwrap();
    nntdrive_lock(handle);
    assert!(!cursors().lock().unwrap().contains_key(&handle));
    drop(reservation);
    assert!(Reservation::begin(handle, 1).is_err());
}

#[test]
fn overview_revocation_rejects_late_publication_and_panics_release_reservations() {
    let handle = unlocked();
    let opened = invoke(nntdrive_sync_overview_open, handle, blocked_request());
    assert_eq!(opened["ok"], true);
    let cursor = cursors()
        .lock()
        .unwrap()
        .remove(&handle)
        .unwrap()
        .cursor
        .unwrap();
    let (reservation, _) = Reservation::begin(handle, 1).unwrap();
    nntdrive_lock(handle);
    assert!(reservation.publish(cursor).is_err());
    assert!(!cursors().lock().unwrap().contains_key(&handle));

    let handle = unlocked();
    let panic = std::panic::catch_unwind(|| {
        let (_reservation, _) = Reservation::begin(handle, 1).unwrap();
        panic!("fixture panic after admission");
    });
    assert!(panic.is_err());
    assert!(!cursors().lock().unwrap().contains_key(&handle));
    let (reservation, _) = Reservation::begin(handle, 1).unwrap();
    drop(reservation);
    nntdrive_lock(handle);
}

#[test]
fn overview_page_size_validation_does_not_reserve_a_cursor() {
    let handle = unlocked();
    for size in [json!(0), json!(257), json!(-1), json!("1"), Value::Null] {
        let mut request = blocked_request();
        request["pageSize"] = size;
        assert_eq!(
            invoke(nntdrive_sync_overview_open, handle, request)["ok"],
            false
        );
        assert!(!cursors().lock().unwrap().contains_key(&handle));
    }
    nntdrive_lock(handle);
}
