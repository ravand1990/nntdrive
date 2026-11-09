-- Preserve bounded, secret-free per-batch results separately from diagnostic errors.
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS result JSONB;
CREATE TABLE IF NOT EXISTS maintenance_settings (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    refresh_days INTEGER NOT NULL CHECK (refresh_days BETWEEN 1 AND 36500)
);
