## Highlights since v0.1.3

- **Settings profiles:** Default captures your current settings. Create named
  copies and switch profiles from the window or menu bar to apply them
  immediately. Changes save automatically; original restore baselines are kept.
- **Focus shortcuts:** Control + Option + Command + W toggles one-window mode;
  Control + Option + Command + D toggles background dimming. Edit them in
  Shortcuts, with clearer spacing between key symbols. Existing bindings remain.
- **One-window mode:** automatically enables Stage Manager and Hide recent apps.
  Disabling it or switching to dimming restores both earlier states, including
  after a restart or failed restoration. Existing restore journals remain readable.
- **Automatic status updates:** known preference changes from other apps and
  system events trigger a complete status read without periodic polling. Saved
  profiles and restore records remain unchanged by external edits. Changes
  without a macOS notification appear on opening, activation or Refresh.

## Verification

150 automated checks passed locally on macOS 15.8.1 (Apple Silicon), including
cross-process preference observation with isolated test data. Light and dark UI
fixtures were inspected. Live system effects and shortcut delivery on other macOS
versions and Intel Macs remain manual checks.

## Installation

Download the **Universal DMG** for macOS 14 or later (Apple Silicon and Intel).
Drag **MonkShift.app** to **Applications** and launch it there. Allow Automation
access to System Events; Accessibility is needed for background dimming.

The ZIP contains the same app. SHA-256 checksums accompany both downloads.

MonkShift is ad-hoc signed and **not notarized** with an Apple Developer ID.
macOS may require approval in System Settings → Privacy & Security.
