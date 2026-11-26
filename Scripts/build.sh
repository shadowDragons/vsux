#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=${VERSION:-1.1.2}
build_number=${BUILD_NUMBER:-$version}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  printf 'VERSION must be X.Y.Z and BUILD_NUMBER must contain 1–3 numeric components.\n' >&2
  exit 1
fi
Scripts/bootstrap-ghostty.sh
configuration=${1:-release}
swift build -c "$configuration"
bin_path=$(swift build -c "$configuration" --show-bin-path)
mkdir -p dist
# Assemble from scratch so stale resources cannot enter a release.
staging=$(mktemp -d "$PWD/dist/.app-build.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/vsux.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ghostty" "$app/Contents/Resources/terminfo"
cp "$bin_path/CmuxClone" "$app/Contents/MacOS/vsux"
mkdir -p "$app/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
# Release binaries must not carry STABS entries containing local build paths.
# Keep debug builds intact, and strip before creating the code signature.
if [[ "$configuration" == release ]]; then
  xcrun strip -S "$app/Contents/MacOS/vsux"
fi
# AppResources resolves this installed location with either SwiftPM driver.
resource_bundle="$bin_path/CmuxClone_CmuxClone.bundle"
test -d "$resource_bundle"
rm -rf "$app/Contents/Resources/CmuxClone_CmuxClone.bundle"
cp -R "$resource_bundle" "$app/Contents/Resources/"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Vendor/Ghostty-LICENSE "$app/Contents/Resources/Ghostty-LICENSE"
mkdir -p "$app/Contents/Resources/Licenses"
install -m 644 Resources/Licenses/*.txt "$app/Contents/Resources/Licenses/"
install -m 644 LICENSE "$app/Contents/Resources/Licenses/vsux-LICENSE.txt"
install -m 644 THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
cp Resources/ghostty/ghostty.terminfo "$app/Contents/Resources/ghostty.terminfo"
# Ghostty resolves terminfo beside its resource directory (Resources/ghostty).
tic -x -o "$app/Contents/Resources/terminfo" Resources/ghostty/ghostty.terminfo
infocmp -A "$app/Contents/Resources/terminfo" xterm-ghostty >/dev/null
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>vsux</string>
<key>CFBundleIdentifier</key><string>local.vsux.app</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>vsux</string>
<key>CFBundleDisplayName</key><string>vsux</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDocumentTypes</key>
<array>
    <dict>
        <key>CFBundleTypeName</key><string>Folder</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>LSHandlerRank</key><string>Alternate</string>
        <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
</array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Local terminal. Ghostty © Mitchell Hashimoto and contributors, MIT.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
python3 Scripts/updates.py configure "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/vsux" --verify-bundled-resources
rm -rf dist/vsux.app
mv "$app" dist/vsux.app
app="dist/vsux.app"
printf 'Built: %s/%s\n' "$PWD" "$app"
