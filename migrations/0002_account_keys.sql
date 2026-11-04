-- Server-side account bootstrap data. `keyfile` is the password-wrapped master
-- key; the backend can store it but can never open it. The verifier is already
-- hashed by `accounts.password_hash`.
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS keyfile JSONB;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS recovery_kit JSONB;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS sync_cursor BIGINT NOT NULL DEFAULT 0;

-- Tracks the newest revision a device has acknowledged, used for SSE catch-up
-- and for detecting offline edits.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_seq BIGINT NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS key_epoch INTEGER NOT NULL DEFAULT 0;

-- Per-device enrollment records needed to wrap the account key for a new
-- device. Only public keys are stored.
CREATE TABLE IF NOT EXISTS device_enrollments (
    id              UUID PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    device_id       UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    requested_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_at     TIMESTAMPTZ,
    approved_by     UUID REFERENCES devices(id) ON DELETE SET NULL
);

-- Persisted NNTP configuration secrets use the server's master key. The table
-- from 0001 already has password_enc.
