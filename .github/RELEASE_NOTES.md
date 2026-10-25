## Fixes since v0.1.5

**Version 0.1.6 · Build 7**

- Turning off **Show windows one at a time** now stops Stage Manager, revealing
  windows from other apps even when Stage Manager was already enabled before
  entering focus. Selecting background dimming also exits Stage Manager.
- **Restore All** still restores the original Stage Manager state. Recent-apps
  visibility returns to its saved state, and existing restore records remain
  compatible. Shutdown failures retain recoverable records and report an error.
- The one-window checkbox now reports off while Stage Manager is off. Window,
  menu bar and shortcut actions share the same exit behavior; profile autosave
  records the resulting Stage Manager state.

## Verification

163 automated checks passed on macOS 15.8.1 (Apple Silicon), including new cases
for pre-existing/external Stage Manager, failure and restart recovery, profile
saving, queued checkbox input and shortcuts.

The opt-in live focus-exit check also passed on that Mac: Stage Manager turned
off and the number of apps with visible windows increased from 5 to 9. The three
original settings were restored exactly. Re-run intentionally with overlapping
windows from multiple apps:

```sh
bash scripts/check-focus-live.sh --allow-system-changes
```

That manual check is separate from the automated suite and never runs in CI.
macOS 14, Intel Macs and other display/Space configurations still require live
verification.

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
