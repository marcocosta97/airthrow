#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/keyboard-checks .build/check-module-cache
CLANG_MODULE_CACHE_PATH=.build/check-module-cache SWIFT_MODULECACHE_PATH=.build/check-module-cache \
swiftc -swift-version 6 -parse-as-library Sources/AirThrowApp/PlaybackKeyboardWindow.swift \
    Tests/KeyboardChecks/main.swift -o build/keyboard-checks/KeyboardChecks
build/keyboard-checks/KeyboardChecks
