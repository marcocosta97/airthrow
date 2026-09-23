#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-${CONFIGURATION:-release}}"
build_dir="${AIRTHROW_BUILD_DIR:-build}"
mkdir -p "$build_dir"
# Command Line Tools' SwiftPM records the deployment target as the linked SDK
# version, which opts the app out of the current system design (Liquid Glass).
# Pin the real SDK version so the app adopts the OS appearance it runs on.
deployment_target="14.0"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c "$configuration" --disable-sandbox \
    -Xlinker -platform_version -Xlinker macos -Xlinker "$deployment_target" -Xlinker "$sdk_version"
bin_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox)"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/athrow-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app="$staging_dir/AirThrow.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/AirThrowApp" "$app/Contents/MacOS/AirThrowApp"
cp "$bin_dir/athrow" "$app/Contents/MacOS/athrow"
cp "$bin_dir/athrow" "$build_dir/athrow"
cp Resources/Info.plist "$app/Contents/Info.plist"
bash scripts/write-build-commit.sh "$app/Contents/Resources/BuildCommit.txt"
# Compile the Icon Composer document so macOS renders the Liquid Glass icon,
# including its light, dark, and tinted appearances (Assets.car), with a loose
# AppIcon.icns fallback for older systems.
xcrun actool Resources/AppIcon.icon \
    --compile "$app/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target "$deployment_target" \
    --app-icon AppIcon \
    --standalone-icon-behavior all \
    --output-partial-info-plist "$build_dir/AppIcon-partial.plist" \
    --output-format human-readable-text
# Finder/iCloud can attach metadata to a generated .app inside Documents.
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
identity="${CODE_SIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$app/Contents/MacOS/athrow"
    codesign --force --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/MacOS/athrow"
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --strict "$app"
# Keep an archive without Finder/iCloud metadata; synced folders can reattach
# prohibited attributes to a loose .app even after successful signing.
ditto --norsrc --noextattr -c -k --keepParent "$app" "$build_dir/AirThrow.zip"
# Replace the previous bundle instead of merging into it, so resources removed
# from the app (for example a superseded icon) do not linger.
rm -rf "$build_dir/AirThrow.app"
ditto --norsrc --noextattr "$app" "$build_dir/AirThrow.app"
printf 'Built %s/AirThrow.app\nArchive: %s/AirThrow.zip\nCLI: %s/athrow\n' "$build_dir" "$build_dir" "$build_dir"
