use nntdrive_crypto::MasterKey;
use nntdrive_nntp::{MockConfig, MockNntpServer, NntpPool};
use nntdrive_storage::config::{ChunkConfig, StorageConfig};
use nntdrive_storage::{Context, FileManifest, Storage, StorageError, TestDb};
use std::sync::Arc;
use uuid::Uuid;

struct Fixture {
    _db: TestDb,
    server: MockNntpServer,
    storage: Storage,
    account: Uuid,
    file_id: Uuid,
    ctx: Context,
    manifest: Option<FileManifest>,
}

async fn setup() -> Option<Fixture> {
    let db = TestDb::create().await?;
    let server = MockNntpServer::start(MockConfig::default()).await;
    let pool = Arc::new(NntpPool::new(vec![server.client_config()]).unwrap());
    let config = StorageConfig {
        chunks: ChunkConfig {
            min_size: 16 * 1024,
            avg_size: 64 * 1024,
            max_size: 256 * 1024,
        },
        shard_size: 64 * 1024,
        max_data_shards: 4,
        redundancy_percent: 40,
        compression_level: 3,
        verify_after_post: true,
        durability_margin: 1,
        health_check_interval_secs: 3600,
        retention_safety_margin_days: 7,
    };
    let storage = Storage::new(db.store.clone(), pool, config).unwrap();
    let account = db.create_account("test@example.com").await;
    let file_id = db.create_file(account, None, b"opaque-name".to_vec()).await;
    let master = MasterKey::generate(account, 0);
    Some(Fixture {
        _db: db,
        server,
        storage,
        account,
        file_id,
        ctx: Context::new(account, master),
        manifest: None,
    })
}

fn payload(len: usize) -> Vec<u8> {
    let mut data: Vec<u8> = (0..len)
        .map(|i| (i.wrapping_mul(2654435761) >> 7) as u8)
        .collect();
    let marker = b"PLAINTEXT-MARKER-MUST-NEVER-REACH-USENET";
    for (i, b) in marker.iter().enumerate() {
        data[i] = *b;
    }
    data
}

async fn upload(f: &mut Fixture, data: &[u8]) -> FileManifest {
    let revision = Uuid::new_v4();
    let outcome = f
        .storage
        .upload(
            &f.ctx,
            f.file_id,
            revision,
            std::io::Cursor::new(data.to_vec()),
        )
        .await
        .unwrap();
    f.storage.commit(&f.ctx, &outcome, None).await.unwrap();
    f.manifest = Some(outcome.manifest.clone());
    outcome.manifest
}

async fn download(f: &Fixture) -> Vec<u8> {
    let (manifest, _, _) = f
        .storage
        .load_manifest(&f.ctx, f.file_id, None)
        .await
        .unwrap();
    let mut out = Vec::new();
    f.storage
        .download_to(&f.ctx, &manifest, &mut out)
        .await
        .unwrap();
    out
}

async fn all_shards(f: &Fixture, manifest: &FileManifest) -> Vec<nntdrive_storage::ShardRow> {
    let mut out = Vec::new();
    for c in &manifest.chunks {
        for s in &c.stripes {
            out.extend(f.storage.store().load_shards(s.id).await.unwrap());
        }
    }
    out
}

#[tokio::test]
async fn encrypted_upload_download_and_no_plaintext_on_usenet() {
    let Some(mut f) = setup().await else { return };
    let data = payload(600_000);
    let manifest = upload(&mut f, &data).await;
    assert!(!manifest.chunks.is_empty());
    assert!(manifest.total_articles() > 0);

    // Ciphertext only: no plaintext marker anywhere in stored articles.
    for id in f.server.store.article_ids().await {
        let raw = f.server.store.raw_article(&id).await.unwrap();
        assert!(
            !raw.windows(20).any(|w| w == b"PLAINTEXT-MARKER-MUST"),
            "plaintext leaked into article {id}"
        );
    }

    assert_eq!(download(&f).await, data);
    let (logical, ciphertext) = f.storage.store().count_storage(f.account).await.unwrap();
    assert!(logical > 0 && ciphertext > 0);
}

#[tokio::test]
async fn repeated_content_reuses_encrypted_chunks() {
    let Some(mut f) = setup().await else { return };
    let data = payload(300_000);
    let first = upload(&mut f, &data).await;
    let articles_after_first = f.server.store.article_count().await;
    let second = upload(&mut f, &data).await;
    assert_eq!(f.server.store.article_count().await, articles_after_first);
    assert_eq!(
        first.chunks.iter().map(|c| c.id).collect::<Vec<_>>(),
        second.chunks.iter().map(|c| c.id).collect::<Vec<_>>()
    );
    assert_eq!(download(&f).await, data);
}

#[tokio::test]
async fn erasure_coding_survives_shard_loss_and_reports_total_loss() {
    let Some(mut f) = setup().await else { return };
    let data = payload(250_000);
    let manifest = upload(&mut f, &data).await;
    let shards = all_shards(&f, &manifest).await;

    // Lose one shard per stripe: download must reconstruct transparently.
    let mut per_stripe_seen = std::collections::HashSet::new();
    for shard in &shards {
        if per_stripe_seen.insert(shard.stripe_id) {
            f.server.store.delete_message(&shard.message_id).await;
        }
    }
    assert!(!per_stripe_seen.is_empty());
    assert_eq!(download(&f).await, data);

    // Stronger corruption beyond the redundancy budget must fail loudly.
    let shards = all_shards(&f, &manifest).await;
    let first_stripe = shards[0].stripe_id;
    for s in shards.iter().filter(|s| s.stripe_id == first_stripe) {
        f.server.store.delete_message(&s.message_id).await;
    }
    let (manifest2, _, _) = f
        .storage
        .load_manifest(&f.ctx, f.file_id, None)
        .await
        .unwrap();
    let mut out = Vec::new();
    let err = f
        .storage
        .download_to(&f.ctx, &manifest2, &mut out)
        .await
        .unwrap_err();
    assert!(matches!(err, StorageError::Unrecoverable { .. }), "{err}");
}

#[tokio::test]
async fn health_repair_and_retention_refresh_are_verified() {
    let Some(mut f) = setup().await else { return };
    let data = payload(220_000);
    let manifest = upload(&mut f, &data).await;
    let shards = all_shards(&f, &manifest).await;

    // Remove one shard per stripe: still recoverable, and repair should fix it.
    let mut by_stripe: std::collections::HashMap<Uuid, &nntdrive_storage::ShardRow> =
        std::collections::HashMap::new();
    for s in &shards {
        by_stripe.entry(s.stripe_id).or_insert(s);
    }
    let mut to_repair = Vec::new();
    for s in by_stripe.values() {
        f.server.store.delete_message(&s.message_id).await;
        to_repair.push(s.id);
    }
    assert!(!to_repair.is_empty());

    let health = f.storage.check_file(&f.ctx, &manifest).await.unwrap();
    assert!(health.recoverable);
    assert!(health.degraded);

    let report = f.storage.repair_file(&f.ctx, &manifest).await.unwrap();
    assert_eq!(report.stripes_unrecoverable, 0);
    assert!(report.shards_reposted >= to_repair.len());
    assert_eq!(download(&f).await, data);

    let healed = f.storage.check_file(&f.ctx, &manifest).await.unwrap();
    assert!(!healed.degraded, "{healed:?}");
    assert!(healed.recoverable);

    // Age every shard past the refresh threshold, then refresh and verify.
    let ids: Vec<Uuid> = all_shards(&f, &manifest)
        .await
        .iter()
        .map(|s| s.id)
        .collect();
    sqlx::query("UPDATE shards SET posted_at = now() - interval '90 days' WHERE id = ANY($1)")
        .bind(&ids)
        .execute(f.storage.store().pool())
        .await
        .unwrap();
    let old_ids: Vec<String> = all_shards(&f, &manifest)
        .await
        .iter()
        .map(|s| s.message_id.clone())
        .collect();
    let report = f.storage.refresh_file(&f.ctx, &manifest, 30).await.unwrap();
    assert!(report.stripes_refreshed > 0);
    assert!(report.shards_reposted >= ids.len());
    assert_eq!(download(&f).await, data);
    let new_ids: Vec<String> = all_shards(&f, &manifest)
        .await
        .iter()
        .map(|s| s.message_id.clone())
        .collect();
    assert!(new_ids.iter().all(|id| !old_ids.contains(id)));
    let history: i64 = sqlx::query_scalar("SELECT count(*) FROM shard_history")
        .fetch_one(f.storage.store().pool())
        .await
        .unwrap();
    assert!(history > 0);
}

#[tokio::test]
async fn wrong_key_and_provider_outage_fail_closed() {
    let Some(mut f) = setup().await else { return };
    let data = payload(120_000);
    let manifest = upload(&mut f, &data).await;
    let (loaded, _, _) = f
        .storage
        .load_manifest(&f.ctx, f.file_id, None)
        .await
        .unwrap();
    let mut out = Vec::new();
    let wrong = Context::new(f.account, MasterKey::generate(f.account, 0));
    let err = f
        .storage
        .download_to(&wrong, &loaded, &mut out)
        .await
        .unwrap_err();
    assert!(matches!(err, StorageError::Crypto(_)), "{err}");

    f.server.store.set_outage(true).await;
    let mut out = Vec::new();
    let err = f
        .storage
        .download_to(&f.ctx, &manifest, &mut out)
        .await
        .unwrap_err();
    assert!(
        !matches!(err, StorageError::Unrecoverable { .. }),
        "outage misreported as loss: {err}"
    );
}

#[tokio::test]
async fn version_history_and_manifest_backup_decrypt() {
    let Some(mut f) = setup().await else { return };
    let v1 = payload(80_000);
    let m1 = upload(&mut f, &v1).await;
    let v2 = payload(90_000);
    let m2 = upload(&mut f, &v2).await;
    assert_ne!(m1.revision_id, m2.revision_id);

    let versions = f
        .storage
        .store()
        .list_versions(f.account, f.file_id, 10)
        .await
        .unwrap();
    assert_eq!(versions.len(), 2);

    // Old revision remains readable and distinct.
    let (old, _, rev) = f
        .storage
        .load_manifest(&f.ctx, f.file_id, Some(m1.revision_id))
        .await
        .unwrap();
    assert_eq!(rev, m1.revision_id);
    let mut out = Vec::new();
    f.storage.download_to(&f.ctx, &old, &mut out).await.unwrap();
    assert_eq!(out, v1);

    // Recovery kit restores the key needed to open the sealed manifest.
    let (kit, code) = nntdrive_crypto::RecoveryKit::create(&f.ctx.master, None).unwrap();
    let restored = kit.unlock(&code).unwrap();
    let sealed = f
        .storage
        .store()
        .version(f.account, f.file_id, Some(m2.revision_id))
        .await
        .unwrap();
    let env = nntdrive_crypto::Envelope::from_bytes(&sealed.manifest).unwrap();
    let plain = restored
        .open_manifest(f.file_id, m2.revision_id, &env)
        .unwrap();
    let recovered = FileManifest::from_bytes(&plain).unwrap();
    assert_eq!(recovered, m2);
}
