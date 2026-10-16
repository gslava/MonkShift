#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift run --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security MonkShiftChecks
# Compile the actual app permission manager with a fake client. This suite never
# calls NSWorkspace or the real Automation API and also works without XCTest.
mkdir -p .build/checks
swiftc -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    Sources/MonkShift/PermissionManager.swift Tests/MonkShiftPermissionTests/PermissionManagerChecks.swift \
    -o .build/checks/MonkShiftPermissionChecks
.build/checks/MonkShiftPermissionChecks
