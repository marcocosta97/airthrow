#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 6 -parse-as-library -application-extension \
    Sources/AirThrowCore/Protocol.swift Sources/AirThrowCore/MediaHandoff.swift \
    Sources/AirThrowShareExtension/ShareInput.swift Tests/ShareChecks/main.swift \
    -o build/ShareChecks
build/ShareChecks
