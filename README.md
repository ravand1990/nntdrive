# NNTDrive

NNTDrive is a self-hosted cloud drive: keep folders in sync across your devices,
browse files, and upload or download them with a Windows, Linux or Android app.
Files and names are encrypted on your device before being stored on **Usenet**
(a separate service you subscribe to). You run the server that keeps track of them.

## Installation

### 1. What you need

- A Linux x64 server (or WSL) with Docker Engine, Docker Compose **2.24+**,
  `curl` and Python 3. No source checkout or Rust/Flutter installation is needed.
- A Usenet subscription that allows **posting and reading**, with its server
  address, port, username and password. A download-only plan is not enough.
- A Windows x64, Linux x64 or Android device. iOS is not available yet.
- For access from other devices: a domain pointing to your server and HTTPS
  (an encrypted connection). See the [HTTPS setup](deploy/README-IMAGES.md#tls-profile)
  before entering account details remotely; the default address below is local only.

### 2. Download and configure the server

In a terminal on the server, create an empty installation directory and download
the deployment files from the latest release. The generate-once launcher ships
with releases from v0.7.0; do not mix it with older Compose files.

```bash
mkdir nntdrive && cd nntdrive
curl -fLO https://github.com/ravand1990/nntdrive/releases/download/v0.8.8/docker-compose.release.yml
curl -fLO https://github.com/ravand1990/nntdrive/releases/download/v0.8.8/nntdrive-compose.py
curl -fL https://github.com/ravand1990/nntdrive/releases/download/v0.8.8/env.release.example -o .env
chmod 600 .env
```

Edit `.env` to pin `NNTDRIVE_VERSION=0.8.8`; leave both secret fields empty.
Keep `NNTDRIVE_HOST_BIND=127.0.0.1`. An absent or completely empty `.env` also
works (using the image's `latest` tag). The launcher generates missing secrets
once in `.nntdrive-secrets/secrets.json` (0600, directory 0700), not in `.env`.
Back up this directory privately and keep it across restarts, `down`/`up` and
container recreation. Never delete it to retry a failed start. Explicit nonempty
secret values are adopted on first boot; later conflicting values are refused,
not rotated. If image downloads require a login, follow the
[image access instructions](deploy/README-IMAGES.md#1-download-the-deployment-files).

### 3. Start and check the server

```bash
python3 nntdrive-compose.py up
curl -fsS http://127.0.0.1:8080/healthz
```

Wait for startup, then retry the health check if needed; it should succeed
without an HTTP error. If it fails, use the [troubleshooting guide](docs/OPERATIONS.md#troubleshooting).
For a remote server, complete the HTTPS setup above before connecting the app.

### 4. Create the first account and save recovery material

Run this **once on the trusted server**, before registering in the app. In Bash,
replace `you@example.com` with your email. The password prompt is hidden; use a
strong password of at least eight characters and save it in your password manager.

```bash
IFS= read -r -s -p 'New account password: ' NNTDRIVE_PASSWORD; printf '\n'
export NNTDRIVE_PASSWORD
python3 nntdrive-compose.py exec -e NNTDRIVE_PASSWORD backend \
  nntdrive bootstrap --email you@example.com \
  --keyfile-out /var/lib/nntdrive/bootstrap/admin.keyfile.json \
  --recovery-out /var/lib/nntdrive/bootstrap/admin.recovery.json
unset NNTDRIVE_PASSWORD
mkdir -m 700 recovery
python3 nntdrive-compose.py cp backend:/var/lib/nntdrive/bootstrap/. ./recovery/
chmod 600 recovery/*
```

**Save the printed recovery code offline and keep the admin token private.**
Both are shown only once. Copy the two JSON files in `recovery/` to protected
offline storage, keeping the recovery code separately. The admin token is the
dashboard login, not your account password. Also keep off-host database backups:
[backup and recovery checklist](docs/DISASTER_RECOVERY.md#assets-you-must-protect).
The server cannot decrypt your files or reset lost encryption keys.

If you already used the app's **First-time setup**, do **not** run bootstrap:
it refuses servers with existing accounts. That dialog saves the recovery code,
but does not export a kit/keyfile; arrange a separate recovery backup before
uploading important data. [Account setup alternatives](docs/OPERATIONS.md#first-account-and-admin-token).

### 5. Install and connect the client

Download your client and `SHA256SUMS.txt` from the same
[release page](https://github.com/ravand1990/nntdrive/releases/tag/v0.8.8).
Compare the download's SHA-256 checksum (its file fingerprint) with the matching
entry in that file before opening it (`sha256sum FILE` on Linux or
`Get-FileHash FILE -Algorithm SHA256` in PowerShell).

| Device | Release file | Install / open |
|---|---|---|
| Windows x64 | `nntdrive-<version>-windows-x64.zip` (for example `nntdrive-0.8.8-windows-x64.zip`) | Extract the **whole** ZIP to a writable folder; run `nntdrive.exe` inside it. Keep the DLLs and other files alongside it. There is no signed installer yet. |
| Linux x64 | `nntdrive-<version>-linux-x64.tar.gz` | Extract the **whole** archive; run `./nntdrive` from the extracted bundle. Keep its `lib` and `data` directories. |
| Android | `nntdrive-<version>-android.apk` | Open the APK and allow installation from that source in Android settings. This test build is debug-signed, not a Play Store release. |

In the app, enter your server's HTTPS URL (or `http://127.0.0.1:8080` **only if
running on the server itself**). On a phone, `127.0.0.1` means the phone, not your
server. Sign in with the email and password from step 4; unlock again after
restarting. On other devices, use the same server, email and password.

### 6. Connect your Usenet provider

Open your server URL with `/admin` added (locally,
`http://127.0.0.1:8080/admin`) and paste the admin token. Under **Usenet providers**,
add the provider details from your subscription, including posting/reading roles
and a supported group. Use **Test**, then **Maintenance → Restart backend** to
apply changes; wait for the health check to succeed again. Some subscriptions
use separate posting and reading servers: see [provider setup](docs/OPERATIONS.md#nntp-providers).
The test checks connection/login; try a small upload and download to verify posting.

## Usage

1. **Upload or download a file:** in the app's file browser, use **Upload a file**.
   Select a file's **Download and verify** action to save a checked local copy;
   version history offers earlier versions. Start with a disposable test file.
2. **Sync a folder:** open the sync icon, choose **Select base folder** and a
   folder on this device, then **Sync this folder**. Use **Add another folder**
   for additional folders, **Sync all now** or per-folder
   **Sync now**. Changes flow both ways; automatic runs happen every five minutes
   while the app is open. See the [folder walkthrough](docs/CLIENTS.md#folder-sync-walkthrough).
3. **Understand local and cloud copies:** “cloud-only” means a remote file has
   no local copy in the folder you are syncing; “local-only” means it has not
   been uploaded yet. Download or sync to bring copies together. These describe
   where copies exist, not an implemented on-demand virtual drive or pin/unpin
   feature. Selective sync excludes subfolders without deleting existing copies.
4. **Read progress and handle conflicts:** wait for completion, not just full
   byte progress (verification may still be running). If two devices edit the
   same file, open the conflict review, inspect both paths, then choose **Keep
   mine**, **Keep theirs** or **Keep both**. Recovery copies are preserved; do not
   delete them until you have checked the result. [Conflict details](docs/CLIENTS.md#sync-model-on-clients).
5. **Update:** Windows/Linux check GitHub releases at startup and daily; use
   **Account → Check for updates** manually. Installed-app replacement/restart
   verification is still incomplete, so keep backups and use the release archives
   if needed. Android updates are APK installs from the release page, not the
   desktop updater. Server upgrades are separate: [back up, then upgrade](deploy/README-IMAGES.md#upgrades).

**Keep the app open and unlocked for sync.** Closing it stops sync; desktop
background service/autostart and Android background scheduling are unfinished.
Synced local files are readable on that device; use device disk encryption.

**Keep independent backups.** Usenet retention and repair cannot guarantee that
files remain recoverable, and already-posted articles cannot reliably be deleted.
NNTDrive has not had an independent security audit.

## Guides

[Verified status and limitations](docs/STATUS.md) ·
[Client platforms and updates](docs/CLIENTS.md) ·
[Server installation and HTTPS](deploy/README-IMAGES.md) ·
[Administration and backups](docs/OPERATIONS.md) ·
[Disaster recovery](docs/DISASTER_RECOVERY.md) ·
[Security](docs/SECURITY.md) · [Architecture](docs/ARCHITECTURE.md) ·
[API](docs/API.md) · [Development](docs/DEVELOPMENT.md) ·
[Isolated container checks](docs/CONTAINER-DEVELOPMENT.md) ·
[CI coverage](docs/CI.md) · [Changelog](CHANGELOG.md)

## License

[AGPL-3.0-or-later](LICENSE).
