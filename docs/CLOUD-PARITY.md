# Cloud storage parity review

Checked **2026-11-23** against NNTDrive **v0.35.0** (`e079d15`) and the
first-party pages linked below. This is the dated analysis for
[issue #88](https://github.com/ravand1990/nntdrive/issues/88), not a second backlog.
Issues own implementation scope and the Project owns scheduling.

## Method and limits

Compare documented capabilities, not product quality, benchmark speed, prices,
quotas or regional availability. Vendor cells name the relevant mode or
platform; they do not promise every plan, device or encrypted-folder mode has
that feature. Recovery windows and preview limits differ by plan and format.
**Not assessed** means no conclusion, not absence. No vendor account or installed
NNTDrive client was exercised in this review.

NNTDrive evidence is [STATUS.md](STATUS.md), [CLIENTS.md](CLIENTS.md),
[SECURITY.md](SECURITY.md), the [changelog](../CHANGELOG.md) and the live linked
issues. Implemented means integrated code with the narrower automated evidence
recorded there, not installed-device acceptance. All vendor references were read
on the check date; they can change independently of this snapshot.

## Evidence-backed comparison

| Capability | Google Drive | Dropbox | OneDrive | iCloud Drive | NNTDrive v0.35.0 |
|---|---|---|---|---|---|
| On-demand access and offline pinning | Desktop streaming plus explicit offline availability [G1] | Online-only placeholders and available-offline files [D1] | Windows Files On-Demand and Always keep on this device [M1] | Windows downloaded-file/folder pins [A1] | In-app revision download cache, pins, eviction, configurable limit and device free space (#82/#199). **No OS placeholders** (#14). |
| Desktop file-manager integration | Finder/Explorer access through Drive for desktop [G1] | Explorer/Finder online-only context actions and sync icons [D1] | Explorer status icons and context actions [M1] | Explorer pin status/actions; Finder/Files access [A1, A4] | Confined Show folder from the app (#51); **no shell overlays/context-menu extension** (#86). |
| Account-wide search | Name/content terms and filter chips; no quality ranking claimed [G2] | Name/extension/type/content search; content capabilities depend on plan [D2] | Website Search everything; names, descriptions and tags [M2] | Device-provided filename/folder/type search on iCloud.com with supported OS and Allow Search [A2] | Authenticated decrypted-name RAM snapshot across folders, filters and ranked results (#80); not full-text content search. Offline reuse requires an existing unlocked-session snapshot; refresh-time status can be stale (#93). |
| Per-file version history | File versions; Google editor history is a separate mechanism [G3] | Version history with plan-dependent window [D3] | Restore previous versions across file types [M3] | General arbitrary-file version history not assessed; deleted-file recovery is separate [A3] | Immutable content revisions, download and confirmed pointer restore (#81); newest 200 versions shown. Actual content retrieval still depends on surviving storage shards. |
| Deleted-file recovery and bulk rollback | Trash restore [G4]; bulk Restore file versions is documented as beta, not a full namespace rewind [G5] | Deleted-file/version recovery and Rewind; eligible plans, not the mobile app [D3, D4] | Recycle-bin recovery; entire-OneDrive restore requires Microsoft 365 for personal accounts [M2, M4] | Recently Deleted/Recover All within the documented window [A3]; full namespace rewind not assessed | Trash/subtree restore, expiry/purge and previewed batched content-pointer rewind (#81). **Not equivalent to namespace time travel**: rewind does not undo moves/names, resurrect deleted metadata or delete files created after the date (#138). |
| In-app previews | Images, PDF, Office, audio/video through web viewer [G6] | Broad format/size-specific preview support; encrypted files require download [D5] | Broad documented previews/thumbnails, with codec/size limits [M5] | Web preview via Space bar [A2]; exact format breadth not assessed | Images plus selectable plain text/Markdown/CSV/JSON/YAML; pinned-copy reuse, bounded reads and scratch cleanup. **PDF, audio/video, thumbnails and lazy pages remain #83**. |
| Web file access | Drive web viewer [G6] | dropbox.com file/search access [D1, D2] | OneDrive website search/recovery [M2, M4] | iCloud.com Drive [A2, A4]; ADP web access requires trusted-device authorization [A5] | **No end-user web file browser**. Deliberately deferred pending a separate E2EE browser/WASM design; the admin dashboard is not a decrypted file browser. |
| Content-encryption trust model | Default transit/at-rest encryption; optional administrator-enabled Workspace client-side encryption, not a default consumer capability [G7] | Default at-rest encryption; optional team E2EE folders on eligible plans, not all account content by default [D6] | Documented service-side transit/at-rest encryption with service-held key stores, not a client-only-key guarantee [M6] | Optional Advanced Data Protection; region, sharing, web and metadata exceptions [A5] | Client-side authenticated encryption for contents, names and manifests; backend has no decrypt path. Sizes/timing/opaque namespace relationships remain visible; local sync/cache copies are plaintext. See SECURITY.md. |

Do not turn this table into a universal security score. For example, Apple's
current search documentation explicitly describes on-device processing, and
Google's Workspace CSE is a real optional capability. Conversely, ordinary
preview/search/collaboration claims must not be assumed to apply unchanged to
vendor E2EE folders. NNTDrive's content-derived same-account chunk dedupe is not
proof of independently revocable copies, faster delta transfer, or better
recovery than another service. Usenet retention, correlated shard loss and
provider availability remain fallible; logical deletion cannot retract articles.

## NNTDrive gap and completion inventory

This retains the other categories from the original review without repeating
unverified vendor Yes/No scores. There is no new implementation queue here.
Issue states below were read on the check date; a closed implementation issue
is intentionally linked as history, not described as still-open work.

| Area | Integrated capability and remaining scope | Existing issue(s) |
|---|---|---|
| Selective sync / delta storage | Per-folder excluded subtrees and content-defined chunk dedupe exist. This review did not benchmark vendor delta protocols or establish throughput parity. | [#51](https://github.com/ravand1990/nntdrive/issues/51) closed; installed propagation [#65](https://github.com/ravand1990/nntdrive/issues/65) open |
| Search | Account-wide name search is integrated; no server-side plaintext index or content OCR. Installed large-account latency/lifecycle remains unverified. | [#80](https://github.com/ravand1990/nntdrive/issues/80) closed; [#93](https://github.com/ravand1990/nntdrive/issues/93) open |
| Recovery | Trash, restore, version history and content rewind are integrated, with the limits above. | [#81](https://github.com/ravand1990/nntdrive/issues/81) closed; installed acceptance [#138](https://github.com/ravand1990/nntdrive/issues/138) open |
| Offline copies | Bounded cached revisions, pins, clear-unpinned, adjustable ceiling/free-space display exist; no disk-space reservation or OS placeholders. | [#82](https://github.com/ravand1990/nntdrive/issues/82) and [#199](https://github.com/ravand1990/nntdrive/issues/199) closed; installed acceptance [#204](https://github.com/ravand1990/nntdrive/issues/204), providers [#14](https://github.com/ravand1990/nntdrive/issues/14) open |
| Preview breadth | Image/text slice exists. PDF/media, list/grid thumbnails and lazy page rendering are unfinished; no installed preview run is claimed. | [#83](https://github.com/ravand1990/nntdrive/issues/83) open |
| Sharing and permissions | No sharing UI/public links. Encrypted sharing needs client-side key distribution, not plaintext fallback. | [#13](https://github.com/ravand1990/nntdrive/issues/13) open |
| Camera upload / native providers | Photo backup, FUSE/WinFsp, Android DocumentsProvider and iOS File Provider are unfinished. iOS delivery is deferred by the owner's cancellation decision, not an active implementation promise. | [#14](https://github.com/ravand1990/nntdrive/issues/14) open; [#12](https://github.com/ravand1990/nntdrive/issues/12) closed as not planned |
| Background / unlock | Desktop close-to-tray and opt-in login autostart exist; cold starts still require a password. Mobile scheduling and remember-unlock are not complete. | [#6](https://github.com/ravand1990/nntdrive/issues/6), [#7](https://github.com/ravand1990/nntdrive/issues/7), [#50](https://github.com/ravand1990/nntdrive/issues/50) open; installed tray/autostart [#66](https://github.com/ravand1990/nntdrive/issues/66)/[#171](https://github.com/ravand1990/nntdrive/issues/171) open |
| Transfer policy | Pause/resume exists. Upload/download caps, windows, metered policy and configurable concurrency remain unfinished; no vendor combined-policy parity asserted. | [#85](https://github.com/ravand1990/nntdrive/issues/85) open |
| Storage / duplicates | Quota display and local cache accounting/cleanup exist. Read-only account folder/type breakdowns, largest files, bounded oldest-large namespace-date reports and a separate measured indexed-cache/pinned/unpinned breakdown exist; sync-folder byte accounting, exact duplicate review, folder actions, dashboard cleanup and automatic freshness remain open. No automatic deletion is proposed. | [#84](https://github.com/ravand1990/nntdrive/issues/84) open; installed cache [#204](https://github.com/ravand1990/nntdrive/issues/204) open |
| Desktop integration | In-app reveal is not an Explorer/Finder extension. Shell overlays/context actions remain unfinished. | [#86](https://github.com/ravand1990/nntdrive/issues/86) open |
| Activity and errors | Device-local bounded history, retention, search, redacted export and links into Not synced exist. Not an account-wide/admin audit log; vendor enterprise audit breadth was not re-audited. | [#87](https://github.com/ravand1990/nntdrive/issues/87) and [#79](https://github.com/ravand1990/nntdrive/issues/79) closed; installed acceptance [#196](https://github.com/ravand1990/nntdrive/issues/196)/[#194](https://github.com/ravand1990/nntdrive/issues/194) open |
| Device management | Token revoke and in-app account-key epoch rotation exist. Revocation cannot erase already-read content or a compromised device's copies; remote wipe is outside the present threat-model guarantee. | [#184](https://github.com/ravand1990/nntdrive/issues/184) closed; installed two-device check [#191](https://github.com/ravand1990/nntdrive/issues/191) open |

Server-side plaintext content indexing, OCR, thumbnail generation and AI are
incompatible with the current trust boundary. Any future content-aware work
must run on-device or have a separately reviewed E2EE design. Real-time Office/
Google Docs co-editing is deliberately outside current scope, not a small missing
checkbox. LAN peer sync is also outside this Usenet-primary product design.
The review creates no duplicate issues and does not reopen completed features
just because installed acceptance is separately pending.

## Practical conclusion

The old review's “no search / trash / offline cache / activity / previews” cells
are obsolete. The useful remaining product work is **breadth and integration**:
sharing (#13), previews (#83), storage insights (#84), transfer policy (#85),
shell integration (#86), native providers/photo backup (#14) and cold/mobile
lifecycle (#6/#50). This is a gap summary, **not** a new priority order or
permission to bypass dependencies, ownership, signing or approved environments.
Do not market the current app as feature-equivalent to all four cloud clients.
Self-hosting and always-client-side encryption distinguish its trust/operations
model, but do not establish a lower total cost or stronger durability.

## Sources (read 2026-11-23)

### Google

- G1: [Stream and mirror files](https://support.google.com/drive/answer/13401938?hl=en).
- G2: [Search and filters](https://support.google.com/drive/answer/2375114?hl=en).
- G3: [Activity and file versions](https://support.google.com/drive/answer/2409045?hl=en).
- G4: [Deleted-file recovery](https://support.google.com/drive/answer/1716222?hl=en).
- G5: [Bulk file-version restore (beta)](https://support.google.com/drive/answer/16482799?hl=en).
- G6: [View and open files](https://support.google.com/drive/answer/2423485?hl=en).
- G7: [Encrypted files and optional Workspace CSE](https://support.google.com/drive/answer/10519333?hl=en).

### Dropbox

- D1: [Online-only and available-offline files](https://help.dropbox.com/sync/make-files-online-only).
- D2: [Search your files](https://help.dropbox.com/view-edit/search).
- D3: [Version history](https://help.dropbox.com/delete-restore/version-history-overview).
- D4: [Rewind, eligibility and exclusions](https://help.dropbox.com/delete-restore/rewind).
- D5: [Preview formats and limits](https://help.dropbox.com/view-edit/file-types-that-preview).
- D6: [Optional team end-to-end encryption](https://www.dropbox.com/features/security/end-to-end-encryption).

### Microsoft

- M1: [Windows Files On-Demand](https://support.microsoft.com/en-us/onedrive/save-disk-space-with-onedrive-files-on-demand-for-windows).
- M2: [Find files, Search everything and recovery](https://support.microsoft.com/en-us/onedrive/find-lost-or-missing-files-in-onedrive).
- M3: [Restore previous file versions](https://support.microsoft.com/en-us/onedrive/restore-a-previous-version-of-a-file-stored-in-onedrive).
- M4: [Restore your OneDrive](https://support.microsoft.com/en-us/onedrive/restore-your-onedrive).
- M5: [Preview formats and thumbnails](https://support.microsoft.com/en-us/onedrive/file-types-supported-for-previewing-files-in-onedrive-sharepoint-and-teams).
- M6: [Service encryption and key stores](https://learn.microsoft.com/en-us/purview/data-encryption-in-odb-and-spo) (Microsoft 365 service architecture, not an audit of every consumer configuration).

### Apple

- A1: [Keep files downloaded on Windows](https://support.apple.com/guide/icloud-windows/keep-files-downloaded-icw8531ad6b7/icloud).
- A2: [Web viewing, previews and device-provided search](https://support.apple.com/guide/icloud/view-files-and-folders-mmebf050837b/icloud).
- A3: [Deleted-file recovery](https://support.apple.com/guide/icloud/recover-deleted-files-mmae56ea1ca5/icloud).
- A4: [Web upload/download and Finder/Files access](https://support.apple.com/guide/icloud/upload-and-download-files-mmad632d1df2/icloud).
- A5: [Advanced Data Protection and its exceptions](https://support.apple.com/guide/security/advanced-data-protection-for-icloud-sec973254c5f/web).

## Keeping the record current

Recheck quarterly or after a major product release, as requested in #88. Update
this dated document and the issue's summary link; do not keep an independent
copy of the matrix in issue prose. Re-read vendor sources, versioned capability
docs, release notes and current issue states. Keep completed implementation
links and move only remaining work to existing follow-ups. The current review
can be completed without treating the linked implementation or verification
issues as completed. No periodic job or new backlog is created by this document.
