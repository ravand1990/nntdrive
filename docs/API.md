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
DB-managed marker and single-process limitation. Retention policy administration
and reference-safe garbage collection are not implemented by this change.
