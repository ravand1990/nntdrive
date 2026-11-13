# Running NNTDrive without cloning the repository

## 1. Download the deployment files

Download matching `docker-compose.release.yml`, `nntdrive-compose.py` and
`env.release.example` from the same [GitHub release](https://github.com/ravand1990/nntdrive/releases).
Releases from v0.7.0 include the generate-once launcher; older releases
(including v0.6.0) do not. No source checkout or local build is needed. Requires
Linux/WSL, Python 3 and Docker Compose **2.24+**.

The backend image is `ghcr.io/ravand1990/nntdrive-backend`. Pin a version in
`.env` instead of using `latest` for unattended upgrades. GHCR package visibility
is separate from repository visibility: if a pull requires authentication, use
a separate token with `read:packages` (not a client updater token):

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u ravand1990 --password-stdin
```

## 2. Configure

Optionally rename `env.release.example` to `.env`, protect it with `chmod 600
.env`, and set `NNTDRIVE_VERSION=0.10.5`. Leave `POSTGRES_PASSWORD` and
`NNTDRIVE_SECRET_KEY` empty. An absent or completely empty `.env` also works,
using the default image `latest`, loopback binding and port 8080. No manual
OpenSSL command, host SDK or local image build is needed.

On first launch, missing values are independently generated using the OS secure
random source: a 32-byte random hex database password and a 32-byte base64 provider
encryption key. Nonempty explicit values from `.env` or the process environment
are honored (environment wins, using Compose's dotenv rules); an explicit key
must decode to exactly 32 bytes. Passwords containing URL-special characters are
percent-encoded in the database connection URL, without changing the password.
`.env` is never modified. Do not put shell commands such as `$(...)` into it.

## 3. Start

```bash
python3 nntdrive-compose.py up
curl -fsS http://127.0.0.1:8080/healthz
```

`up` runs detached and waits for service health. Credentials are saved once in
`.nntdrive-secrets/secrets.json` beside the launcher (0600, directory 0700), and
reused on restart, `down`/`up`, upgrades and `--force-recreate up`. The launcher
never prints generated credentials or configuration, and suppresses raw Compose
failure diagnostics which might contain secrets. A failed pull/start retains the
same credentials for retry. Do not delete this directory to troubleshoot.

Open `http://127.0.0.1:8080/admin` and `http://127.0.0.1:8080/`. The app offers
first-time setup; alternatively bootstrap once from the CLI (see the root README
for a hidden password prompt and protected recovery-file export):

```bash
python3 nntdrive-compose.py exec backend \
  nntdrive bootstrap --email you@example.com \
  --keyfile-out /var/lib/nntdrive/bootstrap/admin.keyfile.json \
  --recovery-out /var/lib/nntdrive/bootstrap/admin.recovery.json
```

The account token and recovery code are printed once by that explicitly requested
operator command; copy the keyfile/recovery kit out with `python3
nntdrive-compose.py cp`. `exec`/`cp` are trusted operator commands with unmodified
stdin/stdout (including binary backup data), not a sandbox: do not execute secret
inspection commands or publish their output.

## Persistence and fail-closed recovery

- Back up `.nntdrive-secrets/` privately **off-host**, along with optional `.env`
  and the database backup. The provider key is not an E2EE user recovery kit.
- Do not change explicit credentials after initialization. Matching values are
  accepted; differing values fail without changing the saved file. Clearing an
  override reuses the saved value, never regenerates it.
- Empty, partial, corrupt, linked, incorrectly owned or permissively accessible
  secret storage is refused without repair or overwrite. Restore the original
  backup with directory 0700/file 0600 permissions and the invoking user's owner.
- If secrets are absent but **any** matching named volume or Compose project
  container exists, initialization refuses, even if both secrets are explicitly
  supplied. Empty existing volumes are conservatively treated as data. Restore
  the original secret backup; never delete volumes to make the check pass.
- Existing installations retain their original Compose/explicit-secret workflow.
  Automatic adoption, credential rotation and existing-install migration are not
  implemented. Do not point this launcher at an old installation without its
  original launcher-generated secret backup.

### Threat model and interrupted initialization

Use one trusted installation directory and one stable project name per deployment;
run all commands as the same user. An OS-held file lock serializes initializers in
that directory. A complete file is flushed before atomic create-only publication,
then the directory is flushed. An interruption cannot publish a partially written
secret or overwrite another file. An interruption during publication may leave a
private `.pending-*` file or a multi-link file: restore the original backup if
validation refuses it; do not regenerate over data. Unpublished pending files are
not selected as credentials. No containers are started until publication succeeds.

The guard detects the release file's fixed named volumes plus project-labeled
volumes/containers, including stopped containers. Keep the launcher/Compose files,
installation directory and project identity together. It cannot discover data
that an operator renamed, moved to another Docker context, restored into different
volumes, or hid by changing the project name. Concurrent first launches from
*different* directories using the same project name are unsupported; coordinate
operators, do not treat filesystem locks as a distributed Docker lock.

Host root, the Docker administrator and the invoking user can read these secrets
(including container environment via Docker); 0600 is not protection against host
compromise. The trusted installation directory must not be writable by another
user. This does not change cryptographic formats or the backend's non-Compose
configuration behavior.

## TLS profile

Set `NNTDRIVE_DOMAIN` in `.env` to your real domain before enabling TLS:

```bash
python3 nntdrive-compose.py --profile tls up
```

Point DNS at the host and open ports 80/443. Keep
`NNTDRIVE_HOST_BIND=127.0.0.1` so raw HTTP is not publicly reachable. With TLS
disabled, no domain setting is required.

## Lifecycle and upgrades

```bash
python3 nntdrive-compose.py restart
python3 nntdrive-compose.py down       # retains secrets AND named volumes
python3 nntdrive-compose.py up
python3 nntdrive-compose.py --force-recreate up
# Back up first, then edit NNTDRIVE_VERSION in .env:
python3 nntdrive-compose.py pull
python3 nntdrive-compose.py up
```

For a separate installation, choose `--project-name <unique-name>` on **every**
command from its own directory; never change it for an initialized installation.
The helper deliberately does not expose `down -v`, `config`, arbitrary Compose
files or project-changing passthrough options. Direct Compose commands do not
load generated secrets: use the helper consistently.

## Backups

Database migrations run automatically at startup. Back up before upgrading:

```bash
python3 nntdrive-compose.py exec -T postgres \
  pg_dump -U nntdrive -d nntdrive -Fc > nntdrive-$(date -u +%Y%m%d).dump
```

The PostgreSQL volume, secret directory and user recovery kit/code are recovery
anchors. Store backups off-host and keep the recovery code separately. See
`docs/DISASTER_RECOVERY.md` in the repository. The encrypted shard cache is
disposable; it is not a database or secrets backup.

The image contains the backend and `nntdrive` CLI. Add providers in `/admin` or
set initial `NNTDRIVE_NNTP_PROVIDERS`; successful admin provider changes apply
without restart. Do not use `:latest` for unattended production upgrades.
