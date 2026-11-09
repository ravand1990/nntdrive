-- Opaque manifests cannot be backfilled by the server. Existing versions stay
-- incomplete until an authenticated, unlocked client supplies their chunk IDs.
ALTER TABLE accounts ADD COLUMN reference_commits_required BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE file_versions ADD COLUMN references_complete BOOLEAN NOT NULL DEFAULT FALSE;
CREATE UNIQUE INDEX chunks_account_id_unique ON chunks(account_id, id);
CREATE UNIQUE INDEX versions_account_id_unique ON file_versions(account_id, id);
CREATE TABLE version_chunks (
    account_id UUID NOT NULL,
    version_id UUID NOT NULL,
    chunk_id UUID NOT NULL,
    PRIMARY KEY(account_id, version_id, chunk_id),
    FOREIGN KEY(account_id, version_id) REFERENCES file_versions(account_id, id) ON DELETE CASCADE,
    FOREIGN KEY(account_id, chunk_id) REFERENCES chunks(account_id, id) ON DELETE NO ACTION
);
CREATE INDEX version_chunks_chunk_idx ON version_chunks(account_id, chunk_id);
CREATE INDEX versions_incomplete_idx ON file_versions(account_id) WHERE NOT references_complete;

-- Keep the opt-in fence effective even if an old backend binary is restarted.
-- Every writer, not merely the new HTTP handler, participates in serialization.
CREATE FUNCTION enforce_reference_commit_policy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext(NEW.account_id::text));
    IF NOT NEW.references_complete AND EXISTS (
        SELECT 1 FROM accounts WHERE id = NEW.account_id AND reference_commits_required
    ) THEN
        RAISE EXCEPTION 'complete chunk references required; upgrade client';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER version_reference_policy BEFORE INSERT ON file_versions
    FOR EACH ROW EXECUTE FUNCTION enforce_reference_commit_policy();
