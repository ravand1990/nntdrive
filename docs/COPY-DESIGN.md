# Bounded guarded encrypted file Copy (#51)

The Rust SDK `ApiClient::copy_file_checked` and dedicated
`POST /api/v1/files/{source}/copy-checked` publish **one current file** atomically.
Copy is not exposed through Flutter/FFI or the UI. Folder Copy is unsupported.
There is no legacy create/commit fallback.

## Client contract

The client authenticates source name and manifest AAD and embedded identities,
validates manifest structure, generates fresh node/revision IDs, and re-encrypts
metadata with fresh nonces. Size, content hash and immutable chunk references
remain unchanged. Wrong keys, tampering and malformed metadata fail closed.
Destination names are freshly decrypted, validated as portable components and
compared using NFC/lowercase/NFC. Unreadable, duplicate or colliding names reject
the operation. Exact spelling is retained in encryption; comparison keys and
plaintext never go on the wire. Same-folder Copy intentionally collides; this
slice does not provide a new-name picker.

Current v1 storage uses account-scoped content-derived chunk keys (ADR-002),
not `MasterKey::file_key`. Reusing immutable chunks within the same account/key
scope is the normal deduplication model. New IDs separate metadata identity,
not content revocation domains. This is not cross-account sharing, independently
revocable content encryption, or a provider-durability guarantee.

## Publication protocol

The ciphertext-only request contains `source_revision`, `source_parent_id`,
`source_name_enc`, destination `parent_id`, complete opaque `siblings` entries
(`id`, `name_enc`), fresh `id` and `revision_id`, `name_enc`, `sealed_manifest`,
`size`, and explicit `chunk_ids`. Success is 201 with both new IDs.

One PostgreSQL transaction acquires the account GC/version advisory lock before
the account namespace row lock. All namespace writers use that order (event
publication also takes the advisory lock). It checks the live non-directory
source's parent, sealed name, current revision and size, destination ownership
and folder type, and exact complete sibling snapshot. Source commits serialize
under the GC lock. The transaction rejects reused identities, validates every
chunk's tenant ownership, inserts a complete reference index with the new
node/version and emits a normal `version` sync event before commit. No partial
node or dangling reference is published on failure. Historical/tombstoned source
versions remain untouched. Shared chunks incur no additional physical quota.
No migration or encrypted format change is needed.

Bounds: 2 MiB HTTP body, 4096 destination entries and chunk declarations,
8192-byte sealed names, 1 MiB sealed manifest, nonnegative size up to 16 TiB.
Oversized destination reads cannot match a bounded guard. An absent/foreign
source or destination is opaque (404); stale source/snapshot and reused IDs
conflict (409). Invalid envelopes/references reject (400). Errors carry no keys
or decrypted metadata. The backend cannot verify a plaintext collision or
opaque manifest semantics; those remain authenticated-client obligations.

There is deliberately **no automatic retry**. A stale guard requires fresh
listing/decryption. A lost response may have committed: refresh the destination
before initiating a new copy, rather than blindly retrying with new IDs. This
slice does not promise idempotent replay or durable operation receipts.
Legacy writers can still introduce duplicate names after guarded publication;
mixed-version backends/direct DB namespace writers do not honor new app locks.

## Verification and remaining scope

Real SDK/HTTP/PostgreSQL/mock-NNTP regression covers encrypted Copy download,
independent source edits/deletion, retained references and GC, exact and Unicode
canonical collisions, stale namespace/source guards, rejected identities and
reference sets, tenant opacity, transaction rollback and actual lock exclusion.
Local crypto tests cover wrong keys, tampering, malformed identity/structure,
empty content and repeated fresh preparation. A sabotage run weakens the
snapshot check and must fail the HTTP regression before restoring production.

Remaining: recursive folder traversal/staging/remapped parents with atomic tree
publication; Flutter/FFI/UI destination/new-name selection; durable retry receipts;
installed Windows/Linux and two-device acceptance; exhaustive disconnect/GC race
scheduling and cross-platform filesystem acceptance. These are not implied by
this bounded file protocol slice. No production/deploy/release changes.
