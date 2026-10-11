#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=release
case "${1:-}" in
  '') [[ $# -eq 0 ]] || exit 2 ;;
  --debug) [[ $# -eq 1 ]] || exit 2; configuration=debug ;;
  *) echo 'Usage: scripts/build-app.sh [--debug]' >&2; exit 2 ;;
esac
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app="$PWD/build/Mac Search.app"
if [[ "$configuration" == debug ]]; then app="$PWD/build/debug/Mac Search.app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/MacSearch" "$app/Contents/MacOS/MacSearch"
if [[ "$configuration" == release ]]; then strip -S "$app/Contents/MacOS/MacSearch"; fi
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
codesign --force --sign "${MACSEARCH_SIGN_IDENTITY:--}" --identifier local.stephen.macsearch "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
