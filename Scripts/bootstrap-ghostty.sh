#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
archive=Vendor/GhosttyKit.tar.gz
checksum=ae38ade4e1c7e4d6ce21b8d7c16e9a95c346005848b4e2daa2afb6f56084c024
url=https://github.com/manaflow-ai/ghostty/releases/download/xcframework-ef4f1570d62117ebc51e3b0f07ad4f34032267b6-crashsubdir-cmux-crash-sentry-off-noi18n-v2/GhosttyKit.xcframework.tar.gz
if [[ -f Vendor/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a ]]; then exit 0; fi
mkdir -p Vendor
if [[ ! -f "$archive" ]] || [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$checksum" ]]; then
  curl --fail --location --retry 3 "$url" -o "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check
tar -xzf "$archive" -C Vendor
cmp Sources/CGhostty/include/ghostty.h Vendor/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h
