#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
    printf 'package-release: %s\n' "$1" >&2
    exit 2
}

[[ $# -eq 1 ]] || fail "usage: $0 vX.Y.Z"
tag="$1"
valid_tag='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$tag" =~ $valid_tag ]] || fail "tag must be a strict vX.Y.Z, got: $tag"
version="${tag#v}"

[[ "${CODE_SIGN_IDENTITY:-}" == "Developer ID Application: "* ]] \
    || fail "CODE_SIGN_IDENTITY must name a Developer ID Application certificate"
[[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]] || fail "NOTARY_KEYCHAIN_PROFILE is required"
[[ "$(uname -m)" == "arm64" ]] || fail "an arm64 host is required"

build_dir="${AIRTHROW_BUILD_DIR:-build}"
build_number="${GITHUB_RUN_NUMBER:-1}"
AIRTHROW_VERSION="$version" AIRTHROW_BUILD_NUMBER="$build_number" \
    bash scripts/build.sh release

bundle="$build_dir/AirThrow.app"
[[ -d "$bundle" ]] || fail "missing bundle: $bundle"
plist_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")"
[[ "$plist_ver" == "$version" ]] || fail "bundle version is $plist_ver, expected $version"
[[ "$plist_build" == "$build_number" ]] || fail "bundle build number is $plist_build, expected $build_number"
for bin in AirThrowApp athrow; do
    [[ -x "$bundle/Contents/MacOS/$bin" ]] || fail "missing binary: $bin"
    [[ "$(lipo -archs "$bundle/Contents/MacOS/$bin")" == *arm64* ]] \
        || fail "$bin is not an arm64 Mach-O"
done
share="$bundle/Contents/PlugIns/AirThrowShare.appex"
[[ -x "$share/Contents/MacOS/AirThrowShare" ]] || fail "missing Share extension"
[[ "$(lipo -archs "$share/Contents/MacOS/AirThrowShare")" == *arm64* ]] \
    || fail "Share extension is not an arm64 Mach-O"
for key in CFBundleShortVersionString CFBundleVersion; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$share/Contents/Info.plist")" == \
       "$(/usr/libexec/PlistBuddy -c "Print :$key" "$bundle/Contents/Info.plist")" ]] \
        || fail "Share extension $key does not match the app"
done
codesign --verify --strict "$share"
codesign --verify --strict "$bundle"
"$bundle/Contents/MacOS/athrow" --help >/dev/null

notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
if [[ -n "${AIRTHROW_SIGNING_KEYCHAIN:-}" ]]; then
    notary_args+=(--keychain "$AIRTHROW_SIGNING_KEYCHAIN")
fi
notary_report="$build_dir/notarization.json"
notary_exit=0
xcrun notarytool submit "$build_dir/AirThrow.zip" "${notary_args[@]}" \
    --wait --timeout 30m --output-format json > "$notary_report" || notary_exit=$?
if [[ -s "$notary_report" ]]; then
    submission_id="$(plutil -extract id raw -o - "$notary_report")"
    xcrun notarytool log "$submission_id" "${notary_args[@]}" "$build_dir/notarization-log.json"
fi
[[ "$notary_exit" -eq 0 ]] || fail "notarization submission failed; see $notary_report"
notary_status="$(plutil -extract status raw -o - "$notary_report")"
[[ "$notary_status" == "Accepted" ]] || fail "notarization was not accepted; see $build_dir/notarization-log.json"
xcrun stapler staple "$bundle"

release_dir="$build_dir/release"
mkdir -p "$release_dir"
release_zip="$release_dir/AirThrow-$version-arm64.zip"
# ZIP files cannot carry tickets themselves; archive the app again after stapling.
ditto --norsrc --noextattr -c -k --keepParent "$bundle" "$release_zip"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/athrow-release.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
ditto -x -k "$release_zip" "$verification_dir"
verified_bundle="$verification_dir/AirThrow.app"
codesign --verify --deep --strict "$verified_bundle"
xcrun stapler validate "$verified_bundle"
spctl --assess --type execute --verbose=4 "$verified_bundle"
printf 'Packaged %s\n' "$release_zip"
