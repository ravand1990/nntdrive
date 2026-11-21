//! AMK epoch rotation through the real API: the rotating device publishes a
//! keyfile that keeps the previous epoch, remaining devices fetch it, and a
//! revoked device loses access to both the keyfile and new content.

use super::*;
use nntdrive_client::ClientError;

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
