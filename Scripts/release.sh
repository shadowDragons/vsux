#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:-0.1.0}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Usage: %s X.Y.Z\n' "$0" >&2
  exit 1
fi
# Only this architecture is validated; do not label a thin binary universal.
if [[ "$(uname -m)" != arm64 ]]; then
  printf 'This release script currently supports Apple Silicon only.\n' >&2
  exit 1
fi
VERSION="$version" Scripts/build.sh release
app="$PWD/dist/vsux.app"
[[ "$(lipo -archs "$app/Contents/MacOS/vsux")" == arm64 ]]
codesign --verify --deep --strict "$app"

stage=$(mktemp -d "$PWD/dist/.dmg-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/vsux.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/INSTALL.txt" <<'TEXT'
vsux — Apple Silicon, macOS 14+

Drag vsux.app to Applications, then eject this disk image.

This preview uses an ad-hoc signature and is not notarized by Apple.
After verifying the download source and SHA-256, if macOS blocks launch,
use System Settings > Privacy & Security > Open Anyway.
Do not disable Gatekeeper globally.

This app runs your shell and Git with your user permissions. Open trusted
workspaces only; Git hooks and credential/remote helpers can execute code.
TEXT
name="vsux-${version}-macos-arm64.dmg"
output="$PWD/dist/$name"
hdiutil create -volname "vsux $version" -srcfolder "$stage" -format UDZO -ov "$output"
hdiutil verify "$output"
(cd dist && shasum -a 256 "$name" > "$name.sha256")
printf 'DMG: %s\nSHA-256: %s.sha256\n' "$output" "$output"
