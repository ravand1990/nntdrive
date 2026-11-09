use nntdrive_storage::TestDb;
use sqlx::Row;
use uuid::Uuid;

#[tokio::test]
async fn upgrading_opaque_history_never_infers_empty_references() {
    let Some(db) = TestDb::create().await else {
        return;
    };
    let mut tx = db.store.pool().begin().await.unwrap();
    let schema = format!("upgrade_{}", Uuid::new_v4().simple());
    sqlx::query(&format!("CREATE SCHEMA {schema}"))
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query(&format!("SET LOCAL search_path TO {schema}"))
        .execute(&mut *tx)
        .await
        .unwrap();
    for migration in [
        include_str!("../../../migrations/0001_init.sql"),
        include_str!("../../../migrations/0002_account_keys.sql"),
        include_str!("../../../migrations/0003_provider_management.sql"),
        include_str!("../../../migrations/0004_maintenance_results.sql"),
    ] {
        sqlx::raw_sql(migration).execute(&mut *tx).await.unwrap();
    }
    let a = Uuid::new_v4();
    let f = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO accounts(id,email,password_hash) VALUES($1,'upgrade@example.test','test')",
    )
    .bind(a)
    .execute(&mut *tx)
    .await
    .unwrap();
    sqlx::query("INSERT INTO files(id,account_id,name_enc,deleted) VALUES($1,$2,$3,true)")
        .bind(f)
        .bind(a)
        .bind(vec![1u8])
        .execute(&mut *tx)
        .await
        .unwrap();
    // A current, historical and tombstoned revision must ALL remain unknown,
    // even an empty declared size cannot prove an opaque reference set is empty.
    for size in [0i64, 42, 99] {
        sqlx::query("INSERT INTO file_versions(id,account_id,file_id,revision_id,size,manifest,deleted) VALUES($1,$2,$3,$4,$5,$6,true)")
            .bind(Uuid::new_v4()).bind(a).bind(f).bind(Uuid::new_v4()).bind(size).bind(b"opaque unchanged".to_vec())
            .execute(&mut *tx).await.unwrap();
    }
    sqlx::raw_sql(include_str!(
        "../../../migrations/0005_chunk_references.sql"
    ))
    .execute(&mut *tx)
    .await
    .unwrap();
    let rows = sqlx::query("SELECT manifest,references_complete FROM file_versions")
        .fetch_all(&mut *tx)
        .await
        .unwrap();
    assert_eq!(rows.len(), 3);
    for row in rows {
        assert!(!row.get::<bool, _>("references_complete"));
        assert_eq!(row.get::<Vec<u8>, _>("manifest"), b"opaque unchanged");
    }
    let required: bool =
        sqlx::query_scalar("SELECT reference_commits_required FROM accounts WHERE id=$1")
            .bind(a)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    assert!(!required);
    // Rollback removes this temporary schema and every synthetic row.
    tx.rollback().await.unwrap();
}
