# Disaster recovery

## Assets you must protect

| Asset | Where | Lost → consequence |
|---|---|---|
| Recovery kit (`*.recovery.json`) + recovery code | Offline, separate from backups | Total, irreversible loss of E2EE data |
| Password/keyfile | Password manager / user devices | Recover with the kit; otherwise lost |
| PostgreSQL backup | Off-host backup storage | Article Message-IDs, manifests and provider configs are lost |
| `NNTDRIVE_SECRET_KEY` | Secret manager **and** offline | Provider passwords in DB backups become unreadable |
| Usenet provider account | Provider | Cannot retrieve/post; storage still exists at the provider |
| `checkpoint.json` | With each DB backup | Integrity/version reference; not secret |

The recovery kit contains the AMK wrapped with a 256-bit recovery code through
Argon2id. It contains no user files. Treat it as the root of recovery.

## Recovery anchor design

Usenet offers no globally mutable "latest metadata" object. NNTDrive therefore
uses:

1. an external, versioned checkpoint: `checkpoint.json` + database dump hash;
2. encrypted manifests inside PostgreSQL (and therefore inside the dump);
3. article Message-IDs in PostgreSQL pointing at immutable Usenet articles.

Restoring the latest dump recovers the latest committed state. If the dump is
older than the newest writes, those newer revisions are not referenced and look
like version loss; the underlying articles may still exist but their Message-IDs
are unknown. This is why backups must be frequent and verified.

## Scenario: backend server lost

1. Provision a new Linux host, Docker + Compose.
2. Restore `deploy/.env` (including the same `NNTDRIVE_SECRET_KEY` if you need
   provider passwords from the DB; otherwise re-enter providers).
3. Start PostgreSQL and the backend, then restore the latest dump with
   `scripts/restore.sh <backup> --yes`.
4. Verify `/healthz`; open `/admin` with a newly minted operator token.
5. Run a health sweep. Run downloads for a few important files.
6. Clients resume from their last `since` cursor (events retained in the DB
   backup). Re-login if tokens were lost.

## Scenario: PostgreSQL lost, Usenet intact

- With a DB backup: follow the backend-loss procedure. The sealed manifests and
  Message-IDs are in the dump.
- Without a DB backup: file contents may still be on Usenet, but NNTDrive cannot
  enumerate them. There is no central mutable index to recover. Potential
  long-shot: NZBs previously exported by users reference Message-IDs; they allow
  manual retrieval of known files. This is not a supported automated recovery.

## Scenario: client device lost

- Revoke the device/token in the admin UI or `/api/v1/devices/:id`.
- Generate a new AMK epoch and wrap it for remaining devices (client procedure).
  Content already encrypted under the old epoch remains readable to the lost
  device, but new content will not be.
- The new device can log in with the password/keyfile and re-download.

## Scenario: lost password, recovery kit available

```bash
nntdrive recovery-restore --kit recovery.json --out new.keyfile.json
# NNTDRIVE_RECOVERY_CODE and NNTDRIVE_PASSWORD are read from the environment
```

Then restore the DB backup and continue. The new keyfile wraps the same AMK, so
existing content remains readable.

## Scenario: lost recovery kit and password

Data is unrecoverable by design. The backend cannot reset E2EE keys. This is not
a bug; plan for it by storing the kit offline in a safe, and testing recovery
before uploading irreplaceable data.

## Scenario: damaged/missing chunks

1. Open the admin dashboard → inspect missing/corrupt shard counts.
2. Run a health sweep or wait for the schedule.
3. Repair runs automatically for degraded stripes. Each replacement is fetched
   back and hashed before the metadata swap.
4. If available shards < `k` for a stripe, the file is reported **unrecoverable**.
   Do not expect repair to invent missing data. Restore the file from a client
   copy or an older revision backup if one exists.

## Scenario: whole upload batch expired

If an entire batch of articles disappeared (e.g., a provider retention event),
multiple stripes can be unrecoverable at once. Erasure coding only protects
within a stripe. Mitigations:

- configure retention refresh with a margin well below the provider limit;
- use more parity for irreplaceable data;
- keep an offline copy of critical files;
- avoid relying on a single provider/backbone even when using multiple brands.

## Scenario: changing Usenet providers

1. Add the new provider with `retrieval_only` and check a sample download.
2. If it lacks the old articles, keep the old account for retrieval or restore
   them from a client.
3. Mark the new provider `both`/`posting_only` as desired via admin CRUD; it is applied on the serving backend without restart.
4. Health sweeps will record which articles are retrievable. Repairs and refreshes
   post to the current posting provider.
5. Nothing in the metadata changes provider names retroactively; old references
   remain honest about where an article was posted.

## Scenario: migrating the backend to another Linux server

Same as "backend server lost" but planned: stop the backend, take a final dump,
copy `.env` (or re-enter secrets), restore on the new host, point DNS at it, then
start clients. Keep the old host read-only until verification completes.

## Restore verification checklist

- [ ] `sha256sum -c SHA256SUMS` succeeds.
- [ ] Backend starts and migrations complete.
- [ ] `/healthz` returns `ok`.
- [ ] Admin stats show expected users/devices/files.
- [ ] Health sweep completes without unrecoverable stripes.
- [ ] Download one small, one large and one old revision; hashes match.
- [ ] Recovery kit restores a keyfile and opens a sealed manifest.
- [ ] Provider credentials work (post a test chunk).
- [ ] Backups resume on schedule; off-host copy verified.
