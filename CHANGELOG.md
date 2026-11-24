# Changelog

Notable changes to Qingfeng are documented here. Version numbers match the app's `CFBundleShortVersionString`.

## [Unreleased]

### Documentation

- Prepare the repository for GitHub with an English default README and a Simplified Chinese README.
- Add repository-local screenshots, publishing instructions, and an MIT license.
- Exclude generated assets, local scan reports, and private development notes from version control.
- Redact machine-specific screenshot content and remove embedded image metadata before public distribution.

## [1.2.1] - 2026-11-24

### Fixed

- Visit known model directories and common personal folders before deep source trees during home-wide inventory scans. This keeps a large development checkout from consuming the traversal budget before those locations are examined.
- Continue with the rest of the home directory without duplicating files; preserve symlink protections and explicit incomplete-scan notices.
- Add a regression check for traversal priority and deduplication (53 core checks plus 8 HTTP checks).

## [1.2.0] - 2026-11-24

### Added

- An optional AI assistant with a draggable desktop icon, streaming chat, stop/retry, and right-click file analysis that starts immediately.
- OpenAI-compatible Chat Completions, Anthropic, Gemini, and Ollama protocols, provider presets, configurable endpoints/models, and API keys stored in macOS Keychain.
- Cleanup-specific analysis using selected metadata and protection flags, with home-prefix redaction and no file-content upload or automatic cleanup.
- Large-file type filters, logical/allocated size comparison, last-access sorting, configurable size threshold, and visible scan coverage.

### Fixed

- Use macOS available capacity for important usage instead of physical free space alone; show physical free and system-reclaimable capacity separately with a fallback when unavailable.
- Scan the whole current user's home, including hidden locations and Library, plus Applications. Packages are view-only aggregates and cloud placeholders are not downloaded.
- Replace the silent largest-200 cutoff with an explicit 20,000-result limit. Default minimum size is 50 MB and the inventory traversal limit is configurable independently (default 2,000,000).
- Include sparse files by logical size and normalize enumerated paths before cleanup validation.
- Preserve cleanup notices when refreshing only the large-file inventory.

### Validation

- 52 core checks and 8 local HTTP transport checks, covering all four streaming protocols, split UTF-8/SSE responses, errors, redirects, and cancellation without real provider credentials.

## [1.1.1] - 2026-11-24

### Fixed

- Explain the gap between disk usage and cleanup candidates with a three-part overview: cleanup candidates, other used space, and available space.
- Show capacities and percentages using total disk capacity consistently, including the four cleanup category cards.
- Describe other used space as the remainder including system files, apps, personal files, Trash, snapshots, and unscanned data, without claiming separate system/app measurements.
- Distinguish unscanned space from an empty cleanup result, including after a folder-only large-file scan, and handle unavailable or inconsistent capacity estimates.

## [1.1.0] - 2026-11-13

### Added

- Checkboxes, selection totals, select-all-current-results, and batch moves to Trash in the Large Files list.
- File metadata snapshots and revalidation before moving selected large files, with per-file results in cleanup history.

### Changed

- Clear selections when changing pages and keep personal files out of cache-cleanup estimates.
- Retain view-only protection for app packages, hidden paths, protected locations, and files outside the user's home directory.
- Provide a local install script that replaces `/Applications/清风.app` and removes duplicate build and user Applications copies.

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
