# Architecture decisions

Short records of decisions that would be expensive to reverse.

## ADR-001: PostgreSQL is the only metadata store

All storage metadata, jobs, identity and versions live in PostgreSQL. Tests create
an isolated schema per test and run the real migrations; there is no in-memory
production path. This costs a database dependency in tests but guarantees the
schema and queries under test are the ones deployed. The client journal is the one
exception (SQLite) because it is local device state.

## ADR-002: Account-scoped chunk keys and ciphertext reuse, not convergent encryption

Unchanged chunks must not be retransmitted, but deterministic encryption leaks
equality. Chunk keys are derived as `HKDF(AMK, plaintext_hash)` and nonces are
random; deduplication is a metadata lookup within one account, and the existing
ciphertext is referenced again. No server-visible hash, no cross-account
dedupe, no plaintext-derived ciphertext.

## ADR-003: Immutable manifests, mutable article locations

Manifests are sealed by the client and never rewritten. Repair and retention
refresh must move Message-IDs; therefore manifests reference stripe IDs and
content hashes, while `shards.message_id` is the mutable pointer. `shard_history`
records every replacement. Clients verify shard hashes from the sealed manifest,
so a tampered pointer is detected.

## ADR-004: The backend accepts ciphertext only

The upload API receives already compressed+encrypted chunk bytes and a client
chunk id. The backend erasure-codes and posts them. A previous internal design
ran encryption in the backend; that was rejected because it broke E2EE and put
the AMK on the server. `nntdrive-storage::prepare_chunk` is client-side;
`Storage::publish_prepared` is the server-safe path.

## ADR-005: Conflicts preserve both versions; never last-write-wins

A pure three-way reconcile compares revisions and content hashes. Concurrent
different edits create a conflict copy and upload it, while the remote revision
takes the original path. Deletes never destroy modified content: delete-vs-modify
restores or resurrects. This favors storage cost over data loss.

## ADR-006: Separate password verifier domain instead of PAKE

The client derives an Argon2id verifier with a salt derived from the account id
and a domain-separated label; the server stores an Argon2id hash of that
verifier. The server never sees the password and cannot derive the AMK. A PAKE
(OPAQUE) would be stronger against TLS-endpoint compromise; it is deferred and
documented as a gap.

## ADR-007: Logical deletion is not physical deletion

Usenet articles cannot be reliably deleted. Deleting a file removes it from the
namespace and current versions (tombstones), and eventually from local indexes,
but previously posted articles may remain retrievable by Message-ID. UI and docs
must never promise physical erasure. This is fundamental to the medium.

## ADR-008: Durable jobs in PostgreSQL, not an in-memory queue

Health, repair and refresh jobs are rows claimed with `FOR UPDATE SKIP LOCKED`.
They survive restarts, support backoff and multiple workers. Jobs are designed to
be idempotent (STAT, reconstruct, verify, swap). This avoids losing repair state
during a crash — the worst time to lose it.

## ADR-009: Retention is a hint, not a guarantee

Provider retention is stored only as an optional hint. Refreshes use a configurable
safety margin and verify every repost. The system reports unrecoverable stripes
rather than assuming redundancy or retention. Multiple Usenet brands may share a
backbone, so brand count is not treated as independent redundancy.

## ADR-010: One erasure stripe per chunk slice, bounded article size

Chunks are content-defined (≤4 MiB by default), shards are 512 KiB, and articles
carry one shard each. This keeps article size under provider limits, allows
parallel posting, and makes repair granular without rewriting large objects.

## ADR-011: No provider-specific protocol shortcuts

Only standard NNTP (RFC 3977-ish) commands, yEnc and NZB are used. Provider
priority, posting/retrieval roles and retries are generic, so new providers are
configuration rather than code. Eweka is the reference provider.

## ADR-012: Failed verification fails the upload

The upload commits a chunk only after `k + 1` shards (capped at all shards) are
verified. If a provider claims success but articles are not retrievable, the
upload fails instead of creating a version that cannot be downloaded. Orphaned
articles are acceptable; a broken committed version is not.
