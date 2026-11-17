Container image: `ghcr.io/ravand1990/nntdrive-backend:0.27.8` (linux/amd64)

Client builds: `nntdrive-0.27.8-linux-x64.tar.gz`, `nntdrive-0.27.8-android.apk` and `nntdrive-0.27.8-windows-x64.zip`.
Checking for updates in the Windows/Linux clients uses this release feed; Android clients use the same feed and hand the verified APK to the system installer; iOS is not built yet.

## Changes


### Bug fixes

- **Not synced** keeps current conflicts visible despite historical sync errors. Rename/move rows check both exact endpoints for errors and case collisions, preserve the destination, and describe failures as evidence from the last completed attempt rather than current transfer state (#79).
