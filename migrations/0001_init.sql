-- NNTDrive initial schema.
-- The server can read IDs, sizes, timestamps and opaque encrypted blobs.
-- Names, manifests, file contents and wrapped keys are ciphertext.

CREATE TABLE IF NOT EXISTS accounts (
    id              UUID PRIMARY KEY,
    email           TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    display_name    TEXT NOT NULL DEFAULT '',
    disabled        BOOLEAN NOT NULL DEFAULT FALSE,
    is_admin        BOOLEAN NOT NULL DEFAULT FALSE,
    quota_bytes     BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS accounts_email_unique ON accounts (lower(email));

CREATE TABLE IF NOT EXISTS devices (
    id              UUID PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    public_key      TEXT NOT NULL,
    platform        TEXT NOT NULL DEFAULT 'unknown',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at    TIMESTAMPTZ,
    revoked_at      TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS devices_account_idx ON devices (account_id);

-- Bearer tokens are stored as SHA-256 hashes; the plaintext token is returned
-- exactly once at login/enrollment.
CREATE TABLE IF NOT EXISTS api_tokens (
    id              UUID PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    device_id       UUID REFERENCES devices(id) ON DELETE CASCADE,
    token_hash      BYTEA NOT NULL UNIQUE,
    scope           TEXT NOT NULL DEFAULT 'client',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ,
    revoked_at      TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS api_tokens_account_idx ON api_tokens (account_id);

-- Logical namespace. `name_enc` is a client-sealed envelope bound to the node
-- id, so the server cannot read names or correlate equal names across nodes.
CREATE TABLE IF NOT EXISTS files (
    id              UUID PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    parent_id       UUID REFERENCES files(id) ON DELETE CASCADE,
    name_enc        BYTEA NOT NULL,
    is_dir          BOOLEAN NOT NULL DEFAULT FALSE,
    size            BIGINT NOT NULL DEFAULT 0,
    current_version UUID,
    content_hash    BYTEA,
    deleted         BOOLEAN NOT NULL DEFAULT FALSE,
    favorite        BOOLEAN NOT NULL DEFAULT FALSE,
    revision        BIGINT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS files_account_parent_idx ON files (account_id, parent_id);
CREATE UNIQUE INDEX IF NOT EXISTS files_account_id_unique ON files (account_id, id);

-- Immutable, client-sealed file manifests. Every content change is a new row.
CREATE TABLE IF NOT EXISTS file_versions (
    id              UUID PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    file_id         UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    revision_id     UUID NOT NULL,
    parent_revision UUID,
    device_id       UUID REFERENCES devices(id) ON DELETE SET NULL,
    size            BIGINT NOT NULL,
    content_hash    BYTEA,
    manifest        BYTEA NOT NULL,
    deleted         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (account_id, revision_id, file_id)
);
CREATE INDEX IF NOT EXISTS file_versions_file_idx ON file_versions (file_id, created_at DESC);
CREATE INDEX IF NOT EXISTS file_versions_account_idx ON file_versions (account_id, created_at DESC);

-- One row per distinct plaintext chunk inside an account's encryption scope.
-- Chunks are deduplicated by plaintext hash but stored only as ciphertext, and
-- reuse never crosses accounts.
CREATE TABLE IF NOT EXISTS chunks (
    id              UUID PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    plaintext_hash  BYTEA NOT NULL,
    plaintext_len   BIGINT NOT NULL,
    ciphertext_len  BIGINT NOT NULL,
    compression     SMALLINT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (account_id, plaintext_hash, plaintext_len)
);

CREATE TABLE IF NOT EXISTS stripes (
    id              UUID PRIMARY KEY,
    chunk_id        UUID NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
    stripe_index    INTEGER NOT NULL,
    data_shards     INTEGER NOT NULL,
    parity_shards   INTEGER NOT NULL,
    shard_len       INTEGER NOT NULL,
    ciphertext_len  INTEGER NOT NULL,
    UNIQUE (chunk_id, stripe_index)
);

-- Current location of a shard. Repair/refresh atomically replaces message_id
-- and moves the old value into shard_history.
CREATE TABLE IF NOT EXISTS shards (
    id              UUID PRIMARY KEY,
    stripe_id       UUID NOT NULL REFERENCES stripes(id) ON DELETE CASCADE,
    shard_index     INTEGER NOT NULL,
    message_id      TEXT NOT NULL,
    sha256          TEXT NOT NULL,
    size            BIGINT NOT NULL,
    provider        TEXT,
    generation      INTEGER NOT NULL DEFAULT 1,
    status          TEXT NOT NULL DEFAULT 'unknown',
    posted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    checked_at      TIMESTAMPTZ,
    UNIQUE (stripe_id, shard_index)
);
CREATE INDEX IF NOT EXISTS shards_message_id_idx ON shards (message_id);
CREATE INDEX IF NOT EXISTS shards_status_idx ON shards (status);
CREATE INDEX IF NOT EXISTS shards_posted_idx ON shards (posted_at);

CREATE TABLE IF NOT EXISTS shard_history (
    id              BIGSERIAL PRIMARY KEY,
    shard_id        UUID NOT NULL REFERENCES shards(id) ON DELETE CASCADE,
    message_id      TEXT NOT NULL,
    provider        TEXT,
    generation      INTEGER NOT NULL,
    reason          TEXT NOT NULL,
    replaced_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Durable background jobs. Workers claim rows with FOR UPDATE SKIP LOCKED and
-- jobs are idempotent, so a crash resumes safely.
CREATE TABLE IF NOT EXISTS jobs (
    id              UUID PRIMARY KEY,
    kind            TEXT NOT NULL,
    dedupe_key      TEXT UNIQUE,
    state           TEXT NOT NULL DEFAULT 'pending',
    payload         JSONB NOT NULL DEFAULT '{}'::jsonb,
    attempts        INTEGER NOT NULL DEFAULT 0,
    max_attempts    INTEGER NOT NULL DEFAULT 10,
    run_after       TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_by       TEXT,
    locked_at       TIMESTAMPTZ,
    last_error      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS jobs_ready_idx ON jobs (state, run_after);

-- Change log consumed by clients over SSE/WebSocket. `seq` is per account and
-- monotonic, giving clients a resumable cursor.
CREATE TABLE IF NOT EXISTS sync_events (
    id              BIGSERIAL PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    seq             BIGINT NOT NULL,
    device_id       UUID,
    file_id         UUID,
    revision_id     UUID,
    kind            TEXT NOT NULL,
    payload         JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS sync_events_account_seq_unique ON sync_events (account_id, seq);
CREATE INDEX IF NOT EXISTS sync_events_account_created_idx ON sync_events (account_id, created_at DESC);

-- Provider credentials are encrypted at rest with NNTDRIVE_MASTER_KEY. They are
-- never returned to non-admin clients.
CREATE TABLE IF NOT EXISTS providers (
    id              UUID PRIMARY KEY,
    name            TEXT NOT NULL UNIQUE,
    host            TEXT NOT NULL,
    port            INTEGER NOT NULL,
    tls             BOOLEAN NOT NULL DEFAULT TRUE,
    username        TEXT,
    password_enc    BYTEA,
    max_connections INTEGER NOT NULL DEFAULT 4,
    role            TEXT NOT NULL DEFAULT 'both',
    priority        INTEGER NOT NULL DEFAULT 100,
    groups          TEXT[] NOT NULL DEFAULT '{}',
    retention_days  INTEGER,
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS server_settings (
    key             TEXT PRIMARY KEY,
    value           JSONB NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS folder_shares (
    id              UUID PRIMARY KEY,
    owner_id        UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    grantee_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    file_id         UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    permission      TEXT NOT NULL DEFAULT 'read',
    wrapped_key     BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at      TIMESTAMPTZ,
    UNIQUE (owner_id, grantee_id, file_id)
);
CREATE INDEX IF NOT EXISTS folder_shares_grantee_idx ON folder_shares (grantee_id);

CREATE TABLE IF NOT EXISTS share_links (
    id              UUID PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    file_id         UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    token_hash      BYTEA NOT NULL UNIQUE,
    password_hash   TEXT,
    expires_at      TIMESTAMPTZ,
    max_downloads   INTEGER,
    downloads       INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at      TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS audit_log (
    id              BIGSERIAL PRIMARY KEY,
    account_id      UUID,
    device_id       UUID,
    action          TEXT NOT NULL,
    detail          JSONB NOT NULL DEFAULT '{}'::jsonb,
    ip              TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_log_created_idx ON audit_log (created_at DESC);
