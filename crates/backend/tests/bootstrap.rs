//! Real PostgreSQL regressions for first-account admission across server instances.
use axum::body::Body;
use axum::extract::connect_info::ConnectInfo;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use nntdrive_backend::state::{AppState, ServerConfig};
use nntdrive_nntp::{MockConfig, MockNntpServer, NntpPool};
use nntdrive_storage::TestDb;
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::{net::SocketAddr, sync::Arc, time::Duration};
use tower::ServiceExt;
use uuid::Uuid;

async fn instance(db: &TestDb, nntp: Arc<NntpPool>, allow_registration: bool) -> AppState {
    // A separate connection pool and AppState, just like another backend process.
    let schema = db.schema.clone();
    let pool = PgPoolOptions::new()
        .max_connections(3)
        .after_connect(move |conn, _| {
            let sql = format!("SET search_path TO \"{schema}\"");
            Box::pin(async move {
                sqlx::query(&sql).execute(conn).await?;
                Ok(())
            })
        })
        .connect_with((*db.store.pool().connect_options()).clone())
        .await
        .unwrap();
    AppState::new(
        pool,
        nntp,
        ServerConfig {
            bind: "127.0.0.1:0".into(),
            cache_dir: std::env::temp_dir(),
            cache_limit_bytes: 1024,
            allow_registration,
            secret_key: [7; 32],
            default_quota_bytes: None,
            health_check_interval_secs: 3600,
            retention_refresh_days: 30,
            retention_interval_secs: 3600,
        },
    )
    .unwrap()
}

async fn register(state: AppState, email: &str) -> (StatusCode, Value) {
    let mut request = Request::builder()
        .method("POST")
        .uri("/api/v1/auth/register")
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_vec(&json!({
            "account_id": Uuid::new_v4(), "email": email,
            "verifier": "ab".repeat(32), "keyfile": {},
            "device": {"name": "test", "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}
        })).unwrap())).unwrap();
    request
        .extensions_mut()
        .insert(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 40000))));
    let response = nntdrive_backend::app(state).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap())
}

async fn wait_for_account_waiters(pool: &PgPool, count: i64) {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let waiting: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM pg_locks WHERE relation = 'accounts'::regclass AND NOT granted"
            ).fetch_one(pool).await.unwrap();
            if waiting == count { break; }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await.expect("account creators did not reach the database gate");
}

async fn concurrent_registration(allow_registration: bool) {
    let db = TestDb::create().await.expect("PostgreSQL is required");
    let server = MockNntpServer::start(MockConfig::default()).await;
    let nntp = Arc::new(NntpPool::new(vec![server.client_config()]).unwrap());
    let first = instance(&db, nntp.clone(), allow_registration).await;
    let second = instance(&db, nntp, allow_registration).await;
    let mut gate = db.store.pool().begin().await.unwrap();
    // SHARE permits the original count reads, but blocks both INSERTs. With the
    // fix it blocks admission locks instead. Observe both waiters before release:
    // no sleeps or scheduler luck are used to manufacture the interleaving.
    sqlx::query("LOCK TABLE accounts IN SHARE MODE")
        .execute(&mut *gate)
        .await
        .unwrap();
    let a = tokio::spawn(register(first.clone(), "first@example.test"));
    let b = tokio::spawn(register(second.clone(), "second@example.test"));
    wait_for_account_waiters(db.store.pool(), 2).await;
    gate.commit().await.unwrap();
    let (a, b) = tokio::time::timeout(Duration::from_secs(20), async {
        (a.await.unwrap(), b.await.unwrap())
    })
    .await
    .expect("registrations deadlocked");
    let responses = [a, b];
    let created = responses
        .iter()
        .filter(|r| r.0 == StatusCode::CREATED)
        .count();
    let admins = responses.iter().filter(|r| r.1["is_admin"] == true).count();
    assert_eq!(
        created,
        if allow_registration { 2 } else { 1 },
        "unexpected number of admitted registrations"
    );
    assert_eq!(admins, 1, "only the first committed account may be admin");
    if !allow_registration {
        assert_eq!(
            responses
                .iter()
                .filter(|r| r.0 == StatusCode::FORBIDDEN)
                .count(),
            1
        );
    }
    let counts: (i64, i64) =
        sqlx::query_as("SELECT count(*), count(*) FILTER (WHERE is_admin) FROM accounts")
            .fetch_one(db.store.pool())
            .await
            .unwrap();
    assert_eq!(counts, (created as i64, 1));
    for table in ["devices", "api_tokens"] {
        let count: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
            .fetch_one(db.store.pool())
            .await
            .unwrap();
        assert_eq!(count, created as i64);
    }
    first.pool.close().await;
    second.pool.close().await;
}

#[tokio::test]
async fn bootstrap_registration_disabled_admits_one_admin() {
    concurrent_registration(false).await;
}

#[tokio::test]
async fn bootstrap_registration_enabled_admits_only_one_admin() {
    concurrent_registration(true).await;
}

#[tokio::test]
async fn bootstrap_operator_helper_serializes_with_registration() {
    use nntdrive_storage::store::account_creation_is_admin;
    let db = TestDb::create().await.expect("PostgreSQL is required");
    let server = MockNntpServer::start(MockConfig::default()).await;
    let nntp = Arc::new(NntpPool::new(vec![server.client_config()]).unwrap());
    let state = instance(&db, nntp, false).await;
    let mut operator = db.store.pool().begin().await.unwrap();
    // This is the shared transactional admission path used by CLI Bootstrap.
    assert_eq!(
        account_creation_is_admin(&mut operator, false, false)
            .await
            .unwrap(),
        Some(true)
    );
    sqlx::query("INSERT INTO accounts (id, email, password_hash, is_admin) VALUES ($1, 'operator@example.test', 'test', TRUE)")
        .bind(Uuid::new_v4()).execute(&mut *operator).await.unwrap();
    let request = tokio::spawn(register(state.clone(), "api@example.test"));
    wait_for_account_waiters(db.store.pool(), 1).await;
    operator.commit().await.unwrap();
    let result = tokio::time::timeout(Duration::from_secs(20), request)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result.0, StatusCode::FORBIDDEN);

    let mut operator = db.store.pool().begin().await.unwrap();
    assert_eq!(
        account_creation_is_admin(&mut operator, false, false)
            .await
            .unwrap(),
        None
    );
    operator.rollback().await.unwrap();
    // AccountCreate without --admin cannot inherit bootstrap privileges; an
    // explicit --admin still grants them even when accounts already exist.
    for explicit_admin in [false, true] {
        let mut operator = db.store.pool().begin().await.unwrap();
        let role = account_creation_is_admin(&mut operator, true, explicit_admin)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(role, explicit_admin);
        let stored: bool = sqlx::query_scalar("INSERT INTO accounts (id, email, password_hash, is_admin) VALUES ($1, $2, 'test', $3) RETURNING is_admin")
            .bind(Uuid::new_v4()).bind(format!("operator-{explicit_admin}@example.test")).bind(role)
            .fetch_one(&mut *operator).await.unwrap();
        assert_eq!(stored, explicit_admin);
        operator.commit().await.unwrap();
    }
    state.pool.close().await;
}

#[tokio::test]
async fn bootstrap_operator_helper_waits_for_registration_commit() {
    use nntdrive_storage::store::account_creation_is_admin;
    let db = TestDb::create().await.expect("PostgreSQL is required");
    let server = MockNntpServer::start(MockConfig::default()).await;
    let nntp = Arc::new(NntpPool::new(vec![server.client_config()]).unwrap());
    let state = instance(&db, nntp, true).await;
    let mut gate = db.store.pool().begin().await.unwrap();
    sqlx::query("LOCK TABLE accounts IN SHARE MODE")
        .execute(&mut *gate)
        .await
        .unwrap();
    let request = tokio::spawn(register(state.clone(), "api@example.test"));
    wait_for_account_waiters(db.store.pool(), 1).await;
    let pool = db.store.pool().clone();
    let operator = tokio::spawn(async move {
        let mut tx = pool.begin().await.unwrap();
        let role = account_creation_is_admin(&mut tx, false, false)
            .await
            .unwrap();
        tx.rollback().await.unwrap();
        role
    });
    wait_for_account_waiters(db.store.pool(), 2).await;
    gate.commit().await.unwrap();
    let (response, role) = tokio::time::timeout(Duration::from_secs(20), async {
        (request.await.unwrap(), operator.await.unwrap())
    })
    .await
    .unwrap();
    assert_eq!(response.0, StatusCode::CREATED);
    assert_eq!(
        role, None,
        "CLI bootstrap must observe the preceding API commit"
    );
    state.pool.close().await;
}

#[tokio::test]
async fn bootstrap_registration_rollback_allows_retry() {
    let db = TestDb::create().await.expect("PostgreSQL is required");
    let server = MockNntpServer::start(MockConfig::default()).await;
    let nntp = Arc::new(NntpPool::new(vec![server.client_config()]).unwrap());
    let state = instance(&db, nntp, false).await;
    // Fail after the account and device INSERTs to exercise actual rollback.
    sqlx::raw_sql("CREATE FUNCTION reject_test_token() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test token failure'; END $$;
        CREATE TRIGGER reject_test_token BEFORE INSERT ON api_tokens FOR EACH ROW EXECUTE FUNCTION reject_test_token();")
        .execute(db.store.pool()).await.unwrap();
    assert_eq!(
        register(state.clone(), "retry@example.test").await.0,
        StatusCode::INTERNAL_SERVER_ERROR
    );
    for table in ["accounts", "devices", "api_tokens"] {
        let count: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
            .fetch_one(db.store.pool())
            .await
            .unwrap();
        assert_eq!(count, 0);
    }
    sqlx::query("DROP TRIGGER reject_test_token ON api_tokens")
        .execute(db.store.pool())
        .await
        .unwrap();
    let result = tokio::time::timeout(
        Duration::from_secs(20),
        register(state.clone(), "retry@example.test"),
    )
    .await
    .expect("rollback did not release admission lock");
    assert_eq!(result.0, StatusCode::CREATED);
    assert_eq!(result.1["is_admin"], true);
    state.pool.close().await;
}
