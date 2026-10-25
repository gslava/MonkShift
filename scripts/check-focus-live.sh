#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ] || [ "$1" != "--allow-system-changes" ]; then
    echo "Usage: bash scripts/check-focus-live.sh --allow-system-changes" >&2
    echo "Manual check: briefly changes Stage Manager, recent-apps visibility and window grouping, then restores them." >&2
    echo "Open windows from at least two apps first. Not run by check.sh or CI." >&2
    exit 2
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --target MonkShiftCore
MONK_FOCUS_BIN_DIR="$(swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --show-bin-path)"
umask 077
mkdir -p build
MONK_FOCUS_DIR="$(mktemp -d "$PWD/build/manual-focus.XXXXXX")"
MONK_FOCUS_BIN="$MONK_FOCUS_DIR/FocusExitLiveCheck"
MONK_FOCUS_FINISHED=false
restore_on_failure() {
    MONK_FOCUS_STATUS=$?
    if ! "$MONK_FOCUS_FINISHED" && [ -x "$MONK_FOCUS_BIN" ] && [ -s "$MONK_FOCUS_DIR/initial-settings.plist" ]; then
        "$MONK_FOCUS_BIN" --restore "$MONK_FOCUS_DIR" || echo "Restore failed; retry: $MONK_FOCUS_BIN --restore $MONK_FOCUS_DIR" >&2
    fi
    echo "Manual-check backup retained at: $MONK_FOCUS_DIR"
    return "$MONK_FOCUS_STATUS"
}
trap restore_on_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
swiftc -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$MONK_FOCUS_BIN_DIR/Modules" "$MONK_FOCUS_BIN_DIR/MonkShiftCore.build/"*.o \
    Sources/MonkShift/System/PreferencesWorker.swift Sources/MonkShift/System/ReduceMotionAPI.swift \
    Sources/MonkShift/System/ColorFilterAPI.swift Tests/MonkShiftManualTests/FocusExitLiveCheck.swift \
    -o "$MONK_FOCUS_BIN"
"$MONK_FOCUS_BIN" --check "$MONK_FOCUS_DIR"
MONK_FOCUS_FINISHED=true
