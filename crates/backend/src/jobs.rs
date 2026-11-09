//! Durable background jobs (health sweeps, repairs, retention refresh).
//!
//! Jobs are rows in PostgreSQL. Workers claim them with `FOR UPDATE SKIP
//! LOCKED`, so several backend replicas can share the queue, and a crash
//! returns the job to the queue on retry instead of losing it.

use crate::state::AppState;
use anyhow::Context as _;
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use sqlx::PgPool;
use sqlx::Row;
use std::sync::Arc;
use std::time::Duration as StdDuration;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct Job {
    pub id: Uuid,
    pub kind: String,
    pub payload: Value,
    pub attempts: i32,
    pub max_attempts: i32,
}

pub async fn enqueue(
    pool: &PgPool,
    kind: &str,
    dedupe_key: Option<&str>,
    payload: Value,
    delay_secs: i64,
) -> anyhow::Result<Uuid> {
    let id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO jobs (id, kind, dedupe_key, payload, run_after)
         VALUES ($1, $2, $3, $4, now() + ($5 || ' seconds')::interval)
         ON CONFLICT (dedupe_key) DO NOTHING",
    )
    .bind(id)
    .bind(kind)
    .bind(dedupe_key)
    .bind(payload)
    .bind(delay_secs.to_string())
    .execute(pool)
    .await?;
    Ok(id)
}

async fn claim(pool: &PgPool, worker: &str) -> anyhow::Result<Option<Job>> {
    let row = sqlx::query(
        "UPDATE jobs SET state = 'running', locked_by = $1, locked_at = now(),
                         attempts = attempts + 1, updated_at = now()
         WHERE id = (
             SELECT id FROM jobs
             WHERE state = 'pending' AND run_after <= now()
             ORDER BY run_after LIMIT 1
             FOR UPDATE SKIP LOCKED
         )
         RETURNING id, kind, payload, attempts, max_attempts",
    )
    .bind(worker)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| Job {
        id: r.get("id"),
        kind: r.get("kind"),
        payload: r.get("payload"),
        attempts: r.get("attempts"),
        max_attempts: r.get("max_attempts"),
    }))
}

pub async fn worker_loop(state: Arc<AppState>, worker: String) {
    loop {
        match claim(&state.pool, &worker).await {
            Ok(Some(job)) => {
                let job_id = job.id;
                match process(&state, &job).await {
                    Ok(result) => {
                        let _ = sqlx::query(
                            "UPDATE jobs SET state = 'done', result = $2, last_error = NULL, updated_at = now(), locked_by = NULL WHERE id = $1",
                        )
                        .bind(job_id)
                        .bind(result)
                        .execute(&state.pool)
                        .await;
                    }
                    Err(e) => {
                        tracing::error!(job = %job_id, kind = %job.kind, error = %e, "job failed");
                        let retry = job.attempts < job.max_attempts;
                        let backoff = (job.attempts as i64 * 30).min(3600);
                        let _ = sqlx::query(
                            "UPDATE jobs SET state = $2, locked_by = NULL,
                                    last_error = $3, updated_at = now(),
                                    run_after = now() + ($4 || ' seconds')::interval
                             WHERE id = $1",
                        )
                        .bind(job_id)
                        .bind(if retry { "pending" } else { "failed" })
                        .bind("maintenance failed; retry or inspect backend diagnostics")
                        .bind(backoff.to_string())
                        .execute(&state.pool)
                        .await;
                    }
                }
            }
            Ok(None) => tokio::time::sleep(StdDuration::from_secs(2)).await,
            Err(e) => {
                tracing::error!(error = %e, "job claim failed");
                tokio::time::sleep(StdDuration::from_secs(10)).await;
            }
        }
    }
}

async fn process(state: &AppState, job: &Job) -> anyhow::Result<Value> {
    match job.kind.as_str() {
        "health_sweep" => health_sweep(state, job).await,
        "repair_stripe" => repair_stripe(state, job).await,
        "refresh_sweep" => refresh_sweep(state, job).await,
        "orphan_gc" => {
            let account_id: Uuid = job
                .payload
                .get("account_id")
                .and_then(Value::as_str)
                .context("account_id required")?
                .parse()?;
            let grace_days = job
                .payload
                .get("grace_days")
                .and_then(Value::as_u64)
                .context("grace_days required")?;
            anyhow::ensure!(
                (1..=3650).contains(&grace_days)
                    && job
                        .payload
                        .get("require_reference_commits")
                        .and_then(Value::as_bool)
                        == Some(true),
                "invalid GC opt-in"
            );
            match state
                .store
                .collect_orphan_chunks(account_id, grace_days as u32, 1000)
                .await
            {
                Ok(deleted) => Ok(
                    json!({ "account_id": account_id, "deleted_chunks": deleted, "grace_days": grace_days, "batch_limit": 1000, "reference_commits_required": true }),
                ),
                Err(nntdrive_storage::StoreError::Invalid(reason))
                    if reason == "GC blocked: incomplete version references" =>
                {
                    Ok(
                        json!({ "account_id": account_id, "deleted_chunks": 0, "blocked": "incomplete_version_references" }),
                    )
                }
                Err(e) => Err(e.into()),
            }
        }
        other => Err(anyhow::anyhow!("unknown job kind {other}")),
    }
}

async fn health_sweep(state: &AppState, job: &Job) -> anyhow::Result<Value> {
    let after: Option<Uuid> = job
        .payload
        .get("after")
        .and_then(|v| v.as_str())
        .and_then(|s| s.parse().ok());
    let batch = state.store.list_stripe_specs(after, 100).await?;
    let mut checked = 0usize;
    let mut degraded = 0usize;
    let mut below_threshold = 0usize;
    let mut last = None;
    for (stripe, shards) in &batch {
        last = Some(stripe.id);
        checked += 1;
        let available = state.storage.check_stripe_rows(shards).await?;
        let total = shards.len();
        if available < stripe.data_shards as usize {
            // STAT failures are unknown availability, not confirmed loss.
            below_threshold += 1;
        }
        if available < total && available >= stripe.data_shards as usize {
            degraded += 1;
            enqueue(
                &state.pool,
                "repair_stripe",
                Some(&format!("repair:{}", stripe.id)),
                json!({ "stripe_id": stripe.id }),
                30,
            )
            .await?;
        }
    }
    if batch.len() == 100 {
        let key = format!("health:{}", last.unwrap_or_else(Uuid::new_v4));
        enqueue(
            &state.pool,
            "health_sweep",
            Some(&key),
            json!({ "after": last }),
            5,
        )
        .await?;
    }
    tracing::info!(checked, degraded, "health sweep finished");
    Ok(
        json!({ "checked": checked, "degraded": degraded, "below_threshold": below_threshold,
               "continued": batch.len() == 100 }),
    )
}

async fn repair_stripe(state: &AppState, job: &Job) -> anyhow::Result<Value> {
    let stripe_id: Uuid = job
        .payload
        .get("stripe_id")
        .and_then(|v| v.as_str())
        .and_then(|s| s.parse().ok())
        .context("repair job missing stripe_id")?;
    let (stripe, shards) = state
        .store
        .stripe_with_shards(stripe_id)
        .await?
        .context("stripe not found")?;
    let report = state.storage.repair_stripe_db(&stripe, &shards).await?;
    tracing::info!(
        stripe = %stripe_id,
        reposted = report.shards_reposted,
        unrecoverable = report.stripes_unrecoverable,
        "repair finished"
    );
    Ok(json!({ "reposted": report.shards_reposted, "unrecoverable": report.stripes_unrecoverable }))
}

pub async fn refresh_days(state: &AppState) -> anyhow::Result<u32> {
    let days: Option<i32> =
        sqlx::query_scalar("SELECT refresh_days FROM maintenance_settings WHERE singleton = true")
            .fetch_optional(&state.pool)
            .await?;
    Ok(days
        .map(|d| d as u32)
        .unwrap_or(state.config.retention_refresh_days))
}

async fn refresh_sweep(state: &AppState, job: &Job) -> anyhow::Result<Value> {
    let after: Option<Uuid> = job
        .payload
        .get("after")
        .and_then(|v| v.as_str())
        .and_then(|s| s.parse().ok());
    let days = refresh_days(state).await?;
    let cutoff = Utc::now() - Duration::days(days as i64);
    let batch = state.store.list_stripe_specs(after, 100).await?;
    let mut refreshed = 0usize;
    let mut failed = 0usize;
    let mut last = None;
    for (stripe, shards) in &batch {
        last = Some(stripe.id);
        if shards.iter().any(|s| s.posted_at < cutoff) {
            match state
                .storage
                .refresh_stripe_db(stripe, shards, cutoff)
                .await
            {
                Ok(r) => {
                    refreshed += r.stripes_refreshed;
                    // This batch selected an expired stripe. A zero refresh report
                    // includes unrecoverable data (not an error in the storage API).
                    failed += usize::from(r.stripes_refreshed == 0);
                }
                Err(e) => {
                    failed += 1;
                    tracing::warn!(stripe = %stripe.id, error = %e, "refresh failed");
                }
            }
        }
    }
    if batch.len() == 100 {
        enqueue(
            &state.pool,
            "refresh_sweep",
            Some(&format!("refresh:{}", last.unwrap_or_else(Uuid::new_v4))),
            json!({ "after": last }),
            30,
        )
        .await?;
    }
    tracing::info!(refreshed, "retention refresh finished");
    Ok(
        json!({ "checked": batch.len(), "refreshed": refreshed, "failed": failed,
               "refresh_days": days, "continued": batch.len() == 100 }),
    )
}

/// Enqueues periodic maintenance if the queue does not already hold it.
pub async fn schedule_periodic(state: &AppState) {
    let now = Utc::now();
    let _ = enqueue(
        &state.pool,
        "health_sweep",
        Some(&format!("health:{}", now.format("%Y-%m-%d-%H"))),
        json!({}),
        0,
    )
    .await;
    let _ = enqueue(
        &state.pool,
        "refresh_sweep",
        Some(&format!("refresh:{}", now.format("%Y-%m-%d"))),
        json!({}),
        300,
    )
    .await;
}

pub async fn scheduler_loop(state: Arc<AppState>) {
    let mut health_due = tokio::time::Instant::now();
    let mut refresh_due = tokio::time::Instant::now();
    loop {
        let now = tokio::time::Instant::now();
        if now >= health_due {
            let _ = enqueue(
                &state.pool,
                "health_sweep",
                Some(&format!("health:{}", Utc::now().format("%Y-%m-%d-%H"))),
                json!({}),
                0,
            )
            .await;
            health_due = now + StdDuration::from_secs(state.config.health_check_interval_secs);
        }
        if now >= refresh_due {
            let _ = enqueue(
                &state.pool,
                "refresh_sweep",
                Some(&format!("refresh:{}", Utc::now().format("%Y-%m-%d"))),
                json!({}),
                0,
            )
            .await;
            refresh_due = now + StdDuration::from_secs(state.config.retention_interval_secs);
        }
        tokio::time::sleep(StdDuration::from_secs(60)).await;
    }
}

pub fn _job_timestamp(_: DateTime<Utc>) {}
