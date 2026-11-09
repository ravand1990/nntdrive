# Bounded guarded encrypted file/folder Copy (#51)

The Rust SDK `ApiClient::copy_file_checked` and dedicated
`POST /api/v1/files/{source}/copy-checked` publish **one current file** atomically.
`ApiClient::copy_folder_checked` publishes a bounded recursive folder subtree in
one separate tree transaction. Flutter/FFI/UI exposes both file and folder Copy;
no sequence of single-file requests is presented as an atomic folder copy.
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

## Recursive folder protocol

`GET /api/v1/files/{source}/copy-tree-snapshot` returns the complete live subtree
in one tenant-scoped recursive query. It fails rather than truncating beyond
256 nodes (including the root) or depth 31 (root depth 0). Each opaque snapshot
entry contains `id`, `parent_id`, `name_enc`, `is_dir`, `current_version`, `size`.
Deleted nodes/subtrees and historical versions are not copied. Source history is
retained unchanged. `GET /api/v1/copy-tree-destination?parent_id=…` (omit for root)
returns bounded opaque destination `files` entries (`id`, `name_enc`). It rejects
foreign/absent parents identically and never returns a truncated collision guard.

The SDK authenticates **all** subtree names, validates portable components and
parent connectivity, rejects canonical collisions among every sibling group,
and freshly checks the destination. It authenticates each current file manifest
using the existing file preparation machinery. Every node gets a fresh ID and
sealed name; files also get fresh revision IDs and resealed manifests. Folders,
including empty folders, have no manifest/revision. No content is downloaded or
reposted: the same v1 account-scoped immutable chunk references are retained.

`POST /api/v1/files/{source}/copy-tree-checked` contains `source` (the complete
subtree snapshot), `parent_id`, complete destination `siblings`, and `nodes`
candidates (`source_id`, fresh `id`, `name_enc`, nullable `revision_id` and
`sealed_manifest`, explicit `chunk_ids`). The backend computes destination
parents from the old-to-new ID mapping; request ordering/parent mappings are not
trusted. Under GC/advisory **then** account namespace locks, it compares the
**exact** live subtree (including revisions/sizes) and destination snapshots,
rejects a destination within the source, validates tenant ownership and unused
identities, then inserts all nodes, complete references and normal create/version
sync events in one transaction. A late reference failure rolls back earlier
parents, versions and events. Success is 201 with the fresh root `id`. There is
no staging visibility, sequential create fallback or automatic retry.

Bounds: 256 source/candidate nodes; depth 31; 4096 destination siblings with at
most 2 MiB decoded name bytes; 8192-byte names; 1 MiB per sealed manifest;
8 MiB aggregate candidate name/manifest bytes; 4096 chunk declarations per file
and 16384 per tree; the file protocol's nonnegative 16 TiB size bound; 12 MiB
encoded publication body. Reads use SQL row/depth/envelope bounds. Client HTTP
bodies are streamed with caps (3 MiB subtree, 4 MiB destination, 1 MiB manifest,
1 KiB acknowledgement); the whole SDK attempt times out after 120 seconds.
Publication has 5-second lock and 15-second per-statement timeouts. Timeout or
connection loss remains ambiguous: refresh before another explicit attempt.
Limits may reject a tree before another individual bound is reached. Exceeding
limits never falls back to publishing a subset.

## Flutter/FFI contract

The row's **Copy file / Copy folder** action opens the encrypted folder picker, disables the
current folder (the unchanged name would collide), and asks for explicit **Copy**
confirmation. Files retain their exact decrypted source spelling; a collision
requires cancellation and choosing another folder or renaming the source first.
Folder confirmation explains the atomic subtree and its resource bounds. The
picker excludes the source folder, and both SDK and backend reject descendants.

`nntdrive_copy_file(handle, request_json)` accepts the opaque source listing
snapshot, destination ID, URL and token, and returns one owned JSON string with
new `id` and `revision_id` (null for a folder). A separate top-level Dart `Isolate.run` helper invokes
and frees it off the UI isolate; no callback is retained. The unlocked handle is
checked before HTTP, ABI requests are bounded to 32 KiB, and folder sources
dispatch to the recursive SDK protocol. SDK/backend crypto/tenant/namespace
guards remain authoritative.
A missing additive export fails safely; bundle Dart and native core together.

The confirmation dialog admits one attempt only, blocks dismissal while running,
and offers **Refresh**, not retry, after success or failure. Native errors are
fixed secret-free messages; the UI never displays server/native diagnostics.
A refresh updates the current browser; inspect the chosen destination before a
new attempt. Refresh does not prove an ambiguous request failed or succeeded.

## Verification and remaining scope

Real SDK/HTTP/PostgreSQL/mock-NNTP regression covers encrypted Copy download,
independent source edits/deletion, retained references and GC, exact and Unicode
canonical collisions, stale namespace/source guards, rejected identities and
reference sets, tenant opacity, transaction rollback and actual lock exclusion.
Local crypto tests cover wrong keys, tampering, malformed identity/structure,
empty content and repeated fresh preparation. A sabotage run weakens the
snapshot check and must fail the HTTP regression before restoring production.

The separate `file_copy_native_test.dart` loopback fixture uses real native
upload of empty content to obtain an authenticated source manifest, invokes the
worker-isolate Copy ABI, checks fresh IDs/envelopes and complete opaque guards,
and downloads/decrypts the copied manifest. It rejects canonical collisions,
unreadable siblings, corrupt manifests and wrong/locked keys; HTTP
404/409/500 and disconnect-before-acknowledgement each produce exactly one
request and secret-free failure. Missing revisions and substituted source-name
identities reject before HTTP. This is
not a second backend tenant test: those remain in the real PostgreSQL suite.
Widget tests separately cover destination/root/cancel selection, explicit
confirmation, duplicate admission, success and ambiguous failure without retry.
Removing the SDK source-name collision check makes this new native HTTP
regression fail (unexpected successful Copy); production guard is restored.

Recursive SDK/real HTTP/PostgreSQL/mock-NNTP tests cover nested and empty
folders/files, fresh metadata identities, parent remapping, independent source
edits, source-history preservation and download after test-only physical source
history removal plus actual GC. They reject actual added/deleted/renamed/moved
or newly committed descendants, stale destination membership, foreign/absent
sources/destinations, foreign/missing references, reused IDs, over-depth/wide
trees and oversized bodies/candidates. Late reference errors leave no nodes or
events; separate lock owners block publication. Weakening exact subtree equality
to subset matching made the added-descendant regression fail (201, expected 409);
production equality was restored before the complete suite.

`folder_copy_native_test.dart` exercises the actual worker-isolate ABI with a
nested/empty folder fixture and real native uploaded empty-file manifest. It
opens every resealed name, downloads the fresh child manifest, checks the one
complete publication body, and rejects internal collisions/unreadable names,
descendant destinations, wrong/locked keys and one-attempt HTTP/disconnect
failures. Widget coverage enables folder Copy and explains bounds before explicit
confirmation; this is not an installed-app test.

Remaining: copy-time new-name selection; durable retry receipts;
installed Windows/Linux and two-device acceptance; exhaustive disconnect/GC race
scheduling and cross-platform filesystem acceptance. These are not implied by
these bounded protocols. No production/deploy/release changes.
