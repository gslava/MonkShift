## Fixes since v0.1.6

**Version 0.1.7 · Build 8**

- The background dimming slider is now disabled in both the window and menu
  while **Dim background windows** is off. Enable the effect before adjusting
  its intensity.
- One-window profiles retain an explicitly saved **Hide recent apps** choice
  when reapplied, switched or reopened after restart. Stage Manager remains
  enabled, and profiles without a saved recent-app choice still default to
  hiding recent apps.
- Unavailable settings saved as off no longer block unrelated profile changes.
  Settings that a focus transition needs to change still require durable
  snapshots before any mutation. Original restore baselines remain recoverable.

## Verification

171 automated checks passed on macOS 15.8.1 (Apple Silicon): 63 core,
8 permission, 23 system and 77 UI/intent/observation checks. New regression
coverage includes slider availability, profile round trips and restart,
unavailable/failed reads, required snapshot failures and restoration.

Light/dark fixture previews were inspected. Automated checks use fake settings
and do not change macOS preferences or request permissions. Live visual behavior
on macOS 14, Intel Macs and other display/Space configurations remains a separate
manual verification step.

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
