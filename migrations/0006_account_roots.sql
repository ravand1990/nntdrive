-- Fixed account roots: exactly one Global space per account and one root per
-- registered device. The backend stores only opaque node IDs plus the client
-- sealed name envelope; it never learns a root or folder name.
CREATE TABLE IF NOT EXISTS account_roots (
    id              UUID PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind            TEXT NOT NULL,
    device_id       UUID REFERENCES devices(id) ON DELETE RESTRICT,
    node_id         UUID NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT account_roots_kind_check CHECK (kind IN ('global', 'device')),
    CONSTRAINT account_roots_device_check CHECK (
        (kind = 'global' AND device_id IS NULL)
        OR (kind = 'device' AND device_id IS NOT NULL)
    ),
    CONSTRAINT account_roots_node_fk FOREIGN KEY (account_id, node_id)
        REFERENCES files (account_id, id) ON DELETE CASCADE
);

-- One Global root per account; one root per device. Both constraints are the
-- only guard against two clients bootstrapping concurrently.
CREATE UNIQUE INDEX IF NOT EXISTS account_roots_global_unique
    ON account_roots (account_id) WHERE kind = 'global';
CREATE UNIQUE INDEX IF NOT EXISTS account_roots_device_unique
    ON account_roots (account_id, device_id) WHERE kind = 'device';
CREATE UNIQUE INDEX IF NOT EXISTS account_roots_node_unique
    ON account_roots (node_id);
CREATE INDEX IF NOT EXISTS account_roots_account_idx
    ON account_roots (account_id, created_at);
