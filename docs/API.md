# HTTP API

Base path: `/api/v1`. All endpoints except registration/login require
`Authorization: Bearer <token>`. Bodies are JSON unless noted. Errors:
`{"error":"code","message":"..."}` with a 4xx/5xx status.

The server cannot decrypt names or manifests. `name_enc` and
`sealed_manifest` are base64-encoded client ciphertext.

## Identity

| Method | Path | Body |
|---|---|---|
| POST | `/auth/register` | `{account_id, email, verifier, keyfile, recovery_kit?, device:{id,name,platform,public_key}}` |
| POST | `/auth/login` | `{email, verifier, device?}` → `{token, keyfile, account_id, ...}` |
| GET | `/auth/lookup?email=` | resolve account id so a new device can derive the account-bound verifier (rate-limited) |
| GET | `/setup/status` | `{setup_required, registration_allowed}`; used for first-run setup |
| POST | `/tokens` | mint an additional 90-day token for the authenticated account `{label}` → `{token, expires_at}` |
| POST | `/auth/logout` | — |
| GET | `/me` | account, quota, usage, devices |
| GET | `/devices` | device list |
| DELETE | `/devices/{id}` | revoke device + tokens; response says key rotation is required |

`verifier` is the 64-hex Argon2id value from
`nntdrive_crypto::derive_auth_verifier(password, account_id)`. Passwords are
never sent. The first registered account becomes administrator if no account
exists; afterwards registration is disabled unless `NNTDRIVE_ALLOW_REGISTRATION=1`.

## Files

| Method | Path | Purpose |
|---|---|---|
| GET | `/files?parent_id=<uuid>` | list encrypted nodes in a folder |
| POST | `/files` | `{id,parent_id,name_enc,is_dir}` |
| PATCH | `/files/{id}` | `{name_enc?,favorite?,deleted?}` (delete is a tombstone) |
| POST | `/files/{id}/move` | `{parent_id}` (cycle-checked) |
| GET | `/files/{id}/versions` | revision metadata |
| POST | `/files/{id}/versions` | `{revision_id,parent_revision,base_revision,size,sealed_manifest}` |
| GET | `/files/{id}/manifest?revision=<uuid>` | raw sealed manifest bytes |

`base_revision` provides optimistic concurrency: a mismatch returns `409`.
A version is only visible after commit; clients must upload all chunks first.

## Ciphertext chunks

| Method | Path | Purpose |
|---|---|---|
| GET | `/chunks/lookup?hash=<hex>&len=<n>` | find an existing chunk for this account |
| POST | `/chunks` | publish one client-encrypted chunk |
| GET | `/chunks/{id}` | article locations (stripe layout + Message-IDs) for reconstruction |
| GET | `/articles/{message_id}` | fetch one shard (authenticated, tenant-scoped) |

Chunk body:

```json
{
  "chunk_id": "uuid",
  "index": 0,
  "offset": 0,
  "plaintext_hash": "<64 hex>",
  "plaintext_len": 1048576,
  "compression": 1,
  "ciphertext": "<base64 envelope>"
}
```

The backend Reed–Solomon codes and posts the ciphertext, verifies it, and returns
the manifest fragment (`chunk` with stripe IDs and shard hashes). It never
receives plaintext or keys. The client seals the manifest and commits it.

## Events

| Method | Path | Purpose |
|---|---|---|
| GET | `/events?since=<seq>` | JSON change list |
| GET | `/events/stream?since=<seq>` | SSE stream (`event: change`, JSON data) |

Use the `seq` of the last processed event as the next cursor. Events cover create,
move, delete and version commits.

## Admin

Requires `accounts.is_admin`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/admin/stats` | users, storage, redundancy, cache, article health, jobs, providers |
| GET | `/admin/users` | users, usage, quota, devices |
| PATCH | `/admin/users/{id}` | `{disabled?,quota_bytes?,is_admin?}` |
| GET/POST | `/admin/providers` | list (no passwords) / add (applied on serving backend) |
| DELETE | `/admin/providers/{id}` | remove (applied on serving backend) |
| GET/POST | `/admin/jobs` | list / enqueue `{kind,payload}` |
| GET/PUT | `/admin/retention` | read / save `{refresh_days}` (integer 1–36500); administrator only |
| POST | `/admin/restart` | gracefully stop the backend so Compose/systemd restarts it (not needed for provider CRUD) |
| GET | `/admin/articles/verify` | STAT the 20 newest articles through the retrieval providers; returns per-article availability |
| POST | `/admin/providers/{id}/test` | DNS/TLS/auth check for a stored provider (no posting) |

The embedded dashboard is `GET /admin`.

## Health

`GET /healthz` (unauthenticated) returns 200 `{"status":"ok"}` when PostgreSQL is
reachable, otherwise 503. It is safe for load balancers and Docker healthchecks.

## Client sync flow

1. Login → token + keyfile; unlock locally.
2. Scan local tree, load SQLite journal.
3. Pull `/events?since=cursor` or `/events/stream`.
4. For changed files, fetch `/files/{id}/manifest`, decrypt, validate.
5. Fetch shards either directly from Usenet or via `/articles/{message_id}`,
   verify hashes, reconstruct, decrypt.
6. Local changes: chunk/encrypt locally, lookup/publish chunks, seal manifest,
   commit version with `base_revision`.
7. Apply conflicts via the Rust sync engine; persist the new cursor.

Provider `POST`, `PATCH /admin/providers/{id}` (omitted fields retained; blank
password retains stored password), and `DELETE` require administrator auth.
Success includes `restart_required: false` and `applied: true`. Replacement is
local to the serving backend, not coordinated across replicas. Invalid configs
or stored credentials roll back the mutation and retain the prior pool. Config
validation does not probe connectivity. Disabling/deleting the last provider
leaves no providers, with no environment fallback. See Operations for the sticky
DB-managed marker and single-process limitation.

Retention policy defaults to `NNTDRIVE_REFRESH_DAYS` until explicitly saved in
PostgreSQL. The dashboard saves and reads back the article-age threshold; workers
read it at each subsequent refresh batch without restart. It is independent of
provider retention hints and is not a guarantee against article expiry. The
scheduler interval remains environment-configured.

Jobs expose a nullable durable `result` object, stored atomically with `done`:
health batches report `checked`, `degraded`, `below_threshold`, `continued`;
refresh batches report `checked`, `refreshed`, `failed`, `refresh_days`,
`continued`; repairs report `reposted`, `unrecoverable`. These are per-batch,
not whole-sweep totals. Health `below_threshold` includes provider errors and is
not proof of permanent loss. `done` means the batch returned, not that data is healthy:
inspect failure/unrecoverable counts. Failed jobs use a fixed diagnostic message
(`failed` on refresh includes an expired stripe that returned without reposting,
including unrecoverable data, as well as transport/verification errors)
rather than persisting new raw errors. Old jobs retain their existing diagnostics
and have null results. Completed results survive restarts; this does not add
crash recovery of jobs left `running`, a lease, or a whole-sweep retry protocol.

Reference-safe orphan metadata cleanup is explicit per account, never scheduled
by default. Admins enqueue `orphan_gc` with
`{"account_id":"<uuid>","grace_days":7,"require_reference_commits":true}`.
Grace must be 1..3650 days. Each run removes at most 1000 chunks older than the
grace period which have **no** references from **any** version, including
historical, conflict and tombstoned versions. Cascades remove local stripe/shard
indexes only; posted NNTP articles cannot be retracted. Results expose
`deleted_chunks`, `account_id`, `grace_days`, `batch_limit`, and
`reference_commits_required`; blocked accounts return zero deletions and
`blocked: "incomplete_version_references"`. Repeat for additional batches.

New version commits may include `chunk_ids: [uuid,...]`, the complete unique
chunk identity set from the client-authenticated manifest (empty only for an
empty file). The Rust SDK includes it for all uploads and deduplicated reuse;
older servers ignore this additive field. The backend cannot decrypt or verify
completeness cryptographically: the account's authenticated client must supply
the honest complete set. No names, keys, content hashes or manifest plaintext
are added to this protocol; chunk/version association is additional metadata.

Migration 0005 deliberately leaves **all** existing versions incomplete. Omitted
or null references from legacy clients also stay incomplete, never implicitly
empty. GET `/reference-backfill?after=<version-row-uuid>` returns up to 200
account-scoped incomplete revision identities plus `next` (or null), including
hidden tombstones. An unlocked client decrypts and validates each exact manifest,
then PUTs `/files/{id}/versions/{revision}/references` with `{chunk_ids:[...]}`.
The set is write-once; identical retries are accepted, changing a complete set
is refused. Exact-revision manifest reads support logically deleted files;
latest reads continue to hide them. Rust SDK helpers
`backfill_version_references` and `backfill_account_references` implement this
flow; no automatic Flutter backfill action is shipped yet. Wrong keys or invalid
manifests stop backfill without marking that revision complete. Concurrent old
uploads may require another pass; GC rechecks completeness under the lock.

GC refuses an account if **any** version is incomplete, leaving its compatibility
policy unchanged. First successful GC, even zero deletions, permanently requires
reference-aware commits for that account. Upgrade all clients before opting in.
Commits, backfill and GC share a PostgreSQL account advisory transaction lock;
a database insert trigger enforces the compatibility fence even on an older
backend binary, and composite foreign keys prevent cross-tenant references and
dangling committed versions. A stale reuse/upload racing GC either commits first
and is protected, or fails atomically and must be retried; grace is not an upload
lease. This does not purge versions or recover space from deleted files with
retained history. No production data should be used to test cleanup.
