-- Trash: a logical delete keeps its timestamp so the item can be listed,
-- restored inside a retention window and eventually expired. Files already
-- deleted before this migration fall back to their last update time.
ALTER TABLE files ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

UPDATE files SET deleted_at = updated_at WHERE deleted = TRUE AND deleted_at IS NULL;

-- Only the trash view reads this shape: deleted rows, newest first, per account.
CREATE INDEX IF NOT EXISTS files_account_trash_idx
    ON files (account_id, deleted_at DESC)
    WHERE deleted = TRUE;
