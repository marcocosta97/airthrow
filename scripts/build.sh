#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-${CONFIGURATION:-release}}"
build_dir="${AIRPLAYER_BUILD_DIR:-build}"
mkdir -p "$build_dir"
swift build -c "$configuration" --disable-sandbox --build-system native
bin_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox --build-system native)"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/airplayer-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app="$staging_dir/AirPlayer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/AirPlayerApp" "$app/Contents/MacOS/AirPlayerApp"
cp "$bin_dir/airplayer" "$app/Contents/MacOS/airplayer"
cp "$bin_dir/airplayer" "$build_dir/airplayer"
cp Resources/Info.plist "$app/Contents/Info.plist"
bash scripts/write-build-commit.sh "$app/Contents/Resources/BuildCommit.txt"
swift scripts/make-icon.swift "$build_dir/AirPlayer.iconset"
iconutil -c icns "$build_dir/AirPlayer.iconset" -o "$app/Contents/Resources/AirPlayer.icns"
# Finder/iCloud can attach metadata to a generated .app inside Documents.
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
identity="${CODE_SIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$app/Contents/MacOS/airplayer"
    codesign --force --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/MacOS/airplayer"
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --strict "$app"
# Keep an archive without Finder/iCloud metadata; synced folders can reattach
# prohibited attributes to a loose .app even after successful signing.
ditto --norsrc --noextattr -c -k --keepParent "$app" "$build_dir/AirPlayer.zip"
ditto --norsrc --noextattr "$app" "$build_dir/AirPlayer.app"
printf 'Built %s/AirPlayer.app\nArchive: %s/AirPlayer.zip\nCLI: %s/airplayer\n' "$build_dir" "$build_dir" "$build_dir"
