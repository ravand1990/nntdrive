use nntdrive_storage::TestDb;
use uuid::Uuid;

#[tokio::test]
async fn gc_batches_cascade_only_local_article_indexes() {
    let Some(db) = TestDb::create().await else {
        return;
    };
    let a = db.create_account("gc-cascade@example.test").await;
    for _ in 0..3 {
        let c = Uuid::new_v4();
        let stripe = Uuid::new_v4();
        let shard = Uuid::new_v4();
        sqlx::query("INSERT INTO chunks(id,account_id,plaintext_hash,plaintext_len,ciphertext_len,created_at) VALUES($1,$2,$3,1,42,now()-interval '10 days')")
            .bind(c).bind(a).bind(c.as_bytes().to_vec()).execute(db.store.pool()).await.unwrap();
        sqlx::query("INSERT INTO stripes(id,chunk_id,stripe_index,data_shards,parity_shards,shard_len,ciphertext_len) VALUES($1,$2,0,1,1,42,42)")
            .bind(stripe).bind(c).execute(db.store.pool()).await.unwrap();
        sqlx::query("INSERT INTO shards(id,stripe_id,shard_index,message_id,sha256,size) VALUES($1,$2,0,'<opaque@test>','opaque',42)")
            .bind(shard).bind(stripe).execute(db.store.pool()).await.unwrap();
        sqlx::query("INSERT INTO shard_history(shard_id,message_id,generation,reason) VALUES($1,'<old@test>',1,'refresh')")
            .bind(shard).execute(db.store.pool()).await.unwrap();
    }
    assert_eq!(db.store.collect_orphan_chunks(a, 7, 1).await.unwrap(), 1);
    assert_eq!(db.store.collect_orphan_chunks(a, 7, 2).await.unwrap(), 2);
    for table in ["chunks", "stripes", "shards", "shard_history"] {
        let count: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
            .fetch_one(db.store.pool())
            .await
            .unwrap();
        assert_eq!(count, 0, "{table} did not cascade");
    }
    assert_eq!(db.store.collect_orphan_chunks(a, 7, 1000).await.unwrap(), 0);
}
