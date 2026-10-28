<p align="center">
  <img src="docs/assets/app-icon.png" alt="Qingfeng app icon" width="104" height="104">
</p>

<h1 align="center">Qingfeng · 清风</h1>

<p align="center">A little breathing room for your Mac.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-24685F" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-24685F" alt="Apple Silicon arm64">
  <img src="https://img.shields.io/badge/SwiftUI-native-F05138" alt="Native SwiftUI">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

**[Download Qingfeng 1.0.2 for Apple Silicon](https://github.com/zealerFT/qingfeng/releases/download/v1.0.2/Qingfeng-1.0.2-AppleSilicon.zip)** · [Release notes](https://github.com/zealerFT/qingfeng/releases/tag/v1.0.2)

macOS 14 or later · Ready-to-run app · No Xcode or compilation required

Qingfeng is a native, offline disk cleanup app for Apple Silicon Macs. It helps you review application caches, developer caches, old logs, and installers, then moves the items you confirm to the macOS Trash. Large files and important data remain available for inspection.

The app is built with **SwiftUI and AppKit**, with no third-party dependencies. Its current interface is **Simplified Chinese**; this repository provides documentation in English and Chinese.

## Features

- **Understand storage use.** Review disk capacity and cleanup candidates by category, with search and Finder shortcuts.
- **Keep control of cleanup.** Nothing is selected by default. Each cleanup requires confirmation and a fresh check of file metadata.
- **Manage developer caches.** Find known caches from npm, pip, uv, Homebrew, Go, Xcode, JetBrains IDEs, and browser testing tools.
- **Inspect important data.** Models, container storage, device backups, Xcode archives, and IDE local history are view-only.
- **Adjust scan limits.** Set a per-directory limit from 10,000 to 1,000,000 entries, including `400000`.
- **Work offline.** No account, analytics, server, or background service. Cleanup history stays on your Mac.

> Moving files to Trash does **not** immediately reclaim disk space. Review or restore them in Finder, then empty Trash yourself when ready. Qingfeng never empties it for you.

## Requirements

| Requirement | Details |
| --- | --- |
| Hardware | Apple Silicon Mac, including M3; native `arm64` builds |
| Operating system | macOS 14 or later |
| Building from source | Swift 6.0+ toolchain, supplied by compatible Xcode or Command Line Tools |
| App language | Simplified Chinese |

Not every supported macOS version and Apple Silicon model has been tested. Intel builds are not provided.

## Installation

### Packaged app

1. **[Download the Apple Silicon app](https://github.com/zealerFT/qingfeng/releases/download/v1.0.2/Qingfeng-1.0.2-AppleSilicon.zip)** (`Qingfeng-1.0.2-AppleSilicon.zip`).
2. Double-click the ZIP to extract it, then drag **清风.app** into **Applications**.
3. Open **清风** from Applications. No developer tools or compilation are needed.

The automatically generated **Source code** downloads on the [release page](https://github.com/zealerFT/qingfeng/releases/latest) are for developers; the app download is the ZIP named **Qingfeng-1.0.2-AppleSilicon.zip**.

Current packages use an **ad-hoc signature** and are **not notarized by Apple**. If macOS blocks an app you have downloaded from this repository and trust, try opening it once, then use **System Settings → Privacy & Security → Open Anyway**, if offered. You can also build from source.

### Build from source

On an Apple Silicon Mac with a Swift 6.0+ toolchain:

```bash
git clone https://github.com/zealerFT/qingfeng.git
cd qingfeng
bash scripts/test.sh
bash scripts/build.sh
open dist/清风.app
```

The build script creates an `arm64` release executable, generates the app icon, applies a local ad-hoc signature, verifies it, and produces:

```text
dist/清风.app
dist/Qingfeng-<version>-AppleSilicon.zip
```

## Usage

1. Click **开始扫描** (Start Scan). Scanning inspects filesystem metadata without deleting files or reading their contents.
2. Open **清理项目** (Cleanup Items). Review names, paths, sizes, and notes; use the folder button to reveal a location in Finder.
3. Quit the relevant apps and stop build tasks. Select only the items you no longer need.
4. Click **复核并清理** (Review & Clean), review the confirmation, and proceed. Changed, incomplete, or blocked items are skipped.
5. Check **操作记录** (History) and the system Trash. Restore anything you need before emptying Trash in Finder.

**勾选较旧项目** (Select Older Items) selects eligible items in the current list that have not changed for at least seven days and are not blocked by a detected running app. Review those selections yourself; age alone does not make a file unnecessary.

### Scan settings

Open the gear button at the top right, enter a value such as `400000` or `400,000`, and click **保存并重新扫描** (Save & Rescan).

| Setting | Value |
| --- | --- |
| Default per-directory limit | 300,000 entries |
| Configurable range | 10,000–1,000,000 entries |
| Large-file search limit | 500,000 entries, fixed separately |

The setting is saved locally and survives restarts. Saving clears the previous scan results and starts a new scan; cleanup revalidation uses the same limit. Higher limits can increase scan time and memory use. A directory that exceeds its limit remains view-only until it is scanned completely.

## Cleanup scope

| Category | Included locations | Behavior |
| --- | --- | --- |
| Application caches | Allowed app directories in `~/Library/Caches` | Apple system cache identifiers and several reserved directories are excluded. Quit the relevant app first. |
| Developer caches | Known npm, pip, uv, Homebrew, Yarn, Go, Xcode DerivedData, Playwright, Cypress, and related cache paths | Tools may need to download or rebuild data afterward. |
| JetBrains caches | Per-version `caches`, `index`, `compile-server`, and `tmp` directories | Preserves LocalHistory and other IDE data. Running-app checks match the IDE product and version when available. |
| Old logs | Items under `~/Library/Logs` | The entire item must have no updates in the last 30 days. |
| Old installers | Top-level `.dmg`, `.pkg`, and `.xip` files in `~/Downloads` | At least 30 days old; ZIP archives and nested installers are excluded. |
| Large files | Downloads, Desktop, Documents, Movies, or a folder you choose | Files with at least 200 MB of allocated space; shows up to the 200 largest results. Finder inspection only. |
| Important data | Known model directories, Docker/Podman storage, device backups, Xcode archives, JetBrains LocalHistory, and the pnpm shared store | Size inspection only; cleanup is disabled. |

Qingfeng does not provide app uninstallation, permanent deletion, container pruning, or cleanup of system directories, photo libraries, chat histories, source repositories, Keychain, or Time Machine backups. Symbolic links and special files prevent a candidate from being cleaned.

## Permissions and limitations

- **Access denied:** macOS can restrict individual folders. If needed, add Qingfeng under **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen it. Ad-hoc signature changes after an update may require removing and re-adding the installed app.
- **Files changed during scanning:** active apps can delete or replace cache files. Quit the corresponding app and rescan. This is distinct from an access denial.
- **Scan limit reached:** increase the per-directory limit or choose a smaller folder for a large-file search. Granting more permissions does not change a scan limit.
- **App still running:** quit the app identified in the message and rescan. Detection cannot cover every custom cache location or command-line build task.
- **Storage estimates:** sizes reflect allocated disk blocks. APFS clones, snapshots, compression, and shared storage can make reclaimed space differ from the displayed total.

File metadata is checked again before cleanup. These checks reduce accidental changes but do not provide isolation against a malicious process racing to replace paths.

## Privacy

Qingfeng has no network requests, analytics, or sign-in. Scan results stay in memory unless you export a report. Local cleanup history is stored at:

```text
~/Library/Application Support/清风/history.json
```

History is limited to 2,000 entries. Exported reports and history contain local paths; review them before sharing them in an issue.

## Development

```text
Sources/QingfengApp/      SwiftUI interface and AppKit integration
Sources/QingfengCore/     Scanning, safety rules, app detection, and cleanup
Tests/QingfengCoreTests/  Filesystem checks using temporary fixtures
Resources/               App metadata and icon source
scripts/                 Test, build, and icon generation scripts
docs/                    Screenshots and publishing instructions
```

Run `bash scripts/test.sh` for the standalone `QingfengCoreChecks` executable. It currently contains 30 checks, including path boundaries, symbolic links, changes after scanning, scan limits, app detection, and Trash behavior with synthetic files. The check runner does not depend on XCTest.

Bug reports and focused pull requests are welcome. Include the app version, macOS version, chip, reproduction steps, and the exact message. Redact private paths and names. Changes to cleanup behavior should include regression checks using temporary fixtures.

See the [changelog](CHANGELOG.md) and [publishing guide](docs/PUBLISHING.md). The app icon was generated with Brain and packaged locally; its source prompt is included in [Resources/icon-prompt.txt](Resources/icon-prompt.txt).

## Screenshots

These privacy-edited captures show the Chinese interface from **v1.0.0**. Machine-specific storage figures, usage charts, item names, paths, counts, and scan times have been replaced with neutral placeholders. The current version adds scan settings and more specific scan notices; see the [changelog](CHANGELOG.md).

### Storage overview

![Qingfeng storage overview with disk capacity and cleanup categories](docs/screenshots/overview.png)

### Review cleanup items

![Qingfeng cleanup list showing developer caches with no items selected](docs/screenshots/cleanup.png)

## License

[MIT](LICENSE) © 2026 zealerFT.
