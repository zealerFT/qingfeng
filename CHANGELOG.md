# Changelog

Notable changes to Qingfeng are documented here. Version numbers match the app's `CFBundleShortVersionString`.

## [Unreleased]

### Documentation

- Prepare the repository for GitHub with an English default README and a Simplified Chinese README.
- Add repository-local screenshots, publishing instructions, and an MIT license.
- Exclude generated assets, local scan reports, and private development notes from version control.
- Redact machine-specific screenshot content and remove embedded image metadata before public distribution.

## [1.0.2] - 2026-10-26

### Added

- A Scan Settings panel for the per-directory scan limit, with a default of 300,000 entries and a range of 10,000–1,000,000.
- Plain-number and comma-separated input, including `400000` and `400,000`, plus preset values.
- Persistent local settings and automatic rescanning after saving.

### Changed

- Scanning and cleanup revalidation use the same configured limit.
- The separate large-file search limit remains at 500,000 entries.

## [1.0.1] - 2026-10-26

### Fixed

- Distinguish access denials, files changing during scanning, scan limits, and other read failures.
- Show the permission settings shortcut only for actual access denials.
- Avoid reporting a limit when a scan completes exactly at the boundary.
- Match running JetBrains IDEs to the corresponding product and cache version, avoiding blocks on unrelated IDEs.
- Include the blocking app's name, version, and process ID in new cleanup messages when available.
- Preserve compatibility with older exported reports and history.

## [1.0.0] - 2026-10-20

### Added

- Native SwiftUI application for Apple Silicon Macs running macOS 14 or later.
- Application and developer cache scanning, old logs and installers, and large-file discovery.
- View-only inspection of known model, container, backup, archive, and IDE history locations.
- Explicit cleanup confirmation, metadata revalidation, app-use checks, and moves to the system Trash.
- Local cleanup history, report export, and a custom app icon.
