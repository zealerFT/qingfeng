#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Qingfeng
build_path="$(swift build --show-bin-path)"
app_sources=()
for source in Sources/QingfengApp/*.swift; do
  [[ "$source" == Sources/QingfengApp/Main.swift ]] || app_sources+=("$source")
done
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -I "$build_path/Modules" "${app_sources[@]}" Tests/QingfengWindowChecks/Runner.swift \
  "$build_path"/QingfengCore.build/*.o -o "$build_path/QingfengWindowChecks"
"$build_path/QingfengWindowChecks"
