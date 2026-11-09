use super::*;
use serde_json::Value;

async fn node(s: &Stack, api: &ApiClient, parent: Option<Uuid>, name: &str, is_dir: bool) -> Uuid {
    let id = Uuid::new_v4();
    api.create_file(
        id,
        parent,
        s.master.seal_name(id, name).unwrap().to_bytes(),
        is_dir,
    )
    .await
    .unwrap();
    id
}
async fn tree_snapshot(s: &Stack, root: Uuid) -> Value {
    reqwest::Client::new()
        .get(format!(
            "{}/api/v1/files/{root}/copy-tree-snapshot",
            s.base_url
        ))
        .bearer_auth(&s.token)
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap()
}
async fn payload(s: &Stack, api: &ApiClient, root: Uuid, destination: Uuid) -> Value {
    let source = tree_snapshot(s, root).await;
    let mut nodes = Vec::new();
    for n in source.as_array().unwrap() {
        let id: Uuid = serde_json::from_value(n["id"].clone()).unwrap();
        if n["is_dir"] == true {
            let fresh = Uuid::new_v4();
            let name = s
                .master
                .open_name(
                    id,
                    &nntdrive_crypto::Envelope::from_bytes(&base64_decode(
                        n["name_enc"].as_str().unwrap(),
                    ))
                    .unwrap(),
                )
                .unwrap();
            nodes.push(json!({"source_id":id,"id":fresh,"name_enc":base64(&s.master.seal_name(fresh,&name).unwrap().to_bytes()),"revision_id":null,"sealed_manifest":null,"chunk_ids":[]}));
        } else {
            let revision = serde_json::from_value(n["current_version"].clone()).unwrap();
            let (manifest, _) = api.manifest(id, Some(revision)).await.unwrap();
            let c = nntdrive_client::copy::prepare_file_copy(
                &s.master,
                id,
                revision,
                &base64_decode(n["name_enc"].as_str().unwrap()),
                &manifest,
            )
            .unwrap();
            nodes.push(json!({"source_id":id,"id":c.file_id,"name_enc":base64(&c.name_enc),"revision_id":c.revision_id,"sealed_manifest":base64(&c.sealed_manifest),"chunk_ids":c.chunk_ids}));
        }
    }
    let siblings = api
        .list_files(Some(destination))
        .await
        .unwrap()
        .iter()
        .map(|s| json!({"id":s.id,"name_enc":s.name_enc}))
        .collect::<Vec<_>>();
    json!({"source":source,"nodes":nodes,"parent_id":destination,"siblings":siblings})
}
async fn post(s: &Stack, root: Uuid, body: &Value) -> u16 {
    reqwest::Client::new()
        .post(format!(
            "{}/api/v1/files/{root}/copy-tree-checked",
            s.base_url
        ))
        .bearer_auth(&s.token)
        .json(body)
        .send()
        .await
        .unwrap()
        .status()
        .as_u16()
}

#[tokio::test]
async fn recursive_copy_nested_empty_independent_and_gc_safe() {
    let Some(s) = stack().await else { return };
    let mut api = ApiClient::new(&s.base_url).unwrap();
    api.set_token(&s.token);
    let root = node(&s, &api, None, "Café folder", true).await;
    let nested = node(&s, &api, Some(root), "nested", true).await;
    let empty = node(&s, &api, Some(root), "empty folder", true).await;
    let file = node(&s, &api, Some(nested), "secret.txt", false).await;
    let zero = node(&s, &api, Some(nested), "zero", false).await;
    let destination = node(&s, &api, None, "destination", true).await;
    let dir = tempfile::tempdir().unwrap();
    let input = dir.path().join("in");
    let out = dir.path().join("out");
    let data = b"recursive content whose source can disappear";
    tokio::fs::write(&input, data).await.unwrap();
    let rev = Uuid::new_v4();
    upload_file(&api, &s.master, file, rev, None, &input)
        .await
        .unwrap();
    let previous = rev;
    let rev = Uuid::new_v4();
    upload_file(&api, &s.master, file, rev, Some(previous), &input)
        .await
        .unwrap();
    let history_before: Vec<Vec<u8>> = sqlx::query_scalar("SELECT manifest FROM file_versions WHERE account_id=$1 AND file_id=$2 ORDER BY revision_id")
        .bind(s.account_id).bind(file).fetch_all(s._db.store.pool()).await.unwrap();
    assert_eq!(history_before.len(), 2);
    tokio::fs::write(&input, b"").await.unwrap();
    upload_file(&api, &s.master, zero, Uuid::new_v4(), None, &input)
        .await
        .unwrap();
    let before = tree_snapshot(&s, root).await;
    let source = api
        .list_files(None)
        .await
        .unwrap()
        .into_iter()
        .find(|n| n.id == root)
        .unwrap();
    assert!(api
        .copy_folder_checked(&s.master, &source, Some(nested))
        .await
        .is_err());
    assert!(api
        .copy_folder_checked(&s.master, &source, None)
        .await
        .is_err());
    let copied = api
        .copy_folder_checked(&s.master, &source, Some(destination))
        .await
        .unwrap();
    assert_eq!(
        tree_snapshot(&s, root).await,
        before,
        "copy must not mutate source/history"
    );
    let history_after: Vec<Vec<u8>> = sqlx::query_scalar("SELECT manifest FROM file_versions WHERE account_id=$1 AND file_id=$2 ORDER BY revision_id")
        .bind(s.account_id).bind(file).fetch_all(s._db.store.pool()).await.unwrap();
    assert_eq!(
        history_after, history_before,
        "all original sealed history must remain identical"
    );
    let tree = tree_snapshot(&s, copied).await;
    let old_ids = [root, nested, empty, file, zero];
    assert_eq!(tree.as_array().unwrap().len(), 5);
    let mut fresh = BTreeMap::new();
    for n in tree.as_array().unwrap() {
        let id: Uuid = serde_json::from_value(n["id"].clone()).unwrap();
        assert!(!old_ids.contains(&id));
        let name = s
            .master
            .open_name(
                id,
                &nntdrive_crypto::Envelope::from_bytes(&base64_decode(
                    n["name_enc"].as_str().unwrap(),
                ))
                .unwrap(),
            )
            .unwrap();
        fresh.insert(name, (id, n.clone()));
    }
    assert_eq!(fresh["nested"].1["parent_id"], json!(copied));
    assert_eq!(fresh["secret.txt"].1["parent_id"], json!(fresh["nested"].0));
    assert!(api
        .list_files(Some(fresh["empty folder"].0))
        .await
        .unwrap()
        .is_empty());
    let copied_file = fresh["secret.txt"].0;
    assert_ne!(fresh["secret.txt"].1["current_version"], json!(rev));
    download_file(&api, &s.master, copied_file, None, &out)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&out).await.unwrap(), data);
    download_file(&api, &s.master, fresh["zero"].0, None, &out)
        .await
        .unwrap();
    assert!(tokio::fs::read(&out).await.unwrap().is_empty());
    // Copying a truly empty folder also uses the same atomic tree protocol.
    let empty_source = api
        .list_files(Some(root))
        .await
        .unwrap()
        .into_iter()
        .find(|n| n.id == empty)
        .unwrap();
    let empty_copy = api
        .copy_folder_checked(&s.master, &empty_source, Some(destination))
        .await
        .unwrap();
    assert!(api.list_files(Some(empty_copy)).await.unwrap().is_empty());
    // Independent writes do not change either copy's revision/content.
    tokio::fs::write(&input, b"new source version")
        .await
        .unwrap();
    upload_file(&api, &s.master, file, Uuid::new_v4(), Some(rev), &input)
        .await
        .unwrap();
    api.delete_file(root).await.unwrap();
    download_file(&api, &s.master, copied_file, None, &out)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&out).await.unwrap(), data);
    // Test-only physical source/history removal proves the copy's own references,
    // not merely the retained original history, protect chunks from actual GC.
    sqlx::query("DELETE FROM file_versions WHERE account_id=$1 AND file_id=ANY($2)")
        .bind(s.account_id)
        .bind(old_ids.to_vec())
        .execute(s._db.store.pool())
        .await
        .unwrap();
    sqlx::query("UPDATE chunks SET created_at=now()-interval '2 days' WHERE account_id=$1")
        .bind(s.account_id)
        .execute(s._db.store.pool())
        .await
        .unwrap();
    assert_eq!(
        s._db
            .store
            .collect_orphan_chunks(s.account_id, 1, 100)
            .await
            .unwrap(),
        1,
        "GC collects only the unshared source edit, not copied content"
    );
    download_file(&api, &s.master, copied_file, None, &out)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&out).await.unwrap(), data);
    let refs:i64=sqlx::query_scalar("SELECT count(*) FROM version_chunks vc JOIN file_versions v ON vc.version_id=v.id WHERE v.file_id=$1 AND v.references_complete").bind(copied_file).fetch_one(s._db.store.pool()).await.unwrap();
    assert!(refs > 0);
}

use std::collections::BTreeMap;
#[tokio::test]
async fn recursive_copy_exact_snapshots_tenants_locks_and_rollback() {
    let Some(s) = stack().await else { return };
    let mut api = ApiClient::new(&s.base_url).unwrap();
    api.set_token(&s.token);
    let root = node(&s, &api, None, "source", true).await;
    let child = node(&s, &api, Some(root), "child", true).await;
    let file = node(&s, &api, Some(child), "file", false).await;
    let destination = node(&s, &api, None, "destination", true).await;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("in");
    tokio::fs::write(&path, b"protected").await.unwrap();
    upload_file(&api, &s.master, file, Uuid::new_v4(), None, &path)
        .await
        .unwrap();
    let valid = payload(&s, &api, root, destination).await;
    for (field, value) in [
        ("source", json!(vec![valid["source"][0].clone(); 257])),
        (
            "siblings",
            json!(vec![
                json!({"id":root,"name_enc":valid["source"][0]["name_enc"]});
                4097
            ]),
        ),
    ] {
        let mut oversized = valid.clone();
        oversized[field] = value;
        assert_eq!(post(&s, root, &oversized).await, 400, "bounded {field}");
    }
    for (field, value) in [
        ("name_enc", json!(base64(&vec![1u8; 8193]))),
        (
            "sealed_manifest",
            json!(base64(&vec![1u8; 1024 * 1024 + 1])),
        ),
        ("chunk_ids", json!(vec![Uuid::new_v4(); 4097])),
    ] {
        let mut oversized = valid.clone();
        let n = oversized["nodes"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|n| n["source_id"] == json!(file))
            .unwrap();
        n[field] = value;
        assert_eq!(
            post(&s, root, &oversized).await,
            400,
            "bounded candidate {field}"
        );
    }
    let added = node(&s, &api, Some(child), "added", true).await;
    assert_eq!(
        post(&s, root, &valid).await,
        409,
        "added descendant must invalidate exact subtree"
    );
    api.delete_file(added).await.unwrap();
    let old = valid["source"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == json!(child))
        .unwrap()["name_enc"]
        .as_str()
        .unwrap();
    api.rename_file(
        child,
        &base64(&s.master.seal_name(child, "renamed").unwrap().to_bytes()),
    )
    .await
    .unwrap();
    assert_eq!(post(&s, root, &valid).await, 409);
    api.rename_file(child, old).await.unwrap();
    api.move_file(child, Some(destination)).await.unwrap();
    assert_eq!(post(&s, root, &valid).await, 409);
    api.move_file(child, Some(root)).await.unwrap();
    let sibling = node(&s, &api, Some(destination), "added destination", true).await;
    assert_eq!(
        post(&s, root, &valid).await,
        409,
        "added destination invalidates empty guard"
    );
    api.delete_file(sibling).await.unwrap();
    for field in ["current_version", "size", "parent_id", "name_enc"] {
        let mut bad = valid.clone();
        let n = bad["source"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|n| n["id"] == json!(file))
            .unwrap();
        n[field] = match field {
            "current_version" | "parent_id" => json!(Uuid::new_v4()),
            "size" => json!(99),
            _ => json!(base64(
                &s.master.seal_name(file, "stale").unwrap().to_bytes()
            )),
        };
        assert_eq!(post(&s, root, &bad).await, 409, "stale descendant {field}");
    }
    let foreign = s._db.create_account("foreign-tree@example.test").await;
    let foreign_file = s._db.create_file(foreign, None, vec![1]).await;
    for id in [foreign_file, Uuid::new_v4()] {
        let res = reqwest::Client::new()
            .get(format!(
                "{}/api/v1/files/{id}/copy-tree-snapshot",
                s.base_url
            ))
            .bearer_auth(&s.token)
            .send()
            .await
            .unwrap();
        assert_eq!(res.status(), 404);
        assert_eq!(post(&s, id, &valid).await, 404);
        let mut bad = valid.clone();
        bad["parent_id"] = json!(id);
        assert_eq!(post(&s, root, &bad).await, 404);
    }
    let foreign_chunk = Uuid::new_v4();
    sqlx::query("INSERT INTO chunks(id,account_id,plaintext_hash,plaintext_len,ciphertext_len) VALUES($1,$2,$3,1,42)").bind(foreign_chunk).bind(foreign).bind(vec![7u8;32]).execute(s._db.store.pool()).await.unwrap();
    let events: i64 = sqlx::query_scalar("SELECT count(*) FROM sync_events WHERE account_id=$1")
        .bind(s.account_id)
        .fetch_one(s._db.store.pool())
        .await
        .unwrap();
    for chunks in [json!([]), json!([foreign_chunk]), json!([Uuid::new_v4()])] {
        let mut bad = valid.clone();
        let n = bad["nodes"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|n| n["source_id"] == json!(file))
            .unwrap();
        n["chunk_ids"] = chunks;
        assert_eq!(
            post(&s, root, &bad).await,
            400,
            "failure after parent inserts must roll back"
        );
        for n in valid["nodes"].as_array().unwrap() {
            let id: Uuid = serde_json::from_value(n["id"].clone()).unwrap();
            let count: i64 = sqlx::query_scalar("SELECT count(*) FROM files WHERE id=$1")
                .bind(id)
                .fetch_one(s._db.store.pool())
                .await
                .unwrap();
            assert_eq!(count, 0);
        }
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM sync_events WHERE account_id=$1")
            .bind(s.account_id)
            .fetch_one(s._db.store.pool())
            .await
            .unwrap();
        assert_eq!(count, events);
    }
    for lock in [
        "SELECT pg_advisory_xact_lock(hashtext($1))",
        "SELECT id FROM accounts WHERE id=$1::uuid FOR UPDATE",
    ] {
        let mut tx = s._db.store.pool().begin().await.unwrap();
        sqlx::query(lock)
            .bind(s.account_id.to_string())
            .execute(&mut *tx)
            .await
            .unwrap();
        let url = format!("{}/api/v1/files/{root}/copy-tree-checked", s.base_url);
        let token = s.token.clone();
        let mut bad = valid.clone();
        bad["source"].as_array_mut().unwrap().pop();
        bad["nodes"].as_array_mut().unwrap().pop();
        let mut request = tokio::spawn(async move {
            reqwest::Client::new()
                .post(url)
                .bearer_auth(token)
                .json(&bad)
                .send()
                .await
                .unwrap()
        });
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(100), &mut request)
                .await
                .is_err()
        );
        tx.rollback().await.unwrap();
        assert_eq!(request.await.unwrap().status(), 409);
    }
    let mut within = valid.clone();
    within["parent_id"] = json!(child);
    assert_eq!(post(&s, root, &within).await, 400);
    let mut reused = valid.clone();
    reused["nodes"][0]["id"] = json!(destination);
    assert_eq!(post(&s, root, &reused).await, 409);
    // Reverse request order: server remaps parents itself and publishes once.
    let mut reversed = valid.clone();
    reversed["nodes"].as_array_mut().unwrap().reverse();
    assert_eq!(post(&s, root, &reversed).await, 201);
    assert_eq!(
        post(&s, root, &reversed).await,
        409,
        "no blind duplicate replay"
    );
    let fresh = payload(&s, &api, root, destination).await;
    let (_, old_rev) = api.manifest(file, None).await.unwrap();
    upload_file(&api, &s.master, file, Uuid::new_v4(), Some(old_rev), &path)
        .await
        .unwrap();
    assert_eq!(
        post(&s, root, &fresh).await,
        409,
        "real descendant commit invalidates snapshot"
    );
    let fresh = payload(&s, &api, root, destination).await;
    api.delete_file(child).await.unwrap();
    assert_eq!(
        post(&s, root, &fresh).await,
        409,
        "deleted descendant invalidates snapshot"
    );
}

#[tokio::test]
async fn recursive_copy_names_and_resource_bounds_fail_closed() {
    let Some(s) = stack().await else { return };
    let mut api = ApiClient::new(&s.base_url).unwrap();
    api.set_token(&s.token);
    let root = node(&s, &api, None, "Folder", true).await;
    let destination = node(&s, &api, None, "destination", true).await;
    let source = api
        .list_files(None)
        .await
        .unwrap()
        .into_iter()
        .find(|n| n.id == root)
        .unwrap();
    let a = node(&s, &api, Some(root), "Café", true).await;
    let b = node(&s, &api, Some(root), "CAFE\u{301}", true).await;
    assert!(api
        .copy_folder_checked(&s.master, &source, Some(destination))
        .await
        .is_err());
    api.rename_file(
        b,
        &base64(&s.master.seal_name(b, "../unsafe").unwrap().to_bytes()),
    )
    .await
    .unwrap();
    assert!(api
        .copy_folder_checked(&s.master, &source, Some(destination))
        .await
        .is_err());
    api.rename_file(
        b,
        &base64(&s.master.seal_name(a, "substituted").unwrap().to_bytes()),
    )
    .await
    .unwrap();
    assert!(api
        .copy_folder_checked(&s.master, &source, Some(destination))
        .await
        .is_err());
    api.delete_file(b).await.unwrap();
    let clash = node(&s, &api, Some(destination), "FOLDER", true).await;
    assert!(api
        .copy_folder_checked(&s.master, &source, Some(destination))
        .await
        .is_err());
    api.delete_file(clash).await.unwrap();
    let mut parent = a;
    for _ in 0..32 {
        parent = node(&s, &api, Some(parent), "deep", true).await;
    }
    let url = format!("{}/api/v1/files/{root}/copy-tree-snapshot", s.base_url);
    assert_eq!(
        reqwest::Client::new()
            .get(&url)
            .bearer_auth(&s.token)
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    api.delete_file(a).await.unwrap();
    for i in 0..256 {
        node(&s, &api, Some(root), &format!("n{i}"), true).await;
    }
    assert_eq!(
        reqwest::Client::new()
            .get(&url)
            .bearer_auth(&s.token)
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    sqlx::query("INSERT INTO files(id,account_id,parent_id,name_enc,is_dir) SELECT gen_random_uuid(),$1,$2,decode(repeat('01',42),'hex'),true FROM generate_series(1,4097)")
        .bind(s.account_id).bind(destination).execute(s._db.store.pool()).await.unwrap();
    assert_eq!(
        reqwest::Client::new()
            .get(format!("{}/api/v1/copy-tree-destination", s.base_url))
            .query(&[("parent_id", destination)])
            .bearer_auth(&s.token)
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    let huge = json!({"padding":"x".repeat(12*1024*1024+1)});
    assert_eq!(post(&s, root, &huge).await, 413);
}
