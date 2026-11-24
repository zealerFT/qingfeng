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
A native disk cleaner for Apple Silicon Macs. Review caches and large files, understand storage use, and ask your own AI model before cleanup.
```

Suggested topics:

```text
macos apple-silicon swift swiftui disk-cleaner disk-space cache-cleaner developer-tools ai-assistant ollama
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

For a local user installation, run `bash scripts/install.sh` instead. It replaces `/Applications/清风.app`, moves the previous user Applications copy and temporary build bundle to Trash, and refreshes Launch Services. Keep `scripts/build.sh` for packaging or CI where installing into the host Applications folder is not desired.

## Versioned releases

For each release:

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Update both README download links, the changelog, and `docs/releases/v<version>.md`.
3. Run `bash scripts/test.sh` (Swift toolchain and Python 3 required), build, verify arm64 and the signature, and review the public file set.
4. Commit and push `main`, then separately push an annotated `v<version>` tag. Use a public Git identity, such as the owner's no-reply address above.
5. The **Publish macOS app** workflow checks the tag/version, runs core and loopback HTTP checks, and creates a GitHub Release containing `Qingfeng-<version>-AppleSilicon.zip` and `SHA256SUMS.txt`.
6. Verify both assets on the release page before sharing the link. Source-code archives are not app installers.

Current release: **1.2.1**, tag **v1.2.1**, build **7**. Release notes: [v1.2.1.md](releases/v1.2.1.md).

Packages are ad-hoc signed, not Apple notarized. Describe this in the README and release notes. Update instructions must tell users to quit and replace `/Applications/清风.app`, not retain a second app copy.

Scanning and cleanup operate offline, but optional AI sends user questions, conversation context, and selected file metadata to the configured endpoint. Do not describe the entire application as network-free. Never include real keys, personal file inventories, local reports, or identifiable screenshots in a release.

## Repository contents

The committed screenshots live in `docs/screenshots/`. Their capture versions and provenance are documented in [screenshots/README.md](screenshots/README.md).

`.gitignore` excludes build products, generated icon files, local development records, and scan reports. The icon source remains included so a fresh checkout can regenerate all app resources. Binary app downloads belong in GitHub Releases, not in Git history.

Private notes and local scan data may still exist in an established development folder. Publish the reviewed Git file set or the prepared source archive, rather than uploading that entire folder without checking it.
