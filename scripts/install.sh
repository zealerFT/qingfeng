#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

install_path="/Applications/清风.app"
build_path="$(pwd)/dist/清风.app"
staging_path="/Applications/.清风.app.new.$$"
trash_path="$HOME/.Trash"
launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d /Applications || ! -w /Applications ]]; then
  echo "Cannot write to /Applications. Run this script from an administrator account." >&2
  exit 1
fi

mkdir -p "$trash_path"

running_pid="$(ps -axo pid=,comm= | awk '$2 ~ /\/清风\.app\/Contents\/MacOS\/Qingfeng$/ { print $1; exit }')"
if [[ -n "$running_pid" ]]; then
  echo "Warning: Qingfeng is running (PID $running_pid); it will keep using its current code until it quits." >&2
fi

bash scripts/build.sh

if [[ ! -d "$build_path" ]]; then
  echo "Build did not produce $build_path" >&2
  exit 1
fi

rm -rf "$staging_path"
trap 'rm -rf "$staging_path"' EXIT
ditto --norsrc --noextattr "$build_path" "$staging_path"

app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$staging_path/Contents/Info.plist")
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$staging_path/Contents/Info.plist")

move_to_trash() {
  local source="$1"
  local label="$2"
  local stamp target suffix

  [[ -e "$source" ]] || return 0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="$trash_path/${label}-${stamp}.app"
  suffix=1
  while [[ -e "$target" ]]; do
    target="$trash_path/${label}-${stamp}-${suffix}.app"
    suffix=$((suffix + 1))
  done

  if [[ -x "$launch_services" ]]; then
    "$launch_services" -u "$source" >/dev/null 2>&1 || true
  fi
  mv "$source" "$target"
  # Moving a bundle can register its new location; remove the Trash entry too.
  if [[ -x "$launch_services" ]]; then
    "$launch_services" -u "$target" >/dev/null 2>&1 || true
  fi
  echo "Moved old app to Trash: $source"
}

# Replace the canonical install and remove the two paths that previously
# appeared as separate Qingfeng apps in Launchpad.
move_to_trash "$install_path" "清风-installed-old"
move_to_trash "$HOME/Applications/清风.app" "清风-user-old"
move_to_trash "$build_path" "清风-build-old"
mv "$staging_path" "$install_path"

if [[ -x "$launch_services" ]]; then
  "$launch_services" -f "$install_path" >/dev/null 2>&1 || true
fi

echo "Installed Qingfeng $app_version ($bundle_id) at $install_path"
echo "The ZIP remains at dist/Qingfeng-${app_version}-AppleSilicon.zip"
