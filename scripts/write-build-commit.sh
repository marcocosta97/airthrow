#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
revision="unknown"
if revision_from_git="$(git -C "$root" rev-parse --short=7 HEAD 2>/dev/null)"; then
    revision="$revision_from_git"
    if [[ -n "$(git -C "$root" status --porcelain --untracked-files=normal)" ]]; then
        revision="${revision}-dirty"
    fi
fi
mkdir -p "$(dirname "$1")"
printf '%s\n' "$revision" > "$1"
