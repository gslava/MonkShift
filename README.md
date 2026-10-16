# MonkShift

A minimal native macOS focus utility built with SwiftUI and AppKit. macOS 14 or later. MIT licensed, fully offline, no dependencies, accounts, analytics, network clients, web views, or resident helper processes.

## Build and open

Requires Apple's Command Line Tools (`xcode-select --install`) or Xcode. From the project directory:

```sh
bash scripts/check.sh
bash scripts/build-app.sh
open build/MonkShift.app
```

The build produces an ad-hoc signed app for the current Mac's architecture. Move it to `/Applications` **before granting permission** to keep its path stable. To edit in Xcode, open `Package.swift`; use the build script to produce an app bundle with the required privacy metadata. No full Xcode installation is needed for the scripts.

For distribution to other Macs, build/test the required architectures, sign using an Apple Developer identity (`MONKSHIFT_SIGN_IDENTITY`), and notarize separately. The default local build is not notarized and is not a universal binary.

## Permission and privacy

The first-launch screen explains the permission and displays the open-source/offline labels. Click **Grant Automation Permission**, then allow **System Events** in the macOS prompt. All system controls and global shortcut actions remain gated until this permission is granted. After denial, open System Settings → Privacy & Security → Automation → MonkShift and enable System Events, then click **Check Again**.

Only Automation is requested. Dock/menu-bar scripting uses System Events' preferences dictionary; it does not automate mouse clicks in System Settings. Global shortcuts use Carbon registration, so Accessibility, Screen Recording and Input Monitoring permissions are not requested. Privacy state is checked again before every mutation. Revocation blocks later actions; a restore record remains available once permission is granted again.

System Events can exit while idle. If a permission check reports that its target is not running, MonkShift starts it in the background and checks again without prompting. The menu updates when the check completes; consent is requested only through the onboarding button.

Rebuilding an ad-hoc signed app can invalidate macOS's stored permission identity. Reopen the final app from its stable location and regrant permission if necessary.

## Controls and status

Every setting has a checkbox in the window and in the native menu bar menu. Status is refreshed when opening the menu/window, returning to MonkShift, changing the desktop Space while the window is visible, waking the Mac, and after applying settings. Use **Refresh** for changes made elsewhere. No repeating background polling is used.

| Setting | Implementation and scope |
| --- | --- |
| Instant Dock | `com.apple.dock` → `autohide-delay = 0`, `autohide-time-modifier = 0`; Dock reloads after applying the group. |
| Hide Dock | System Events → `autohide of dock preferences`. Auto-hides; reveal by moving to its screen edge. |
| Hide menu bar | System Events → `autohide menu bar of dock preferences`. Auto-hides; reveal by moving to the top edge. |
| Instant menu bar | **Unavailable in this version.** No verified system-wide timing implementation was found. The disabled checkbox explains this. Monk Mode applies the other supported settings and reports this limitation. |
| Stage Manager | `com.apple.WindowManager` → `GloballyEnabled`. Requires “Displays have separate Spaces”; if disabled, MonkShift explains the prerequisite. |
| Hide recent apps | `com.apple.WindowManager` → `AutoHide = true`. Only affects Stage Manager while it is enabled. |
| One window at a time | `com.apple.WindowManager` → `AppWindowGroupingBehavior = 1`. Only affects Stage Manager. |
| Black wallpaper | An 8 × 8 opaque black PNG generated locally, applied through `NSWorkspace` to each connected display in the current desktop Space. |
| Grayscale | System display color filter category 1, type 1, through dynamically resolved `MADisplayFilterPref*` APIs and the system Universal Access daemon. |

The grayscale slider defaults to **50%**, is stored locally, and writes only when editing ends. It normalizes the native exported minimum/maximum intensity range to 0–100% (on the development Mac, native 0.25–1.0). 0% is the lowest supported filter intensity; switch the checkbox off to remove the filter completely. While grayscale is on, refresh reads its current intensity from macOS and slider changes apply after release. When off, the chosen amount is used on the next enable.

**Compatibility:** Dock and Stage Manager preference keys and the color filter symbols are not stable public configuration APIs. Their actual visual effects require manual checks on each supported macOS version. Checkboxes read system preferences/API state, not screen pixels. A preference read-back confirms the stored value; it cannot prove the corresponding daemon rendered the effect. Missing symbols, failed writes and unknown states are shown explicitly. No SIP changes or administrator privileges are used.

## Monk Mode and restoration

**Monk Mode (Enable All)** first captures every available setting and writes the restore file atomically before making changes. It then applies the supported settings. Failures appear individually; an error does not count as successful application.

**Disable Monk Mode** restores exactly the saved state from immediately before that session, including prior filter type/enabled state/intensity and wallpaper URL/options. Quitting keeps the current system settings and the restore record. Opening MonkShift again lets you disable/restore the saved session.

Individual checkbox changes also save their first baseline. Unchecking restores that feature's saved configuration and ensures the feature is off. **Restore All Changes** restores the Monk session first, then the earlier individual baselines. This means a previously enabled system feature can be restored to enabled. Individual edits during a Monk session do not replace the session baseline.

If restoration fails, the corresponding record stays on disk for retry. For a disconnected display, reconnect it and retry **Restore All Changes**. An unreadable/corrupted restore file blocks modifications rather than replacing the file. A missing file on a first launch is normal.

Local data:

```text
~/Library/Application Support/MonkShift/restore.json
~/Library/Application Support/MonkShift/black.png
```

Shortcuts and the preferred slider position live in the app's UserDefaults domain `app.monkshift.MonkShift`. Wallpaper restoration is limited to saved connected displays and their current desktop Space. Other Spaces, rotating wallpaper schedules, live/video wallpaper state, and displays attached after a snapshot are not managed. Keep original wallpaper files available until restoration. Independent system-setting edits made during a Monk session are overwritten when restoring that session, as expected from restoring its saved baseline.

## Global shortcuts

| Action | Default |
| --- | --- |
| Monk Mode / restore previous session | Control + Option + Command + M |
| Stage Manager | Control + Option + Command + S |
| Color Filter | Control + Option + Command + C |
| Hide / show menu bar | Control + Option + Command + B |

Click **Shortcuts…** and then **Edit…** to choose modifiers and a letter. The app validates duplicates and OS registration errors, retaining the previous working shortcut on a failed edit. Keys use physical ANSI positions so the same combination works across input languages. As with other Carbon shortcuts, secure input/system-reserved combinations may prevent delivery. Shortcuts work while MonkShift is running, even with its window closed or menu bar auto-hidden.

## Memory design

The idle process retains one small model, native NSStatusItem/NSMenu, and Carbon shortcut registrations. Closing the window releases its SwiftUI hosting tree. There are no repeated timers, live previews, third-party frameworks, web views or helper daemons. macOS system processes such as Dock and universalaccessd are managed by macOS, not resident MonkShift helpers.

No fixed RAM claim is made until the release build is measured. To measure, launch the release app, grant permission, close the window, let it idle, then inspect **Memory** for MonkShift in Activity Monitor. Compare open-window and closed-window states. Shared framework pages and OS caches mean RSS and Activity Monitor's memory figure differ.

## Verification

`bash scripts/check.sh` runs 13 tests against a fake backend and temporary storage: write-before-mutate, failed writes, repeated enables, partial apply/restore failures, restoration after restart, baseline ordering, edits during a session, pre-existing enabled features, and file corruption/version handling. It does not request privacy permissions or change macOS settings. A dependency-free Foundation runner is used because Command Line Tools do not include XCTest.

The same script compiles the app's actual permission manager with a fake client and runs 8 additional checks: idle-target recovery, denied/missing/revoked consent, unavailable targets, launch failures, concurrent refreshes, and explicit request completion. No real services are started or privacy prompts requested by these checks.

`bash scripts/render-previews.sh` renders light/dark window and onboarding PNGs into `build/previews` using fixture state. The renderer is compiled only with `MONKSHIFT_PREVIEW`; it is absent from release builds. These images verify layout, not real OS behavior.

Manual acceptance checks on **both macOS 14 and macOS 15**:

- Deny the permission: controls and shortcuts remain locked. Grant it: controls unlock. Revoke it: future actions are blocked.
- After granting permission, close the window and let System Events exit while idle. Open MonkShift's menu: controls should appear after the background check, without another consent prompt. Repeat after restarting MonkShift.
- Record initial Dock, menu bar, Stage Manager, wallpaper and filter states. Enable each setting and verify its actual visual effect, including Stage Manager grouping with two windows from the same app.
- Enable Monk Mode; verify the supported features and the explicit unavailable menu bar timing message. Disable it and compare to the recorded baseline.
- Start with a different color filter enabled. Enable grayscale, adjust its slider, and restore; confirm the original type and intensity are preserved.
- Quit while Monk Mode is active. Reopen and restore the previous state.
- Change an individual setting, start Monk Mode, edit another setting, disable Monk Mode, then Restore All; verify baseline ordering.
- Test wallpaper restoration with multiple displays, a temporarily disconnected display, and separate desktop Spaces. Confirm documented scope.
- Edit and use all four shortcuts from another app. Try duplicates and a shortcut registered by another app; confirm errors preserve the previous assignment.
- Inspect light/dark mode, keyboard navigation, VoiceOver labels, minimum window size and scrolling. Closing the window leaves menu bar control available.
- Measure idle CPU/memory using the release build after closing the window.

The build scripts do not launch MonkShift or change system settings. Real permission prompts, visual OS effects, macOS 14 behavior, global shortcut delivery and idle RAM remain manual verification gates until tested in an intentional app session.

## Source references

- [Apple: Stage Manager behavior and prerequisites](https://support.apple.com/en-ie/guide/mac-help/mchl534ba392/mac).
- [Apple: Automation permission API](https://developer.apple.com/documentation/coreservices/3025784-aedeterminepermissiontoautomate).
- [Apple: display color filters](https://support.apple.com/en-ie/guide/mac-help/mchl11ddd4b3/mac).
- API signatures/category/type and notification behavior were cross-checked against [brettferdosi/grayscale's API notes](https://github.com/brettferdosi/grayscale/blob/master/Sources/Bridge.h), system SDK exports and read-only runtime probes. No third-party runtime code is linked.
- [Hexnode's Stage Manager configuration reference](https://www.hexnode.com/mobile-device-management/help/script-to-enable-disable-stage-manager-on-mac/) describes its configuration scripts and grouping values.
