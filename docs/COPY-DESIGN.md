# Copy preparation and remaining transaction work (#51)

Copy is **not exposed in the client UI or implemented as a server operation**.
The bounded SDK primitive `copy::prepare_file_copy` only authenticates source
metadata and prepares new ciphertext locally. It performs no HTTP or disk I/O.

## Implemented preparation contract

- Open the source name and manifest under the supplied master key and expected
  source node/revision AAD; validate manifest structure and embedded identity.
- Generate fresh file and revision IDs. Re-encrypt the exact source name and a
  new manifest bound to these IDs with fresh authenticated-encryption nonces.
- Preserve size, content hash and immutable chunk/stripe references. Do not
  mutate source ciphertext or export any key. Return no plaintext metadata.
- Wrong account keys, tampering, malformed manifests and identity substitutions
  fail before a candidate is returned. Errors do not include decrypted data.

Current v1 storage uses account-scoped content-derived chunk keys (ADR-002),
not `MasterKey::file_key`. New node IDs derive distinct per-file keys, but
claiming that v1 content is encrypted with these keys would be incorrect.
Immutable chunks can be safely shared within the same account/key scope just
as normal uploads already deduplicate identical bytes; future edits publish
new immutable revisions, never rewrite shared chunks. Names/manifests are
re-encrypted, not copied byte-for-byte. This is not independent revocation or
cross-account sharing. A requirement for independent *content* encryption
keys would require a separately reviewed versioned format/migration design.

The primitive does not download/reverify chunk bytes or provider durability;
its tests establish authenticated metadata preparation, not a complete copy.

## Required before enabling Copy

1. Dedicated tenant-scoped guarded publication endpoint, no legacy fallback.
   In one transaction under the existing account namespace lock, validate the
   source identity/current revision/parent/name, destination ownership/type,
   complete opaque sibling snapshot and all referenced chunk ownership, then
   insert the fresh node/version/reference index and sync event atomically.
   Reuse the GC/version-commit lock protocol; no dangling references or legacy
   incomplete-reference commits. Reject reused node/revision IDs. Keep errors
   opaque across tenants. Never accept plaintext collision tags or keys.
2. Client locally decrypts/validates destination names and portable canonical
   collision rules; collisions require rename/cancel. A stale guard requires
   refresh, not blind retry. The primitive is not that collision policy.
3. Folder copy needs a bounded traversal/staging/publication protocol with fresh
   IDs and remapped parents, fail-closed unreadable/colliding descendants, cycle
   and source-into-descendant policy, interruption/retry and no partial visible
   tree. Do not compose unguarded create/commit requests and call it atomic.
4. Real PostgreSQL + HTTP + mock-NNTP tests for independent edits/deletion and
   source preservation, tenant opacity, destination races/collisions, commit/GC
   races, interrupted and ambiguous responses, then native/UI wiring and
   installed Windows/Linux/two-device acceptance.

This slice changes no encrypted format, server API, database or FFI ABI. It
intentionally leaves publication and folder copy unimplemented rather than
shipping a non-atomic or cross-tenant shortcut.
