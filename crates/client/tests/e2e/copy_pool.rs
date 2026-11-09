//! Real HTTP regressions: Copy must not acquire a second database connection
//! while its publication transaction owns the backend pool's only connection.
use super::*;
use serde_json::Value;
use std::time::Duration;

async fn fixture() -> Option<(Stack, Uuid, Uuid, Uuid, Uuid)> {
    let s = stack_with_pool_limit(Some(1)).await?;
    let mut api = ApiClient::new(&s.base_url).unwrap();
    api.set_token(&s.token);
    let root = copy_tree_tests::node(&s, &api, None, "source", true).await;
    let file = copy_tree_tests::node(&s, &api, Some(root), "data", false).await;
    let a = copy_tree_tests::node(&s, &api, None, "destination a", true).await;
    let b = copy_tree_tests::node(&s, &api, None, "destination b", true).await;
    let dir = tempfile::tempdir().unwrap();
    let input = dir.path().join("input");
    tokio::fs::write(&input, b"shared immutable copy content")
        .await
        .unwrap();
    upload_file(&api, &s.master, file, Uuid::new_v4(), None, &input)
        .await
        .unwrap();
    Some((s, root, file, a, b))
}

async fn request(s: &Stack, source: Uuid, destination: Uuid, folder: bool) -> (String, Value) {
    let mut api = ApiClient::new(&s.base_url).unwrap();
    api.set_token(&s.token);
    if folder {
        return (
            format!("{}/api/v1/files/{source}/copy-tree-checked", s.base_url),
            copy_tree_tests::payload(s, &api, source, destination).await,
        );
    }
    let parent: Option<Uuid> =
        sqlx::query_scalar("SELECT parent_id FROM files WHERE account_id=$1 AND id=$2")
            .bind(s.account_id)
            .bind(source)
            .fetch_one(s._db.store.pool())
            .await
            .unwrap();
    let source_node = api
        .list_files(parent)
        .await
        .unwrap()
        .into_iter()
        .find(|n| n.id == source)
        .unwrap();
    let revision = source_node.current_version.unwrap();
    let (manifest, _) = api.manifest(source, Some(revision)).await.unwrap();
    let copy = nntdrive_client::copy::prepare_file_copy(
        &s.master,
        source,
        revision,
        &base64_decode(&source_node.name_enc),
        &manifest,
    )
    .unwrap();
    (
        format!("{}/api/v1/files/{source}/copy-checked", s.base_url),
        json!({"source_revision":revision,"source_parent_id":source_node.parent_id,
            "source_name_enc":source_node.name_enc,"parent_id":destination,"siblings":[],
            "id":copy.file_id,"revision_id":copy.revision_id,"size":copy.size,
            "name_enc":base64(&copy.name_enc),"sealed_manifest":base64(&copy.sealed_manifest),
            "chunk_ids":copy.chunk_ids}),
    )
}

async fn send(s: &Stack, request: &(String, Value)) -> u16 {
    // The pool also has a 2s acquisition deadline: old code returns 500 instead
    // of hanging the test indefinitely. This outer deadline bounds HTTP too.
    tokio::time::timeout(Duration::from_secs(5), async {
        reqwest::Client::new()
            .post(&request.0)
            .bearer_auth(&s.token)
            .json(&request.1)
            .send()
            .await
            .unwrap()
            .status()
            .as_u16()
    })
    .await
    .expect("Copy HTTP request exhausted the one-connection pool")
}

async fn quota_regression(folder: bool) {
    let Some((s, root, file, destination, _)) = fixture().await else {
        return;
    };
    let request = request(&s, if folder { root } else { file }, destination, folder).await;
    sqlx::query("UPDATE accounts SET quota_bytes=0 WHERE id=$1")
        .bind(s.account_id)
        .execute(s._db.store.pool())
        .await
        .unwrap();
    assert_eq!(
        send(&s, &request).await,
        413,
        "quota denial must not exhaust pool"
    );
    let mut api = ApiClient::new(&s.base_url).unwrap();
    api.set_token(&s.token);
    assert!(api.list_files(Some(destination)).await.unwrap().is_empty());
    // At the exact existing physical-chunk quota, copying shared references
    // still succeeds: neither handler charges logical file bytes again.
    sqlx::query("UPDATE accounts SET quota_bytes=(SELECT SUM(plaintext_len) FROM chunks WHERE account_id=$1) WHERE id=$1")
        .bind(s.account_id).execute(s._db.store.pool()).await.unwrap();
    assert_eq!(send(&s, &request).await, 201);
    let copied = api.list_files(Some(destination)).await.unwrap();
    assert_eq!(copied.len(), 1);
    let copied_file = if folder {
        let children = api.list_files(Some(copied[0].id)).await.unwrap();
        assert_eq!(children.len(), 1);
        children[0].id
    } else {
        copied[0].id
    };
    let dir = tempfile::tempdir().unwrap();
    let output = dir.path().join("output");
    download_file(&api, &s.master, copied_file, None, &output)
        .await
        .unwrap();
    assert_eq!(
        tokio::fs::read(output).await.unwrap(),
        b"shared immutable copy content"
    );
}

#[tokio::test]
async fn file_copy_single_connection_pool() {
    quota_regression(false).await;
}

#[tokio::test]
async fn folder_copy_single_connection_pool() {
    quota_regression(true).await;
}

#[tokio::test]
async fn concurrent_file_and_folder_copy_single_connection_pool() {
    let Some((s, root, file, a, b)) = fixture().await else {
        return;
    };
    let file_request = request(&s, file, a, false).await;
    let folder_request = request(&s, root, b, true).await;
    let (file_status, folder_status) =
        tokio::join!(send(&s, &file_request), send(&s, &folder_request));
    assert_eq!((file_status, folder_status), (201, 201));
    let mut api = ApiClient::new(&s.base_url).unwrap();
    api.set_token(&s.token);
    for destination in [a, b] {
        assert_eq!(api.list_files(Some(destination)).await.unwrap().len(), 1);
    }
}
