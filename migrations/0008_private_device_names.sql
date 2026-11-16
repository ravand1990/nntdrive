-- Device display labels live only in the existing client-sealed root
-- files.name_enc (bound to that node ID). The legacy column remains for old
-- clients/backends, but is never a second, plaintext display-label store.
-- ALTER takes a table lock held through this transactional migration, so no
-- legacy writer can slip between the scrub and installation of the trigger.
ALTER TABLE devices ALTER COLUMN name SET DEFAULT 'Device';

UPDATE devices SET name = 'Device' WHERE name IS DISTINCT FROM 'Device';

CREATE FUNCTION normalize_device_name() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.name := 'Device';
    RETURN NEW;
END;
$$;

-- Normalize rather than reject: rolling upgrades and old clients keep their
-- enrollment/login behavior without being able to restore plaintext names.
CREATE TRIGGER devices_anonymous_name
BEFORE INSERT OR UPDATE ON devices
FOR EACH ROW EXECUTE FUNCTION normalize_device_name();
