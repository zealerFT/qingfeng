# Publishing Qingfeng on GitHub

Repository: [zealerFT/qingfeng](https://github.com/zealerFT/qingfeng). This guide covers source publication and preparing app releases.

## Repository metadata

| Field | Value |
| --- | --- |
| Owner | `zealerFT` |
| Repository name | `qingfeng` |
| Visibility | Public |
| Default branch | `main` |
| License | MIT |
| Default documentation | `README.md` (English) |
| Chinese documentation | `README.zh-CN.md` |

**Description** — copy this into GitHub's Description field:

```text
A native, offline disk cleaner for Apple Silicon Macs, built with SwiftUI. Review caches and large files, then move selected items to Trash.
```

Suggested topics:

```text
macos apple-silicon swift swiftui disk-cleaner disk-space cache-cleaner developer-tools offline
```

## Publish the source

1. Create an empty public repository named `qingfeng` under `zealerFT`. Do not ask GitHub to generate a README, `.gitignore`, or license; these files are already included.
2. In the local project directory, initialize a repository if it has not already been initialized:

   ```bash
   git init -b main
   ```

3. Review the files, then make the first commit:

   ```bash
   git status --short --untracked-files=all
   git add .
   git diff --cached --stat
   git -c user.name=zealerFT -c user.email=17766344+zealerFT@users.noreply.github.com commit -m "Initial release of Qingfeng"
   ```

4. For a repository without an existing `origin`, connect it and push:

   ```bash
   git remote add origin https://github.com/zealerFT/qingfeng.git
   git push -u origin main
   ```

Use your existing GitHub authentication when prompted. A pre-existing remote or repository history should be reviewed before changing it.

The example commit uses the owner's GitHub no-reply email. Contributors should use their own public identity or GitHub no-reply address, rather than exposing a private email or machine-generated identity.

## Publish the app

From the source checkout on an Apple Silicon Mac:

```bash
bash scripts/test.sh
bash scripts/build.sh
file dist/清风.app/Contents/MacOS/Qingfeng
plutil -lint dist/清风.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/清风.app
```

For version 1.0.2, create a GitHub Release with:

- **Tag:** `v1.0.2`, targeting the reviewed `main` commit.
- **Title:** `Qingfeng 1.0.2`.
- **Asset:** `dist/Qingfeng-1.0.2-AppleSilicon.zip`.

Use these release notes as a starting point:

```markdown
Qingfeng is a native, offline disk cleanup app for Apple Silicon Macs.

### Highlights

- Review application caches, developer caches, old logs, and installers before moving selected items to Trash.
- Inspect large files and important data without deleting them in the app.
- Configure the per-directory scan limit from 10,000 to 1,000,000 entries, with settings saved locally.
- Distinguish access denials, changed files, and scan limits, with more precise running-app detection.

### Requirements and installation

- Apple Silicon Mac, macOS 14 or later; the app interface is Simplified Chinese.
- Download `Qingfeng-1.0.2-AppleSilicon.zip`, extract it, and move `清风.app` to Applications.
- This build is ad-hoc signed and is not notarized by Apple. See the README for first-launch guidance or source build instructions.
- Files are moved to Trash only after confirmation. Empty Trash yourself when ready to reclaim space.

### 中文说明

原生 Apple Silicon 磁盘整理工具，支持应用与开发缓存、旧日志、旧安装包，以及大文件和重要数据的只读查看。单目录扫描上限可设置为 10,000–1,000,000 项并保存在本机。

需要 macOS 14 及以上，应用为中文界面。安装包为本地 ad-hoc 签名，尚未经过 Apple 公证。清理需要确认，文件进入系统废纸篓；检查后自行清空才会释放空间。
```

## Repository contents

The committed screenshots live in `docs/screenshots/`. Their capture versions and provenance are documented in [screenshots/README.md](screenshots/README.md).

`.gitignore` excludes build products, generated icon files, local development records, and scan reports. The icon source remains included so a fresh checkout can regenerate all app resources. Binary app downloads belong in GitHub Releases, not in Git history.

Private notes and local scan data may still exist in an established development folder. Publish the reviewed Git file set or the prepared source archive, rather than uploading that entire folder without checking it.
