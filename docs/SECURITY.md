# Security and threat model

## Guarantees

- File contents, filenames, directory structure and manifests are encrypted on
  the client before leaving it. The backend stores and moves ciphertext only.
- Every chunk, name and manifest is authenticated with XChaCha20-Poly1305. A
  modified, truncated or substituted ciphertext fails closed.
- Manifests pin each shard's SHA-256, so a backend that swaps articles is
  detected before reconstruction.
- The server authenticates users with an Argon2id verifier derived from the
  password under a separate domain/salt. It never receives the password or the
  account master key.
- Device enrollment wraps the AMK with X25519 ECDH + HKDF. Device secrets belong
  in the platform keystore; the CLI uses a 0600 keyfile.
- No key material is logged. `SecretKey`, `MasterKey` and `FileKey` implement
  redacted `Debug`; secrets are zeroized where the types allow it.

## Threat model

| Threat | Mitigation | Residual risk |
|---|---|---|
| Malicious client / unauthorized API user | Bearer tokens hashed at rest; every query is scoped by `account_id`; tenant isolation tests; input validation; quotas; rate limit on auth | A stolen token grants access until expiry/revocation. Bind tokens to devices and revoke on loss. |
| Compromised backend server | It only holds ciphertext, sealed names/manifests, metadata, and wrapped provider passwords. It cannot derive the AMK. | It can delete or withhold data (availability), correlate sizes/timings, and see who accesses what. It can also use provider credentials to post/retrieve ciphertext. |
| Compromised provider credentials | Encrypted at rest with `NNTDRIVE_SECRET_KEY`; admin endpoints never return passwords. | A host compromise also exposes the env secret. Rotate provider credentials and rotate `NNTDRIVE_SECRET_KEY` by re-entering providers. |
| Metadata tampering | Sealed manifests are authenticated and bound to file/revision ids; shard hashes pinned; account scoping; DB constraint checks. | A compromised DB can hide revisions or point at existing articles. Clients detect content substitution, not omission/rollback. |
| Replay / old version substitution | Manifests bind revision ids; clients compare revision ancestry. | A malicious backend can serve an older valid revision. Clients can keep local version history; server-side rollback protection is not cryptographic without a trusted external log. |
| Lost encryption keys / password | Recovery kit wraps the AMK with a 256-bit code via Argon2id; documented offline storage. | Without the kit or password, data is unrecoverable. The server cannot reset E2EE keys. |
| Removed device | Device token revoked; users must rotate the AMK epoch and re-wrap it for remaining devices. New content uses new keys. | Content previously readable by the device remains readable to it. This is inherent to content-addressed immutable storage. |
| Malicious filesystem input (sync) | Relative path validation, `..`/absolute/reserved-name rejection, symlinks not followed by default, case-collision detection, atomic writes. | Path traversal bugs remain a review focus; FUSE/WinFsp integrations are not implemented yet. |
| Traffic interception | TLS to provider, reverse-proxy TLS for clients; HSTS via Caddy. | Self-hosted deployments can accidentally expose HTTP. Bind to loopback or use the TLS profile. |
| Password brute force | Argon2id 64 MiB/t=3 for key derivation and verifier; per-IP auth rate limit; 90-day tokens. | No account lockout/2FA yet. Put a hardened proxy limiter in front for internet exposure. |
| Provider retention loss | Health checks, repair, proactive refresh with read-back verification, honest unrecoverable status. | Erasure coding cannot recover data when more than `m` shards in a stripe are gone. Correlated batch loss can exceed this. |
| Article content analysis | Random nonces; no deterministic encryption; opaque subjects; per-account dedupe only. | Sizes, timing, article counts and provider logs leak metadata. |

## Cryptographic choices

| Purpose | Primitive |
|---|---|
| Content encryption | XChaCha20-Poly1305 (RustCrypto) |
| Password / recovery KDF | Argon2id v1.3, 64 MiB, t=3, p=1 |
| Key separation | HKDF-SHA256, length-prefixed domain strings |
| Content hash / chunk id | BLAKE3 |
| Shard integrity | SHA-256 |
| Device key agreement | X25519 (dalek) + HKDF-SHA256 |
| Token storage | SHA-256 of a 256-bit random bearer token |
| Provider secret at rest | XChaCha20-Poly1305 with `NNTDRIVE_SECRET_KEY` |

No algorithm is implemented by this project.

## Key management procedures

- **Create**: password → keyfile; recovery kit + code exported and stored
  offline (not on the backend host, not in the same backup).
- **New device**: existing device wraps the AMK to the new device's X25519 public
  key. Enrollment is authenticated by the account token; current release has no
  separate approval UI.
- **Lose a device**: revoke its token/device in the API or admin UI, generate a
  new AMK epoch, wrap it for remaining devices, and re-encrypt new content.
  NNTDrive exposes the instruction but does not automate epoch rotation yet.
- **Password change**: re-wrap the AMK under a new password/salt; the old keyfile
  is invalidated client-side.
- **Recovery**: restore the keyfile from the kit + code, or rebuild a keyfile
  with `nntdrive recovery-restore`. Then restore the database backup.

## Logging and data handling

- Structured logs contain IDs, counts, timings and error classes; never tokens,
  passwords, verifier values, article bodies, names, or keys.
- The article cache stores ciphertext only and is disposable.
- Backup dumps contain ciphertext and metadata, plus provider passwords
  encrypted with `NNTDRIVE_SECRET_KEY`. Treat them as sensitive.

## Deployment hardening checklist

- Set a strong `POSTGRES_PASSWORD` and `NNTDRIVE_SECRET_KEY`; keep `deploy/.env`
  out of version control (already ignored).
- Keep `NNTDRIVE_ALLOW_REGISTRATION=false` unless onboarding.
- Put the backend behind a TLS reverse proxy; expose only 80/443.
- Restrict the admin UI to trusted networks or add SSO/reverse-proxy auth.
- Run backups off-host and verify restores regularly.
- Monitor failed jobs, missing/corrupt shard counts and unrecoverable stripes.
- Rotate tokens/devices on personnel or laptop loss.

## Known gaps (tracked, not hidden)

- No PAKE (OPAQUE/SRP): the verifier is password-equivalent over TLS. A
  compromised TLS endpoint could replay it to the backend.
- No server-side rollback protection for manifests.
- Device removal does not automatically rotate the AMK epoch in this release.
- Sharing/link endpoints are incomplete; do not advertise secure sharing yet.
- No security audit has been performed. Treat this as alpha software.
