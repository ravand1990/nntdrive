use nntdrive_storage::{FileManifest, StoreError, TestDb};
use uuid::Uuid;

async fn chunk(db: &TestDb, account: Uuid, old: bool) -> Uuid {
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO chunks(id, account_id, plaintext_hash, plaintext_len, ciphertext_len, created_at) VALUES($1,$2,$3,1,42,now() - make_interval(days => $4))")
        .bind(id).bind(account).bind(id.as_bytes().to_vec()).bind(if old { 10i32 } else { 0 }).execute(db.store.pool()).await.unwrap();
    id
}

#[tokio::test]
async fn legacy_backfill_grace_history_tenants_and_irreversible_fence() {
    let Some(db) = TestDb::create().await else {
        return;
    };
    let a = db.create_account("gc-a@example.test").await;
    let b = db.create_account("gc-b@example.test").await;
    let f = db.create_file(a, None, vec![1]).await;
    let orphan = chunk(&db, a, true).await;
    let recent = chunk(&db, a, false).await;
    let referenced = chunk(&db, a, true).await;
    let foreign = chunk(&db, b, true).await;
    let m = FileManifest::new(f, Uuid::new_v4(), 1, String::new());
    db.store
        .insert_version_with_references(a, f, &m, b"opaque", None, None, None)
        .await
        .unwrap();
    assert!(db.store.collect_orphan_chunks(a, 1, 100).await.is_err());
    let fence: bool =
        sqlx::query_scalar("SELECT reference_commits_required FROM accounts WHERE id=$1")
            .bind(a)
            .fetch_one(db.store.pool())
            .await
            .unwrap();
    assert!(
        !fence,
        "blocked collection must not change compatibility policy"
    );
    assert!(db
        .store
        .backfill_references(b, f, m.revision_id, &[foreign])
        .await
        .is_err());
    assert!(db
        .store
        .backfill_references(a, f, m.revision_id, &[foreign])
        .await
        .is_err());
    assert!(db
        .store
        .backfill_references(a, f, m.revision_id, &[Uuid::new_v4()])
        .await
        .is_err());
    db.store
        .backfill_references(a, f, m.revision_id, &[referenced, referenced])
        .await
        .unwrap();
    db.store
        .backfill_references(a, f, m.revision_id, &[referenced])
        .await
        .unwrap();
    assert!(db
        .store
        .backfill_references(a, f, m.revision_id, &[])
        .await
        .is_err());
    // Supersede and logically delete the namespace and old version. Historical
    // references must survive both, including conflict/restore-able versions.
    let latest = FileManifest::new(f, Uuid::new_v4(), 0, String::new());
    db.store
        .insert_version(a, f, &latest, b"empty", None, None)
        .await
        .unwrap();
    sqlx::query("UPDATE files SET deleted=true WHERE account_id=$1; ")
        .bind(a)
        .execute(db.store.pool())
        .await
        .unwrap();
    sqlx::query("UPDATE file_versions SET deleted=true WHERE account_id=$1")
        .bind(a)
        .execute(db.store.pool())
        .await
        .unwrap();
    assert_eq!(db.store.collect_orphan_chunks(a, 1, 100).await.unwrap(), 1);
    for id in [recent, referenced] {
        assert!(db.store.load_chunk(a, id).await.is_ok());
    }
    assert!(db.store.load_chunk(a, orphan).await.is_err());
    assert!(db.store.load_chunk(b, foreign).await.is_ok());
    let legacy = FileManifest::new(f, Uuid::new_v4(), 1, String::new());
    assert!(matches!(
        db.store
            .insert_version_with_references(a, f, &legacy, b"legacy", None, None, None)
            .await,
        Err(StoreError::Invalid(_))
    ));
    assert!(db
        .store
        .version(a, f, Some(legacy.revision_id))
        .await
        .is_err());
    // The DB fence also rejects an old backend's raw INSERT after opt-in.
    assert!(sqlx::query("INSERT INTO file_versions(id,account_id,file_id,revision_id,size,manifest) VALUES($1,$2,$3,$4,1,$5)")
        .bind(Uuid::new_v4()).bind(a).bind(f).bind(Uuid::new_v4()).bind(b"legacy".to_vec()).execute(db.store.pool()).await.is_err());
    // A direct DELETE cannot bypass the reference foreign key.
    assert!(
        sqlx::query("DELETE FROM chunks WHERE account_id=$1 AND id=$2")
            .bind(a)
            .bind(referenced)
            .execute(db.store.pool())
            .await
            .is_err()
    );
    assert_eq!(db.store.collect_orphan_chunks(a, 1, 100).await.unwrap(), 0);
    assert!(db.store.collect_orphan_chunks(a, 0, 100).await.is_err());
    assert!(db.store.collect_orphan_chunks(a, 1, 1001).await.is_err());
}

#[tokio::test]
async fn collector_commit_races_never_publish_dangling_versions() {
    let Some(db) = TestDb::create().await else {
        return;
    };
    let a = db.create_account("gc-race@example.test").await;
    let f = db.create_file(a, None, vec![1]).await;
    for _ in 0..12 {
        let id = chunk(&db, a, true).await;
        let m = FileManifest::new(f, Uuid::new_v4(), 1, String::new());
        let ids = [id];
        let (gc, commit) = tokio::join!(
            db.store.collect_orphan_chunks(a, 1, 1),
            db.store
                .insert_version_with_references(a, f, &m, b"opaque", None, None, Some(&ids))
        );
        gc.unwrap();
        if commit.is_ok() {
            assert!(db.store.load_chunk(a, id).await.is_ok());
            assert!(db.store.version(a, f, Some(m.revision_id)).await.is_ok());
        } else {
            assert!(db.store.version(a, f, Some(m.revision_id)).await.is_err());
        }
    }
    // A late reuse which already lost the collector race cannot publish.
    let gone = chunk(&db, a, true).await;
    db.store.collect_orphan_chunks(a, 1, 1000).await.unwrap();
    let m = FileManifest::new(f, Uuid::new_v4(), 1, String::new());
    assert!(db
        .store
        .insert_version_with_references(a, f, &m, b"opaque", None, None, Some(&[gone]))
        .await
        .is_err());
    assert!(db.store.version(a, f, Some(m.revision_id)).await.is_err());
}

#[tokio::test]
async fn legacy_commit_racing_gc_either_blocks_gc_or_is_refused() {
    let Some(db) = TestDb::create().await else {
        return;
    };
    for i in 0..8 {
        let a = db
            .create_account(&format!("gc-legacy-{i}@example.test"))
            .await;
        let f = db.create_file(a, None, vec![1]).await;
        let id = chunk(&db, a, true).await;
        let m = FileManifest::new(f, Uuid::new_v4(), 1, String::new());
        let (gc, commit) = tokio::join!(
            db.store.collect_orphan_chunks(a, 1, 1000),
            db.store
                .insert_version_with_references(a, f, &m, b"opaque", None, None, None)
        );
        assert!(gc.is_ok() != commit.is_ok());
        if commit.is_ok() {
            assert!(db.store.load_chunk(a, id).await.is_ok());
        } else {
            assert!(db.store.version(a, f, Some(m.revision_id)).await.is_err());
        }
    }
}
