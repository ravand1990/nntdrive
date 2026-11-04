# Architecture

## Goals and invariants

1. Usenet is the primary storage medium. The backend may cache, but must not
   require a permanent copy of the library.
2. The backend never sees plaintext content, plaintext filenames, directory
   structure, manifests, or account master keys.
3. A version becomes visible only after every chunk was posted and the required
   number of articles was verified by read-back or STAT.
4. Metadata is immutable and versioned. Updates are transactional.
5. Repair and retention never claim success without verifying replacement
   articles and atomically swapping metadata.
6. When fewer than `k` shards survive, the system reports the stripe as
   unrecoverable. It never fabricates data.

## Components

| Component | Responsibility |
|---|---|
| `nntdrive-crypto` | AMK keyfile, Argon2id, HKDF derivation, XChaCha20-Poly1305 envelopes, chunk keys, sealed names/manifests, X25519 device wrapping, recovery kits, auth verifiers |
| `nntdrive-nntp` | TLS NNTP, auth, pooled connections, retries/backoff, yEnc, NZB, STAT/BODY/POST/HEAD, provider statistics, fault-injecting mock server |
| `nntdrive-storage` | Streaming FastCDC, zstd, erasure coding, manifest types, PostgreSQL index, upload/download, health, repair, refresh |
| `nntdrive-sync` | Filesystem scanning, ignore rules, case-collision detection, SQLite baseline journal, pure three-way reconciliation, action execution against a `Remote` |
| `nntdrive-backend` | Axum API, tenant auth, devices, file namespace, ciphertext chunk intake, article proxy/cache, SSE, admin API/dashboard, durable jobs |
| `nntdrive-cli` | Operator bootstrap, recovery actions, health/repair/refresh, Phase 1/2 demonstration |

The Flutter clients are intended to embed the shared Rust engine. Today only the
UI/API scaffold exists (see `CLIENTS.md`).

## Key hierarchy

```text
password ──Argon2id(salt in keyfile)──▶ KEK ──XChaCha20-Poly1305──▶ AMK
recovery code ──Argon2id(salt in kit)──▶ KEK ──────────────▶ AMK
device X25519 private key ──ECDH+HKDF──▶ KEK ──────────────▶ AMK

AMK ──HKDF(salt = account_id || epoch, "file-key", file_id)──▶ file key
file key ──HKDF("chunk-key", chunk_index)──────────────────────▶ chunk key
AMK ──HKDF("content-chunk-key", plaintext BLAKE3)─────────────▶ chunk key *
AMK ──HKDF("name-key" / "manifest-key" / "keyring-key")────────▶ domain keys
```

`*` Storage uses an account-scoped content key derived from the plaintext chunk
hash so that unchanged chunks can be reused without re-encryption. This is **not**
convergent encryption: the server never sees the hash or key, nonces are random,
and deduplication is limited to one account's encryption scope.

Every envelope is `version || 24-byte random nonce || ciphertext+tag` with AAD:

- chunk: `"nntdrive/v1/chunk" || chunk_id || plaintext_hash || plaintext_len || compression`
- name: `"nntdrive/v1/name" || node_id || epoch`
- manifest: `"nntdrive/v1/manifest" || file_id || revision_id`
- AMK wrap: `"nntdrive/v1/amk-wrap" || account_id || epoch`
- recovery: `"nntdrive/v1/recovery-kit" || account_id || epoch`
- device enrollment: `"nntdrive/v1/device-wrap" || device_id || ephemeral_pub || recipient_pub`

Chunk identity is the plaintext BLAKE3 hash plus length. Shard identity is
SHA-256 of the shard bytes and is pinned in the sealed manifest, so a malicious
backend cannot swap article contents without client detection.

## Upload pipeline

1. Client streams the file through FastCDC (256 KiB / 1 MiB / 4 MiB).
2. Each chunk is compressed with zstd when it saves >32 bytes.
3. The chunk key is derived, a random nonce is generated, and the compressed
   chunk is sealed. Compression is authenticated.
4. The client looks up `(account, plaintext_hash, length)` for reuse. Reuse means
   the identical ciphertext and article references are referenced again.
5. Otherwise the ciphertext is split into stripes of at most
   `max_data_shards × shard_size` (default 10 × 512 KiB), padded, and
   Reed–Solomon coded. Small chunks use fewer data shards so a 1 KiB chunk does
   not become 5 MiB of padding.
6. Each shard becomes one yEnc article (`Message-ID` generated locally). Subject
   lines contain only opaque IDs, never names.
7. Every article is STAT-ed and optionally fetched back and hash-verified. The
   default durability threshold is `k + 1` verified shards (capped at `k + m`).
8. Chunk, stripe and shard rows are inserted atomically.
9. The client builds the manifest, seals it, and commits the revision. Only now
   is the version visible. A crash earlier leaves unreferenced chunks/articles,
   never a corrupt visible version.
10. The backend emits a `sync_events` row consumed by other devices via SSE.

Empty files produce an empty manifest and no articles.

## Download pipeline

1. Authenticate, fetch the sealed manifest, decrypt and structure-validate it.
2. For each chunk, fetch shards until `k` valid ones are available. Each shard is
   verified against the manifest hash **before** reconstruction.
3. Reconstruct missing data/parity, decrypt (AAD rejects tampering), decompress,
   verify the chunk hash and length.
4. Verify the whole-file hash after writing, via a temporary file + rename in the
   sync engine so interrupted downloads never masquerade as complete.
5. If fewer than `k` shards exist, return `Unrecoverable`; provider failures are
   reported separately from confirmed article loss.

## Self-healing

Health sweeps STAT every article of a stripe. Statuses (`ok`, `missing`,
`corrupt`, `unknown`) are updated. Degraded stripes (`k ≤ available < k+m`) are
enqueued for repair; unrecoverable stripes are flagged and never "repaired".

Repair fetches valid shards, reconstructs the stripe, re-encodes all shards, and
reposts only missing/corrupt indices with fresh Message-IDs. Each reposted
article is fetched back and hash-verified. Metadata is then swapped in one
transaction and the old Message-IDs are written to `shard_history`.

Retention refresh fetches a stripe, reposts **all** shards under fresh
Message-IDs, verifies them, then swaps all locations atomically. This protects
against provider retention windows and whole-batch expiry. Without a recent
refresh, correlated loss of an entire upload batch can exceed parity and is
reported unrecoverable — erasure coding alone does not make retention unlimited.

## Synchronization

The client scans the filesystem (skip temp/lock files, reject symlinks escaping
the root, detect case collisions) and compares against a SQLite baseline of the
last synced content hashes and server revisions.

`reconcile()` is pure and uses revisions plus content hashes, not mtimes:

- both sides modified differently → conflict: local file renamed to
  `name (conflict <device> <timestamp>).ext`, remote version downloaded to the
  original path, conflict copy uploaded as a new file;
- local delete vs remote modify → remote restored (data preservation wins);
- local modify vs remote delete → local resurrected;
- both deleted → no action;
- renames are detected by unique content hash and propagated as moves.

Actions are applied through the `Remote` trait. The backend adapter is not yet
implemented in a shipped client; the engine is tested against an in-memory remote.

## Metadata model

- `accounts`, `devices`, `api_tokens` — identity and scoped bearer tokens
  (SHA-256 hashes, 90-day expiry, revocable).
- `files` — namespace; `name_enc` is a client-sealed envelope bound to the node
  id. The server can order opaque bytes but cannot read names.
- `file_versions` — immutable sealed manifests, one row per revision, with
  parent revision and content size.
- `chunks`, `stripes`, `shards`, `shard_history` — article locations and health.
  Message-IDs are mutable pointers to immutable content; manifests reference
  stripes and content hashes, so repair/refresh never rewrites a manifest.
- `jobs` — durable queue with `FOR UPDATE SKIP LOCKED`, attempts and backoff.
- `sync_events` — per-account monotonic sequence, the SSE catch-up cursor.
- `providers` — NNTP configs, password encrypted with `NNTDRIVE_SECRET_KEY`.
- `folder_shares`, `share_links`, `audit_log` — schema for sharing and auditing;
  endpoints are incomplete.

## Recovery anchor

Usenet has no globally mutable pointer to "latest metadata". NNTDrive therefore
relies on an explicit anchor:

1. the **recovery kit** (+ code) held offline by the user, containing the AMK;
2. a **PostgreSQL dump** held off-host, including sealed manifests, article
   Message-IDs, provider configs and job state;
3. the `checkpoint.json` written by `scripts/backup.sh`, containing the dump hash
   and schema version.

Restoring a dump from before a deletion can resurrect logically deleted data,
because Usenet articles cannot be physically removed. That is documented rather
than hidden. Changing providers does not invalidate articles if the new provider
carries the same groups/backbone; otherwise recovery depends on old provider
access.

## Non-goals and honest limits

- Guaranteed durability or permanent Usenet retention.
- Physical deletion of posted articles.
- Server-side search over plaintext (only opaque metadata search is possible).
- Unlimited sharing without key exchange design; current sharing schema is a
  foundation, not a finished feature.
