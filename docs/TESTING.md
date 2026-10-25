# Testing and verification

[README](../README.md) · [Development](DEVELOPMENT.md) · [Architecture](ARCHITECTURE.md)

## Automated checks

Run from the repository root:

```sh
bash scripts/check.sh
```

`bash scripts/check.sh` runs core checks against observed-state fixtures, a fake backend and temporary storage: aggregate status including unknown/unavailable settings, write-before-mutate, failed writes, repeated enables, partial apply/restore failures, restoration after restart, baseline ordering, edits during a session, pre-existing enabled features, file corruption/version handling, suspension/concurrent-operation guards, and failed finalization recovery. Reduce Motion checks include both original states, failed restoration through a file-store restart and legacy sessions without its snapshot. Legacy sessions also leave desktop visibility untouched when it was not captured. Focus-mode checks cover both baselines before switching, snapshot/disable failures, selected-mode intensity, denied selected versus unselected modes and old journals without dimming. Stage Manager and Hide recent apps dependency checks cover all four original-state combinations, separate focus cycles, failed prerequisites, ignored writes, restoration after restart, failed metadata writes, nested Monk Mode baselines and old journals without the new optional fields. It does not request privacy permissions or change macOS settings. A dependency-free Foundation runner is used because Command Line Tools do not include XCTest.

The same script compiles the app's actual permission manager with a fake client and checks: idle-target recovery, denied/missing/revoked consent, unavailable targets, launch failures, concurrent refreshes, and explicit request completion. No real services are started or privacy prompts requested by these checks.

Isolated system checks cover cross-process file locking, normal/crash
release, lock-file errors, typed Apple Event requests, background serialization,
main-actor responsiveness during a slow fake reply, and unknown/denied/unhandled/timed-out
replies. Command codes are compared with macOS's installed scripting dictionary
for both Dock and menu bar reads/writes, including true and false values. Only
permission failures suggest changing Automation access. These checks use temporary
files, short-lived test subprocesses and a fake event transport; no real Apple
Events are sent. Reduce Motion accessors are replaced with fakes to check
enable/disable/restoration and rejected writes without changing the OS. Desktop
visibility checks inject in-memory preference access into the real preferences
worker. They cover all sixteen visibility combinations, invalid values, exact
restoration of mixed Boolean/integer values and absent keys, ignored writes,
durable snapshots before mutation, and partial restoration retried after restart.

UI/intent/observation checks use the actual app model and native menu with fake settings and
permissions, isolated preferences/storage, and global shortcuts disabled. They
cover input during refresh, rapid toggles, failed-change recovery, captured slider
values, in-flight intensity reads, finalization errors, permission revocation,
native menu/slider identity, stable Quit availability, queued restoration and
deferred shutdown while changes or a refresh are pending. The intent checks
also cover all three actions, repeated enables, completion/read-back ordering,
initial refresh, denied/revoked permission, partial apply/restore errors,
finalization failure and startup/shutdown behavior. Menu action checks verify
that individual Reduce Motion and desktop visibility changes, Monk Mode and Restore All preserve their
respective baselines. One-window menu checks also verify automatic Stage Manager and Hide recent apps
enabling/restoration, queued checkmarks and read-back after a failed prerequisite.
Dimming checks also simulate delayed WindowServer publication, bounded genuine ordering failures, cancelled validation, uninterrupted focus handoff, deadline expiry, menu retention/close, nested menu sources, transient-panel detection, slow/missing AX menu replies without menu notifications, explicit menu events overriding missing inferred state, preserved confirmed history after unresolved reads, repeated menu switching without document refocus, stale/ambiguous anchor rejection and immediate clearing for unsafe transitions even while a menu is open. Native unshown window fixtures also distinguish a level-zero accessory popup from a closable settings window. No real Apple Events, privacy prompts or system-setting writes are performed.

Focus-reader checks inject Accessibility responses and window metadata into the
actual background reader. They cover unpublished/incomplete popup geometry,
repeated Stats-style panel handoffs, real settings windows and ambiguous matches.

Observation checks use isolated notification centers and temporary preferences,
including a second process writing only to a unique `MonkShiftObserverChecks.*`
domain. They verify event coalescing, shutdown, deferred reads during mutations,
reads and both slider editors, and preservation of profiles and restore files.
The cross-process check requires access to the user's preferences service and can
be blocked by a filesystem sandbox; it does not write real macOS settings.

Automated checks do not establish live menu compatibility or CPU/RAM usage.

Window-grouping checks exercise the real preferences adapter with in-memory
storage: native values 0/1/2, missing/unsupported states, enable/disable direction,
ignored writes and exact restoration including absent keys. Focus-cycle checks
combine that adapter with the restore engine across all Stage Manager/recent-app
baselines. Dimming conflicts require Stage Manager to be enabled.

## Fixture previews

`bash scripts/render-previews.sh` renders light/dark window and onboarding PNGs into `build/previews` using fixture state. The controls use the same 716 × 568 pt content size as the app. They cover off, all enabled with/without a saved session, background dimming with/without Accessibility, partially enabled, unknown, unavailable, failed-operation, applying and refreshing states, plus the minimum window size and the menu bar icon at native and enlarged sizes. The direct native intensity view is rendered with grayscale on/off, disabled, and at the 0%/100% endpoints. Add `--readme` to refresh the tracked examples in `docs/images`. The renderer is compiled only with `MONKSHIFT_PREVIEW`; it is absent from release builds. These images verify layout, not real OS behavior.

## General manual checks

Run on **both macOS 14 and macOS 15**, and on newer macOS versions before claiming support. Record the versions actually tested:

- With Stage Manager on and two windows from the same app open, enable **Show windows one at a time** and confirm System Settings selects **One at a Time** and the visual effect matches. Disable it and confirm **All at Once**. Repeat with a previously enabled Stage Manager and with it initially off. Check background dimming still works with Stage Manager off even when its stored grouping selects a single-window variant.
- With the controls visible, toggle Stage Manager using an external shortcut and System Settings. Check its observed status changes after macOS publishes the preference update. Repeat for Dock/menu bar, recent apps, window grouping, desktop visibility, Reduce Motion and color-filter changes. Test external changes while a slider is being dragged and while a profile/setting change is queued. Verify the saved profile and Restore All baseline are retained. Check wallpaper changes on return to MonkShift or Refresh when no notification is delivered.
- Deny the permission: controls and shortcuts remain locked. Grant it: controls unlock. Revoke it: future actions are blocked.
- After granting permission, close the window and let System Events exit while idle. Open MonkShift's menu: controls should appear after the background check, without another consent prompt. Repeat after restarting MonkShift.
- Record initial Dock, menu bar, Stage Manager, wallpaper and filter states. Enable each setting and verify its actual visual effect, including Stage Manager grouping with two windows from the same app.
- Enable Monk Mode; verify all ten settings and the aggregate status at the top of both the window and menu. Disable one setting and confirm **Partially enabled** appears even with a saved session. Disable Monk Mode and compare to the recorded baseline. Unknown/unavailable readings must not produce **All enabled** or a false **Off**.
- Compare **Hide desktop icons and widgets** with System Settings → Desktop & Dock → Show Items / Show Widgets. Test Stage Manager both off and on, starting with all items visible, all hidden and mixed settings. Enable individually and through Monk Mode; verify both icons and widgets hide, desktop files and widget positions are preserved, and disabling Monk Mode restores each original value. Quit/reopen with a session active and restore. Check the documented temporary reveal on desktop click, multiple displays and Spaces. Old sessions without a desktop-visibility snapshot must leave these settings untouched.
- Compare Reduce Motion with System Settings → Accessibility → Display. Toggle it individually and through Monk Mode, starting once enabled and once disabled; disable Monk Mode and verify the exact original state. Quit/reopen with the mode active, then restore. Check another running app observes the change. These live checks are separate from fake-backend tests and read-only symbol/getter probes.
- Start with a different color filter enabled. Enable grayscale, adjust its slider, and restore; confirm the original type and intensity are preserved. Repeat through the menu bar's direct **Grayscale intensity** control: the percentage should follow dragging, settings should apply on release, and the window should show the same value. With grayscale off, verify the menu slider is disabled; choose a preferred amount in the window, then enable the filter and verify that amount is used. Check both controls stay available during changes and are disabled when the filter is unavailable/unknown. Make several quick checkbox/slider changes: confirm the last chosen values are retained, the interface does not grey out, and the open native menu slider retains focus through background refreshes.
- Quit while Monk Mode is active. Reopen and restore the previous state.
- Launch a second copy while MonkShift is running, including with its window closed: only the existing window should open and no second menu bar item should appear. After terminating the owner, verify a subsequent launch works and saved restoration remains available.
- Change an individual setting, start Monk Mode, edit another setting, disable Monk Mode, then Restore All; verify baseline ordering.
- Test wallpaper restoration with multiple displays, a temporarily disconnected display, and separate desktop Spaces. Confirm documented scope.
- Edit and use all six shortcuts from another app. Try duplicates and a shortcut registered by another app; confirm errors preserve the previous assignment.
- With a full-Xcode build installed in `/Applications`, open Shortcuts and find all three MonkShift actions. Run Toggle with MonkShift quit, then again while it is running; confirm the saved baseline is restored. Repeat Enable twice, then Disable twice. Test a revoked Automation permission and a partial restore failure: Shortcuts must report an error and the restore records must remain retryable. Verify discovery and execution on macOS 14 and the current macOS; compiler/fixture checks do not prove system registration.
- Inspect light/dark mode, keyboard navigation and VoiceOver labels. At the minimum 716 × 568 pt content size, confirm all eleven checkboxes, both sliders and footer actions remain visible without scrolling, including unknown/unavailable, Accessibility-denied and failed-operation states. Open contextual explanations and Review Issues with the keyboard; verify full messages remain readable. Closing the window leaves menu bar control available.
- With the controls window open, verify MonkShift appears in the Dock and Command + Tab switches to it. Check Command + H, Command + M, and reopening a minimized window through the menu bar. Close with the red button and Command + W: the Dock/app-switcher entry must disappear while the menu bar and global shortcuts still work. Reopen from the menu bar and repeat several times; confirm each window becomes focusable, only one controls window exists, and saved restore state remains available. Command + Q must still wait for queued changes before exiting.
- Measure idle CPU/memory using the release build after closing the window.

The build scripts do not launch MonkShift or change system settings. Real permission prompts, visual OS effects, macOS 14 behavior, global shortcut delivery, Apple Shortcuts discovery/cold launch and idle RAM remain manual verification gates until tested in an intentional app session. App Intents metadata extraction requires full Xcode and cannot be validated with Command Line Tools alone.

## Profiles manual checks

- Start with different readable macOS settings and verify the initial Default profile captures them without changing anything. Create a named copy from the dropdown and from the menu bar; reject blank or duplicate names.
- Change checkboxes and both intensities, then switch between profiles from the window and menu bar. Verify the target settings and focus mode apply immediately and both interfaces show the same selection. Repeat quickly while changes are pending.
- Restart and verify names, selection and saved configurations survive without automatically applying a profile. Restore All after multiple switches, including switches inside Monk Mode, and verify the original settings return while profiles remain saved.
- Revoke Accessibility before selecting a dimming profile. Verify the current focus mode is preserved, the error is visible, and selecting the same profile after restoring permission retries successfully.

## Background dimming manual checks

The automated dimming checks use fake Accessibility, tracking, rendering and settings clients; they do not prove live ordering or resource usage. Before shipping:

- Start the packaged app intentionally; verify Accessibility is requested only when missing and denial leaves Automation-backed controls usable. Grant/revoke it and Refresh; verify dimming hides/resumes correctly.
- Test all four initial combinations of Stage Manager and Hide recent apps. Enable **Show windows one at a time** in the window and menu, and verify both settings turn on and the recent-apps strip is hidden. Turn the mode off or switch to dimming and verify Stage Manager turns off and windows from other apps become visible, including when Stage Manager was initially on. Recent-apps visibility must return to its earlier state. Restore All must still recover both original settings. Check repeated enables, a second cycle after changing either setting, restart recovery, unavailable prerequisites and retry after a failed restoration. Only one focus mode may be enabled; Monk Mode must follow the last choice after both are turned off and after restarting. An earlier individual focus cycle must still restore both prerequisite baselines after entering and restoring Monk Mode.
- Switch between windows of the same app and different apps, including Safari, Finder, AppKit and Electron apps. Check sheets, menus, floating palettes, close/minimize and an app with no windows. Ambiguous focus, disappearance of the anchor and switching to a different regular app without a valid window must remove the overlay. Temporarily missing AX focus may retain an already identified normal window that is still on screen in the same app or behind an accessory menu. Closing/minimizing the anchor, Space/display changes, permission loss and disabling dimming clear it.
- Open MonkShift's menu, File/Edit menus, third-party menu bar utilities (including Stats) and system menus (including Wi-Fi and Control Center); leave each open for several seconds, enter submenus and dismiss with Escape or an outside click. Reopen the same menu and alternate between different menus at least six times without clicking the document between them. Dimming must remain at the chosen intensity below the last document window, with menus above it, including when the host sends no menu notification or temporarily cannot answer AX requests. Accessory popups without a native close control, including normal-level custom NSWindows, must not replace the document anchor; an actual closable settings window may become the new anchor. Open a new window from a menu and verify reanchoring without a flash. Close/minimize the retained document and verify no orphan layer remains. Verify each utility live; fake checks do not establish OS compatibility.
- Exercise Stage Manager groups, Mission Control, Spaces, full screen, Reduce Motion, multiple displays with separate Spaces, display hot-plug and mixed scaling. Check clicks and drag-and-drop pass through without focus theft. No compatibility claim is established until these checks pass on each supported macOS version.
- Verify 0%, 50% and 90%, independent grayscale/dimming sliders, rapid switching, exact restoration, failed restore retry, and exit/relaunch behavior.
- Measure release-build MonkShift and WindowServer CPU/RAM plus GPU activity with dimming off/on, both idle and during focus changes, dragging and background video. Record hardware, macOS version, display resolution/scaling and display count.

## Resource measurements

No fixed RAM claim is made until the release build is measured. To measure, launch the release app, grant permission, close the window, let it idle, then inspect **Memory** for MonkShift in Activity Monitor. Compare open-window and closed-window states, dimming off/on, and one versus multiple displays. Also measure WindowServer memory/CPU and GPU activity: compositing costs may be charged outside MonkShift. Include stationary windows, repeated focus switching, window dragging and background video; no numeric performance claim is verified yet. Shared framework pages and OS caches mean RSS and Activity Monitor's memory figure differ.


## Opt-in live focus-exit check

Open windows from at least two apps, then run intentionally:

```sh
bash scripts/check-focus-live.sh --allow-system-changes
```

This manual check uses the real settings engine and preferences adapter. It
enters one-window focus, exits it, verifies that Stage Manager is off and that
additional application windows are visible through public WindowServer metadata.
It reads no window titles or screen pixels. It operates on a private copy of the
restore journal, saves the three original preferences before mutation, and
restores them on completion. A recovery backup is retained under `build/`;
the wrapper also attempts restoration if the check fails or is interrupted.
It is never run by `check.sh` or CI and refuses to run without the opt-in flag.

Live verification on 2026-10-25, macOS 15.8.1 (Apple Silicon): the opt-in check
passed with the production engine/preferences adapter. Stage Manager and the
one-window checkbox were off after exit, visible app owners increased from 5
to 9, and the three original preferences were restored exactly. This result does
not establish compatibility with other macOS versions or display configurations.
