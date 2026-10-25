## Fixes since v0.1.4

**Version 0.1.5 · Build 6**

- Fix **Show windows one at a time** switching in the wrong direction. Enabling
  now selects the native single-window mode; disabling selects all windows.
- Read both native single-window variants correctly. Missing or unsupported
  grouping values show **Unknown** instead of an incorrect checkbox state.
- Keep background dimming available when Stage Manager is off, regardless of its
  stored grouping preference. Unknown active grouping pauses dimming safely.
- Preserve original grouping values, absent preference keys and Stage Manager /
  Hide recent apps baselines for restoration. Existing profiles and restore files
  remain compatible.

## Documentation

The README is shorter, with detailed guides under `docs/`. Installation now
includes the macOS first-launch warning and the **Open Anyway** instructions.

## Verification

156 automated checks passed locally on macOS 15.8.1 (Apple Silicon), including
six new preferences-adapter checks for grouping direction, native values,
rejected writes, restoration and focus-mode dependencies. Checks use isolated
preferences and fake system clients; they do not change macOS settings.
Live visual effects on macOS 14 and Intel Macs remain manual checks.

## Installation

Download the **Universal DMG** for macOS 14 or later (Apple Silicon and Intel),
then drag **MonkShift.app** to **Applications**. The ZIP contains the same app;
SHA-256 checksums accompany both downloads.

To update an existing Homebrew installation:

```sh
brew update
brew upgrade --cask gslava/monkshift/monkshift
```

MonkShift is ad-hoc signed and **not notarized**. If macOS blocks first launch,
open **System Settings → Privacy & Security → Open Anyway**, then confirm **Open**
if you trust the download. Grant Automation access to System Events;
Accessibility is needed for background dimming.
