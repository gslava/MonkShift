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
MONK_CHECK_BIN_DIR="$(swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --show-bin-path)"
swiftc -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$MONK_CHECK_BIN_DIR/Modules" "$MONK_CHECK_BIN_DIR/MonkShiftCore.build/"*.o \
    Sources/MonkShift/System/SingleInstanceLock.swift Sources/MonkShift/System/SystemEventsClient.swift \
    Tests/MonkShiftSystemTests/*.swift \
    -o .build/checks/MonkShiftSystemChecks
.build/checks/MonkShiftSystemChecks
# Exercise the app model and native menu with fake settings/permission clients.
# The shortcut manager has no system event handler or registered hotkeys.
swiftc -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$MONK_CHECK_BIN_DIR/Modules" "$MONK_CHECK_BIN_DIR/MonkShiftCore.build/"*.o \
    Sources/MonkShift/AppModel.swift Sources/MonkShift/PermissionManager.swift Sources/MonkShift/Shortcuts.swift \
    Sources/MonkShift/System/*.swift Sources/MonkShift/Views/GrayscaleIntensityMenuView.swift \
    Sources/MonkShift/Views/SettingsMenuController.swift Tests/MonkShiftUITests/*.swift \
    -o .build/checks/MonkShiftUIChecks
.build/checks/MonkShiftUIChecks
