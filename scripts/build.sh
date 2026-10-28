#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -m)" != arm64 ]; then
  echo "This build targets Apple Silicon; run on an arm64 Mac." >&2
  exit 1
fi
swift build -c release --arch arm64 --product Qingfeng
swift scripts/make-icon.swift
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
app_path="dist/清风.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/arm64-apple-macosx/release/Qingfeng "$app_path/Contents/MacOS/Qingfeng"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/Icon.png "$app_path/Contents/Resources/"
codesign --force --sign - --timestamp=none "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ditto -c -k --sequesterRsrc --keepParent "$app_path" "dist/Qingfeng-${app_version}-AppleSilicon.zip"
echo "Built: $app_path"
