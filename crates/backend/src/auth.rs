//! Authentication, devices, bearer tokens and the admin extractor.

use crate::error::{b64, random_token, sha256, ApiError, ApiResult};
use crate::state::{encrypt_secret, AppState};
use axum::extract::{ConnectInfo, FromRequestParts, Path, State};
use axum::http::request::Parts;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use std::net::SocketAddr;
use uuid::Uuid;

type DeviceListRow = (
    Uuid,
    String,
    String,
    Option<DateTime<Utc>>,
    Option<DateTime<Utc>>,
);
type DeviceListFullRow = (
    Uuid,
    String,
    String,
    DateTime<Utc>,
    Option<DateTime<Utc>>,
    Option<DateTime<Utc>>,
);

#[derive(Debug, Clone)]
pub struct Auth {
    pub account_id: Uuid,
    pub device_id: Option<Uuid>,
    pub token_id: Uuid,
    pub is_admin: bool,
}

impl FromRequestParts<AppState> for Auth {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let header = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or(ApiError::Unauthorized)?;
        let token = header
            .strip_prefix("Bearer ")
            .ok_or(ApiError::Unauthorized)?
            .trim();
        if token.len() < 20 {
            return Err(ApiError::Unauthorized);
        }
        let hash = sha256(token.as_bytes());
        let row = sqlx::query_as::<_, (Uuid, Uuid, Option<Uuid>, bool, bool, Option<i64>)>(
            "SELECT t.id, a.id, t.device_id, a.is_admin, a.disabled, a.quota_bytes
             FROM api_tokens t JOIN accounts a ON a.id = t.account_id
             WHERE t.token_hash = $1 AND t.revoked_at IS NULL
               AND (t.expires_at IS NULL OR t.expires_at > now())",
        )
        .bind(hash.as_slice())
        .fetch_optional(&state.pool)
        .await?
        .ok_or(ApiError::Unauthorized)?;
        if row.4 {
            return Err(ApiError::Unauthorized);
        }
        Ok(Auth {
            token_id: row.0,
            account_id: row.1,
            device_id: row.2,
            is_admin: row.3,
        })
    }
}

#[derive(Debug, Clone)]
pub struct AdminUser(pub Auth);

impl FromRequestParts<AppState> for AdminUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let auth = Auth::from_request_parts(parts, state).await?;
        if !auth.is_admin {
            return Err(ApiError::Forbidden);
        }
        Ok(AdminUser(auth))
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct DevicePayload {
    #[serde(default)]
    pub id: Option<Uuid>,
    pub name: String,
    #[serde(default)]
    pub platform: Option<String>,
    pub public_key: String,
}

#[derive(Debug, Deserialize)]
pub struct RegisterPayload {
    pub account_id: Uuid,
    pub email: String,
    pub verifier: String,
    pub keyfile: Value,
    #[serde(default)]
    pub recovery_kit: Option<Value>,
    #[serde(default)]
    pub display_name: Option<String>,
    pub device: DevicePayload,
}

pub async fn register(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(body): Json<RegisterPayload>,
) -> ApiResult<impl IntoResponse> {
    if !state.limiter.allow(addr.ip()).await {
        return Err(ApiError::TooManyRequests);
    }
    validate_email(&body.email)?;
    if body.verifier.len() != 64 || !body.verifier.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(ApiError::BadRequest(
            "verifier must be 64 hex characters".into(),
        ));
    }
    let public_key = crate::error::unb64(&body.device.public_key)
        .map_err(|_| ApiError::BadRequest("device public_key must be base64".into()))?;
    if public_key.len() != 32 {
        return Err(ApiError::BadRequest(
            "device public_key must be 32 bytes".into(),
        ));
    }
    if !body.keyfile.is_object() {
        return Err(ApiError::BadRequest("keyfile must be an object".into()));
    }
    let hash = nntdrive_crypto::hash_verifier(&body.verifier)
        .map_err(|_| ApiError::Internal(anyhow::anyhow!("verifier hashing failed")))?;

    let account_count: i64 = sqlx::query_scalar("SELECT count(*) FROM accounts")
        .fetch_one(&state.pool)
        .await?;
    if account_count > 0 && !state.config.allow_registration {
        return Err(ApiError::Forbidden);
    }
    let is_admin = account_count == 0;

    let mut tx = state.pool.begin().await?;
    let existing: Option<Uuid> =
        sqlx::query_scalar("SELECT id FROM accounts WHERE lower(email) = lower($1)")
            .bind(&body.email)
            .fetch_optional(&mut *tx)
            .await?;
    if existing.is_some() {
        return Err(ApiError::Conflict("email already registered".into()));
    }
    sqlx::query(
        "INSERT INTO accounts (id, email, password_hash, display_name, is_admin, keyfile, recovery_kit, quota_bytes)
         VALUES ($1, lower($2), $3, $4, $5, $6, $7, $8)",
    )
    .bind(body.account_id)
    .bind(body.email.trim())
    .bind(hash)
    .bind(body.display_name.unwrap_or_default())
    .bind(is_admin)
    .bind(&body.keyfile)
    .bind(&body.recovery_kit)
    .bind(state.config.default_quota_bytes)
    .execute(&mut *tx)
    .await?;
    let device_id = body.device.id.unwrap_or_else(Uuid::new_v4);
    upsert_device_tx(
        &mut tx,
        body.account_id,
        device_id,
        &body.device.name,
        body.device.platform.as_deref().unwrap_or("unknown"),
        &body.device.public_key,
    )
    .await?;
    let (token, token_id) =
        issue_token_tx(&mut tx, body.account_id, Some(device_id), "client").await?;
    tx.commit().await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "account_id": body.account_id,
            "device_id": device_id,
            "token": token,
            "token_id": token_id,
            "is_admin": is_admin,
        })),
    ))
}

#[derive(Debug, Deserialize)]
pub struct LoginPayload {
    pub email: String,
    pub verifier: String,
    #[serde(default)]
    pub device: Option<DevicePayload>,
}

pub async fn login(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(body): Json<LoginPayload>,
) -> ApiResult<impl IntoResponse> {
    if !state.limiter.allow(addr.ip()).await {
        return Err(ApiError::TooManyRequests);
    }
    let row = sqlx::query_as::<_, (Uuid, String, bool, Option<Value>, Option<Value>)>(
        "SELECT id, password_hash, disabled, keyfile, recovery_kit FROM accounts WHERE lower(email) = lower($1)",
    )
    .bind(body.email.trim())
    .fetch_optional(&state.pool)
    .await?
    .ok_or(ApiError::Unauthorized)?;
    if row.2 {
        return Err(ApiError::Unauthorized);
    }
    if !nntdrive_crypto::verify_verifier(&body.verifier, &row.1) {
        return Err(ApiError::Unauthorized);
    }
    let account_id = row.0;
    let (device_id, token) = match body.device {
        Some(device) => {
            let public_key = crate::error::unb64(&device.public_key)
                .map_err(|_| ApiError::BadRequest("bad device key".into()))?;
            if public_key.len() != 32 {
                return Err(ApiError::BadRequest(
                    "device public_key must be 32 bytes".into(),
                ));
            }
            let id = device.id.unwrap_or_else(Uuid::new_v4);
            let mut tx = state.pool.begin().await?;
            upsert_device_tx(
                &mut tx,
                account_id,
                id,
                &device.name,
                device.platform.as_deref().unwrap_or("unknown"),
                &device.public_key,
            )
            .await?;
            let (token, _) = issue_token_tx(&mut tx, account_id, Some(id), "client").await?;
            tx.commit().await?;
            (Some(id), token)
        }
        None => {
            let mut tx = state.pool.begin().await?;
            let (token, _) = issue_token_tx(&mut tx, account_id, None, "client").await?;
            tx.commit().await?;
            (None, token)
        }
    };

    let (quota, usage): (Option<i64>, i64) = sqlx::query_as(
        "SELECT a.quota_bytes,
                (SELECT COALESCE(SUM(plaintext_len),0)::bigint FROM chunks c WHERE c.account_id = a.id)
         FROM accounts a WHERE a.id = $1",
    )
    .bind(account_id)
    .fetch_one(&state.pool)
    .await?;
    Ok(Json(json!({
        "account_id": account_id,
        "device_id": device_id,
        "token": token,
        "keyfile": row.3,
        "recovery_kit": row.4,
        "quota_bytes": quota,
        "used_bytes": usage,
    })))
}

/// Resolves an email to its account id so a new device can derive the
/// account-bound Argon2 verifier before logging in. Rate-limited and reveals
/// only the account UUID; it does not confirm credentials.
#[derive(Debug, Deserialize)]
pub struct LookupQuery {
    pub email: String,
}

pub async fn lookup_account(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    axum::extract::Query(q): axum::extract::Query<LookupQuery>,
) -> ApiResult<impl IntoResponse> {
    if !state.limiter.allow(addr.ip()).await {
        return Err(ApiError::TooManyRequests);
    }
    let account_id: Option<Uuid> = sqlx::query_scalar(
        "SELECT id FROM accounts WHERE lower(email) = lower($1) AND disabled = FALSE",
    )
    .bind(q.email.trim())
    .fetch_optional(&state.pool)
    .await?;
    match account_id {
        Some(id) => Ok(Json(json!({ "account_id": id }))),
        None => Err(ApiError::NotFound),
    }
}

/// Reports whether this backend has no accounts yet, so a client can show the
/// first-run setup flow.
pub async fn setup_status(State(state): State<AppState>) -> ApiResult<impl IntoResponse> {
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM accounts")
        .fetch_one(&state.pool)
        .await?;
    Ok(Json(json!({
        "setup_required": count == 0,
        "registration_allowed": state.config.allow_registration,
    })))
}

#[derive(Debug, Deserialize)]
pub struct NewTokenPayload {
    pub label: String,
}

/// Mints an additional bearer token for the authenticated account. Used by the
/// first-run flow to hand the user an admin dashboard token once.
pub async fn create_token(
    State(state): State<AppState>,
    auth: Auth,
    Json(body): Json<NewTokenPayload>,
) -> ApiResult<impl IntoResponse> {
    let label = body.label.trim();
    if label.is_empty()
        || label.len() > 64
        || !label
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(ApiError::BadRequest(
            "label must be 1-64 letters, digits, '-' or '_'".into(),
        ));
    }
    let token = random_token();
    let id = Uuid::new_v4();
    let expires: DateTime<Utc> = sqlx::query_scalar(
        "INSERT INTO api_tokens (id, account_id, device_id, token_hash, scope, expires_at)
         VALUES ($1, $2, $3, $4, 'client', now() + interval '90 days')
         RETURNING expires_at",
    )
    .bind(id)
    .bind(auth.account_id)
    .bind(auth.device_id)
    .bind(sha256(token.as_bytes()).as_slice())
    .fetch_one(&state.pool)
    .await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "id": id,
            "token": token,
            "label": label,
            "expires_at": expires,
        })),
    ))
}

async fn upsert_device_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: Uuid,
    device_id: Uuid,
    name: &str,
    platform: &str,
    public_key: &str,
) -> ApiResult<()> {
    let existing: Option<(Uuid, Option<DateTime<Utc>>)> =
        sqlx::query_as("SELECT account_id, revoked_at FROM devices WHERE id = $1")
            .bind(device_id)
            .fetch_optional(&mut **tx)
            .await?;
    match existing {
        Some((owner, _)) if owner != account_id => Err(ApiError::Unauthorized),
        Some(_) => {
            sqlx::query(
                "UPDATE devices SET last_seen_at = now(), name = $2, platform = $3 WHERE id = $1",
            )
            .bind(device_id)
            .bind(name)
            .bind(platform)
            .execute(&mut **tx)
            .await?;
            Ok(())
        }
        None => {
            sqlx::query(
                "INSERT INTO devices (id, account_id, name, public_key, platform, last_seen_at)
                 VALUES ($1, $2, $3, $4, $5, now())",
            )
            .bind(device_id)
            .bind(account_id)
            .bind(name)
            .bind(public_key)
            .bind(platform)
            .execute(&mut **tx)
            .await?;
            Ok(())
        }
    }
}

async fn issue_token_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account_id: Uuid,
    device_id: Option<Uuid>,
    scope: &str,
) -> ApiResult<(String, Uuid)> {
    let token = random_token();
    let id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO api_tokens (id, account_id, device_id, token_hash, scope, expires_at)
         VALUES ($1, $2, $3, $4, $5, now() + interval '90 days')",
    )
    .bind(id)
    .bind(account_id)
    .bind(device_id)
    .bind(sha256(token.as_bytes()).as_slice())
    .bind(scope)
    .execute(&mut **tx)
    .await?;
    Ok((token, id))
}

fn validate_email(email: &str) -> Result<(), ApiError> {
    let email = email.trim();
    if email.len() < 3
        || email.len() > 320
        || !email.contains('@')
        || email.contains(char::is_whitespace)
    {
        return Err(ApiError::BadRequest("invalid email".into()));
    }
    Ok(())
}

pub async fn logout(State(state): State<AppState>, auth: Auth) -> ApiResult<impl IntoResponse> {
    sqlx::query("UPDATE api_tokens SET revoked_at = now() WHERE id = $1")
        .bind(auth.token_id)
        .execute(&state.pool)
        .await?;
    Ok(crate::state::json_ok("logged out"))
}

pub async fn me(State(state): State<AppState>, auth: Auth) -> ApiResult<impl IntoResponse> {
    let (email, display_name, is_admin, quota, created_at): (
        String,
        String,
        bool,
        Option<i64>,
        DateTime<Utc>,
    ) = sqlx::query_as(
        "SELECT email, display_name, is_admin, quota_bytes, created_at FROM accounts WHERE id = $1",
    )
    .bind(auth.account_id)
    .fetch_one(&state.pool)
    .await?;
    let (_, used) = state.store.count_storage(auth.account_id).await?;
    let devices: Vec<DeviceListRow> = sqlx::query_as(
        "SELECT id, name, platform, last_seen_at, revoked_at FROM devices WHERE account_id = $1 ORDER BY created_at",
    )
    .bind(auth.account_id)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(json!({
        "account_id": auth.account_id,
        "email": email,
        "display_name": display_name,
        "is_admin": is_admin,
        "quota_bytes": quota,
        "used_bytes": used,
        "created_at": created_at,
        "devices": devices.iter().map(|d| json!({
            "id": d.0, "name": d.1, "platform": d.2,
            "last_seen_at": d.3, "revoked_at": d.4,
            "current": Some(d.0) == auth.device_id
        })).collect::<Vec<_>>(),
    })))
}

pub async fn list_devices(
    State(state): State<AppState>,
    auth: Auth,
) -> ApiResult<impl IntoResponse> {
    let devices: Vec<DeviceListFullRow> = sqlx::query_as(
        "SELECT id, name, platform, created_at, last_seen_at, revoked_at
             FROM devices WHERE account_id = $1 ORDER BY created_at",
    )
    .bind(auth.account_id)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(json!({
        "devices": devices.iter().map(|d| json!({
            "id": d.0, "name": d.1, "platform": d.2, "created_at": d.3,
            "last_seen_at": d.4, "revoked_at": d.5, "current": Some(d.0) == auth.device_id
        })).collect::<Vec<_>>()
    })))
}

pub async fn revoke_device(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<Uuid>,
) -> ApiResult<impl IntoResponse> {
    let mut tx = state.pool.begin().await?;
    let updated = sqlx::query(
        "UPDATE devices SET revoked_at = now() WHERE id = $1 AND account_id = $2 AND revoked_at IS NULL",
    )
    .bind(id)
    .bind(auth.account_id)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if updated == 0 {
        return Err(ApiError::NotFound);
    }
    sqlx::query("UPDATE api_tokens SET revoked_at = now() WHERE device_id = $1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    // Note: content encrypted under the old key epoch stays readable to the
    // removed device. Clients must rotate the AMK and re-wrap it for remaining
    // devices; the server reports this in the response.
    Ok(Json(json!({
        "status": "revoked",
        "key_rotation_required": true,
        "message": "rotate the account master key and wrap it for remaining devices"
    })))
}

/// Stores an encrypted provider password for the admin API. Never returns it.
pub fn seal_provider_password(state: &AppState, password: &str) -> Vec<u8> {
    encrypt_secret(&state.config.secret_key, password.as_bytes())
}

pub fn public_device_key(public_key: &str) -> String {
    public_key.to_string()
}

pub fn token_hash_hex(token: &str) -> String {
    hex(&sha256(token.as_bytes()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn redacted_key(keyfile: &Value) -> Value {
    json!({ "present": keyfile.is_object() })
}

pub fn _unused_b64() -> String {
    b64(b"")
}
