#!/bin/bash
# Stamp the built Info.plist with this checkout's version. A release passes
# AIRTHROW_VERSION and AIRTHROW_BUILD_NUMBER. Every other build, including
# Xcode, takes the version from git so About does not stay on the plist default.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 ]]; then
    printf 'usage: %s Info.plist [Info.plist...]\n' "$0" >&2
    exit 2
fi

version="${AIRTHROW_VERSION:-}"
build_number="${AIRTHROW_BUILD_NUMBER:-}"
valid_semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ -n "$version" && ! "$version" =~ $valid_semver ]]; then
    printf 'AIRTHROW_VERSION must be a strict x.y.z version, got: %s\n' "$version" >&2
    exit 2
fi
if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    printf 'AIRTHROW_BUILD_NUMBER must be positive digits, got: %s\n' "$build_number" >&2
    exit 2
fi

if [[ -z "$version" ]]; then
    if described="$(git -C "$root" describe --tags --abbrev=7 --match 'v[0-9]*' --dirty 2>/dev/null)"; then
        version="${described#v}"
    elif described="$(git -C "$root" rev-parse --short=7 HEAD 2>/dev/null)"; then
        version="0.0.0-g${described}"
    else
        version="0.0.0"
    fi
    if [[ -n "$(git -C "$root" status --porcelain --untracked-files=normal 2>/dev/null || true)" && "$version" != *-dirty ]]; then
        version="${version}-dirty"
    fi
fi
if [[ -z "$build_number" ]]; then
    build_number="$(git -C "$root" rev-list --count HEAD 2>/dev/null || true)"
    [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || build_number=1
fi

for plist in "$@"; do
    [[ -f "$plist" ]] || { printf 'missing Info.plist: %s\n' "$plist" >&2; exit 2; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
done
