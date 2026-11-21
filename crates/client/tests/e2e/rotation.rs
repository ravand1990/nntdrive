//! AMK epoch rotation through the real API: the rotating device publishes a
//! keyfile that keeps the previous epoch, remaining devices fetch it, and a
//! revoked device loses access to both the keyfile and new content.

use super::*;
use nntdrive_client::{download_file, upload_file, ClientError};

const PASSWORD: &str = "correct horse battery staple";

#[tokio::test]
async fn rotation_publishes_a_keyfile_that_keeps_old_revisions_readable() {
    let Some(s) = stack().await else { return };
    let mut api = ApiClient::new(s.base_url.clone()).unwrap();
    api.set_token(s.token.clone());

    // The stored keyfile is the one created at registration.
    let stored = api.account_keyfile().await.unwrap();
    assert_eq!(stored, serde_json::to_value(&s.keyfile).unwrap());

    // A revision sealed under the current epoch before the rotation.
    let node = Uuid::new_v4();
    let old_name = s.master.seal_name(node, "before rotation.txt").unwrap();
    let old_chunk_id = Uuid::new_v4();
    let old_plaintext = b"revision written before the rotation";
    let old_hash = *blake3::hash(old_plaintext).as_bytes();
    let old_chunk = s
        .master
        .seal_chunk(
            old_chunk_id,
            &old_hash,
            old_plaintext.len() as u64,
            0,
            old_plaintext,
        )
        .unwrap();

    let (rotated_keyfile, rotated_master) =
        nntdrive_client::rotate_account_key(&api, &s.keyfile, &s.master, PASSWORD)
            .await
            .unwrap();
    assert_eq!(rotated_master.epoch(), 1);
    assert_eq!(rotated_keyfile.retained.len(), 1);

    // The server now holds the rotated keyfile, and a repeat publish is a no-op.
    let published = api.account_keyfile().await.unwrap();
    assert_eq!(published, serde_json::to_value(&rotated_keyfile).unwrap());
    assert_eq!(api.publish_keyfile(&rotated_keyfile, 0).await.unwrap(), 1);

    // Another device fetches the published keyfile and can read both revisions.
    let fetched: KeyFile = serde_json::from_value(published).unwrap();
    let ring = fetched.unlock_ring(PASSWORD).unwrap();
    assert_eq!(ring.epochs().collect::<Vec<_>>(), vec![1, 0]);
    assert_eq!(
        ring.open_name(node, &old_name).unwrap(),
        "before rotation.txt"
    );
    assert_eq!(
        ring.open_chunk(
            old_chunk_id,
            &old_hash,
            old_plaintext.len() as u64,
            0,
            &old_chunk
        )
        .unwrap(),
        old_plaintext.to_vec()
    );
    let new_name = rotated_master
        .seal_name(node, "after rotation.txt")
        .unwrap();
    assert_eq!(
        ring.open_name(node, &new_name).unwrap(),
        "after rotation.txt"
    );
    // The pre-rotation key alone cannot read the new epoch.
    assert!(s.master.open_name(node, &new_name).is_err());

    // Revoking this device cuts off the keyfile fetch, so it cannot learn the
    // new epoch even though it still holds the old one.
    let http = reqwest::Client::new();
    let revoked = http
        .delete(format!("{}/api/v1/devices/{}", s.base_url, s.device_id))
        .bearer_auth(&s.token)
        .send()
        .await
        .unwrap();
    assert_eq!(revoked.status(), reqwest::StatusCode::OK);
    let denied = http
        .get(format!("{}/api/v1/account/keyfile", s.base_url))
        .bearer_auth(&s.token)
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), reqwest::StatusCode::UNAUTHORIZED);
    assert!(api.account_keyfile().await.is_err());
}

#[tokio::test]
async fn rotation_publish_rejects_stale_and_foreign_writers() {
    let Some(s) = stack().await else { return };
    let mut api = ApiClient::new(s.base_url.clone()).unwrap();
    api.set_token(s.token.clone());
    let stored = serde_json::to_value(&s.keyfile).unwrap();

    // A wrong expected epoch is rejected before anything is stored, so a failed
    // local rotation cannot replace the working keyfile.
    let (first, _) = s.keyfile.rotate(&s.master, PASSWORD).unwrap();
    let err = api
        .publish_keyfile(&first, s.keyfile.epoch + 5)
        .await
        .unwrap_err();
    match err {
        ClientError::Api { status, .. } => assert_eq!(status, 400),
        other => panic!("unexpected error: {other}"),
    }
    assert_eq!(api.account_keyfile().await.unwrap(), stored);

    // A second writer that rotated from the same old epoch is refused, so two
    // concurrent rotations cannot silently fork the account key.
    assert_eq!(api.publish_keyfile(&first, 0).await.unwrap(), 1);
    let (stale, _) = s.keyfile.rotate(&s.master, PASSWORD).unwrap();
    let err = api.publish_keyfile(&stale, 0).await.unwrap_err();
    match err {
        ClientError::Api { status, .. } => assert_eq!(status, 409),
        other => panic!("unexpected error: {other}"),
    }
    assert_eq!(
        api.account_keyfile().await.unwrap(),
        serde_json::to_value(&first).unwrap()
    );

    // A keyfile that belongs to another account is refused outright.
    let (foreign_keyfile, foreign_master) = KeyFile::create(PASSWORD, Uuid::new_v4()).unwrap();
    let (foreign_rotated, _) = foreign_keyfile.rotate(&foreign_master, PASSWORD).unwrap();
    let err = api
        .publish_keyfile(&foreign_rotated, foreign_keyfile.epoch)
        .await
        .unwrap_err();
    match err {
        ClientError::Api { status, .. } => assert_eq!(status, 403),
        other => panic!("unexpected error: {other}"),
    }
}

/// The real SDK upload/download path the app calls through FFI: a revision
/// uploaded before a rotation and one uploaded after it must both download with
/// the ring a second device gets from the published keyfile.
#[tokio::test]
async fn rotation_keeps_sdk_uploads_and_downloads_readable_across_epochs() {
    let Some(s) = stack().await else { return };
    let mut api = ApiClient::new(s.base_url.clone()).unwrap();
    api.set_token(s.token.clone());
    let dir = tempfile::tempdir().unwrap();

    // Revision uploaded while epoch 0 is current.
    let before_id = create_node(&api, &s.master, "before.bin").await;
    let before_path = dir.path().join("before.bin");
    let before_bytes = vec![7u8; 12_345];
    tokio::fs::write(&before_path, &before_bytes).await.unwrap();
    upload_file(
        &api,
        &s.master,
        before_id,
        Uuid::new_v4(),
        None,
        &before_path,
    )
    .await
    .unwrap();

    // Rotate and publish, then reopen the keyfile the way another device does.
    let (rotated_keyfile, _) =
        nntdrive_client::rotate_account_key(&api, &s.keyfile, &s.master, PASSWORD)
            .await
            .unwrap();
    assert!(rotated_keyfile.retained.len() == 1);
    let published = api.account_keyfile().await.unwrap();
    let ring = serde_json::from_value::<KeyFile>(published)
        .unwrap()
        .unlock_ring(PASSWORD)
        .unwrap();
    assert_eq!(ring.epochs().collect::<Vec<_>>(), vec![1, 0]);

    // Revision uploaded after the rotation seals with the current epoch.
    let after_id = create_node(&api, &ring, "after.bin").await;
    let after_path = dir.path().join("after.bin");
    let after_bytes = vec![9u8; 4_096];
    tokio::fs::write(&after_path, &after_bytes).await.unwrap();
    upload_file(&api, &ring, after_id, Uuid::new_v4(), None, &after_path)
        .await
        .unwrap();

    // Both revisions download through the ring (old manifest and chunk epoch
    // included), which is what the native handle now holds.
    let before_out = dir.path().join("before.out");
    download_file(&api, &ring, before_id, None, &before_out)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&before_out).await.unwrap(), before_bytes);
    let after_out = dir.path().join("after.out");
    download_file(&api, &ring, after_id, None, &after_out)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&after_out).await.unwrap(), after_bytes);

    // The pre-rotation key alone cannot authenticate the newer revision.
    let denied = download_file(
        &api,
        &s.master,
        after_id,
        None,
        &dir.path().join("denied.out"),
    )
    .await;
    assert!(denied.is_err());
}
