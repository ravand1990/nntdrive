use nntdrive_nntp::*;
use std::sync::Arc;
use std::time::Duration;

fn make_article(_pool: &NntpPool, payload: &[u8]) -> Article {
    let id = new_message_id("test.local");
    let body = yenc_encode(&id, payload);
    Article::new(
        vec!["alt.binaries.test".into()],
        format!("[NNTDrive] {id}"),
        body,
        id,
    )
}

#[tokio::test]
async fn post_stat_fetch_roundtrip() {
    let server = MockNntpServer::start(MockConfig::default()).await;
    let pool = NntpPool::new(vec![server.client_config()]).unwrap();

    let payload: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    let article = make_article(&pool, &payload);
    pool.post(&article).await.unwrap();
    assert_eq!(server.store.article_count().await, 1);

    let size = pool.stat(&article.message_id).await.unwrap();
    assert!(size.unwrap_or(0) > 0);
    let fetched = pool.fetch(&article.message_id).await.unwrap();
    assert_eq!(fetched, payload);

    let stats = &pool.stats()[0].1;
    assert_eq!(stats.posts, 1);
    assert!(stats.bytes_fetched >= payload.len() as u64);

    // Message is addressable through an NZB as well.
    let nzb = Nzb {
        meta: vec![("title".into(), "test".into())],
        files: vec![NzbFile {
            poster: "NNTDrive".into(),
            date: 0,
            subject: "test".into(),
            groups: vec!["alt.binaries.test".into()],
            segments: vec![NzbSegment {
                bytes: payload.len() as u64,
                number: 1,
                message_id: article.message_id.clone(),
            }],
        }],
    };
    let parsed = Nzb::parse(&nzb.to_xml()).unwrap();
    assert_eq!(parsed.files[0].segments[0].message_id, article.message_id);
}

#[tokio::test]
async fn wrong_credentials_are_rejected() {
    let server = MockNntpServer::start(MockConfig::default()).await;
    let mut cfg = server.client_config();
    cfg.password = Some("wrong".into());
    cfg.max_retries = 0;
    let pool = NntpPool::new(vec![cfg]).unwrap();
    let err = pool.post(&make_article(&pool, b"x")).await.unwrap_err();
    assert!(err.to_string().contains("authentication failed"), "{err}");
}

#[tokio::test]
async fn missing_and_corrupted_articles_are_detected() {
    let server = MockNntpServer::start(MockConfig::default()).await;
    let pool = NntpPool::new(vec![server.client_config()]).unwrap();
    let payload = vec![42u8; 10_000];
    let article = make_article(&pool, &payload);
    pool.post(&article).await.unwrap();

    server.store.corrupt_message(&article.message_id).await;
    let err = pool.fetch(&article.message_id).await.unwrap_err();
    assert!(matches!(err, NntpError::Yenc(_)), "{err}");

    server.store.delete_message(&article.message_id).await;
    assert!(pool.stat(&article.message_id).await.unwrap().is_none());
    assert!(matches!(
        pool.fetch(&article.message_id).await.unwrap_err(),
        NntpError::NotFound
    ));
}

#[tokio::test]
async fn retention_expiry_and_outage_are_visible() {
    let server = MockNntpServer::start(MockConfig::default()).await;
    let pool = NntpPool::new(vec![server.client_config()]).unwrap();
    let article = make_article(&pool, b"retention");
    pool.post(&article).await.unwrap();
    assert!(pool.stat(&article.message_id).await.unwrap().is_some());

    tokio::time::sleep(Duration::from_millis(20)).await;
    server
        .store
        .expire_older_than(Duration::from_millis(5))
        .await;
    assert!(pool.stat(&article.message_id).await.unwrap().is_none());

    server.store.set_outage(true).await;
    assert!(pool.stat(&article.message_id).await.is_err());
}

#[tokio::test]
async fn posting_can_be_disabled_by_provider() {
    let cfg = MockConfig {
        posting_enabled: false,
        ..Default::default()
    };
    let server = MockNntpServer::start(cfg).await;
    let mut client = server.client_config();
    client.max_retries = 0;
    let pool = NntpPool::new(vec![client]).unwrap();
    let err = pool.post(&make_article(&pool, b"x")).await.unwrap_err();
    assert!(err.to_string().contains("posting"), "{err}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrency_is_bounded_by_provider_limit() {
    let server = MockNntpServer::start(MockConfig::default()).await;
    let mut cfg = server.client_config();
    cfg.max_connections = 2;
    let pool = Arc::new(NntpPool::new(vec![cfg]).unwrap());

    let mut tasks = Vec::new();
    for i in 0..8u8 {
        let pool = pool.clone();
        tasks.push(tokio::spawn(async move {
            let article = make_article(&pool, &vec![i; 20_000]);
            pool.post(&article).await.unwrap();
        }));
    }
    for t in tasks {
        t.await.unwrap();
    }
    assert_eq!(server.store.article_count().await, 8);
    assert!(server.store.max_active_connections().await <= 2);
}

#[tokio::test]
async fn multiple_providers_offer_redundant_retrieval() {
    let a = MockNntpServer::start(MockConfig::default()).await;
    let b = MockNntpServer::start(MockConfig::default()).await;
    let mut ca = a.client_config();
    ca.name = "a".into();
    ca.priority = 0;
    let mut cb = b.client_config();
    cb.name = "b".into();
    cb.priority = 1;
    cb.role = ProviderRole::RetrievalOnly;

    // Primary posts; the second provider is retrieval-only and has nothing.
    let pool = NntpPool::new(vec![ca, cb]).unwrap();
    let article = make_article(&pool, b"redundancy");
    pool.post(&article).await.unwrap();
    assert_eq!(a.store.article_count().await, 1);
    assert_eq!(b.store.article_count().await, 0);

    // Simulate the article missing on a and copied to b (as a repair would).
    let raw = a.store.raw_article(&article.message_id).await.unwrap();
    a.store.delete_message(&article.message_id).await;
    b.store.insert_raw(raw).await;
    let decoded = pool.fetch(&article.message_id).await.unwrap();
    assert_eq!(decoded, b"redundancy");
}
