# User guide

[README](../README.md) · [Installation and updates](DISTRIBUTION.md#first-launch-and-updates)

## Permissions

The first-launch screen explains the permission and displays the open-source/offline labels. Click **Grant Automation Permission**, then allow **System Events** in the macOS prompt. All system controls and global shortcut actions remain gated until this permission is granted. After denial, open System Settings → Privacy & Security → Automation → MonkShift and enable System Events, then click **Check Again**.

Accessibility is requested at normal startup solely to identify and observe the
active window for background dimming. Denial leaves other controls usable.
Enable MonkShift under System Settings → Privacy & Security → Accessibility,
then press **Refresh**. Screen Recording and Input Monitoring are not requested;
window titles, screenshots and keystrokes are not read.

Privacy state is checked before every mutation. Revocation blocks later actions,
but saved restore records remain available after permission is granted again.

System Events can exit while idle. If a permission check reports that its target is not running, MonkShift starts it in the background and checks again without prompting. The menu updates when the check completes; consent is requested only through the onboarding button.

Rebuilding an ad-hoc signed app can invalidate macOS's stored permission identity. Reopen the final app from its stable location and regrant permission if necessary.

## Window and status

The window opens with a **716 × 568 pt content area**, also its minimum size.
Two columns keep all eleven checkboxes and both intensity sliders visible without
scrolling: **Dock & Menu Bar** and **Stage Manager** on the left, **Window Focus**
and **Display** on the right. The header keeps the observed status, **Refresh**
and **Enable Monk Mode** / **Disable Monk Mode** together. **Shortcuts…** and
**Restore All** stay in the footer, with the app version centered between them. Hover over the
version to see the build number. Both values come from the installed app's bundle
metadata; the onboarding screen also shows the version. Disabling Monk Mode restores the settings
saved before that session.

While the controls window is open, MonkShift appears in the **Dock** and the
**Command + Tab** app switcher. Minimizing the window keeps it there. Closing the
window (red close button or **Command + W**) returns MonkShift to menu-bar-only
operation, keeping focus controls and global shortcuts active. Choose **Open
MonkShift…** in the menu bar to reopen the window and return it to the Dock and
app switcher. Reopening a minimized window brings it back on screen.

The native application menus provide **Hide** (**Command + H**), **Minimize**
(**Command + M**), **Close Window** and **Quit** (**Command + Q**), plus window
zoom and window selection. Quit exits the app; closing the window keeps it running.

Checkboxes show enabled/disabled state directly. **Unknown** and **Unavailable**
remain explicit labels. Click the information or warning button beside a setting
for its full explanation; these buttons also support keyboard focus and tooltips.
Permission actions appear inside **Window Focus** when Accessibility is missing.
Operation and storage errors expose a **Review Issues…** button in the footer,
with selectable details in a popover; long messages do not expand the controls.

The top of the window and menu shows **All enabled**, **Partially enabled**, **Off**, or **Status unknown**, together with the number of confirmed enabled settings out of ten (the nine common settings plus the selected window-focus mode). The unselected focus mode is excluded from this count. This reflects observed settings, independently of the saved Monk Mode session. Unknown and unavailable settings are counted separately and never count as confirmed enabled. The summary stays visible during background work. A small activity indicator appears in a fixed space in the window only if work lasts longer than half a second. The menu bar uses a monochrome template icon of a monk in the lotus pose, adapting to light and dark menu bars.

Known external changes update observed status without altering saved profiles or
restore baselines. Opening the menu/window, returning to the app and **Refresh**
provide another read when macOS delivers no notification, including some
wallpaper changes. Instant detection of every external change is not guaranteed.

## Grayscale intensity

The grayscale slider is available in the window and **directly below the
grayscale checkbox in the menu bar menu**. It shows the current percentage while
dragging and applies once on release. Both controls share the same value, default
to **50%**, and store the preference locally. The menu slider is disabled when
grayscale is off; the window slider can still save a preferred amount for the next
enable. Use the window slider for keyboard adjustment.

Controls stay available during routine reads and changes; permission, storage
errors and unknown/unavailable filter state still block unsafe changes. Each
slider release queues its chosen intensity. 0% is the lowest supported filter
intensity; switch the checkbox off to remove the filter completely. While
grayscale is on, refresh reads its current intensity from macOS without replacing
an active drag or a newer queued value.

## Window Focus

**Window Focus** has two mutually exclusive checkboxes: **Show windows one at a time** and **Dim background windows**. Enabling one disables the other after both original states have been saved. Turning both off retains the last enabled choice for the next Monk Mode session; the choice survives a restart. The initial choice is One window at a time, preserving existing behavior. A failed selected mode is reported and does not silently select the other one.

Enabling **Show windows one at a time** also enables **Stage Manager** and
**Hide recent apps**. Disabling the checkbox or switching to **Dim background
windows** turns Stage Manager off so windows from other apps become visible,
even if Stage Manager was already on before that focus cycle. Recent-apps
visibility returns to its saved state. **Restore All** and session restoration
can still recover the exact original Stage Manager setting. Existing journals
remain readable. Failed shutdowns retain their restore records for retry; they
are not reported as successful. If a prerequisite cannot be enabled, the previous
focus mode is left unchanged and the error is reported.

Background dimming has its own **0–90%** slider in the window and directly below its native menu checkbox, defaulting to 50%. It is independent of grayscale. Both sliders are disabled until background dimming is enabled. Dimming at 0% draws no layer. The overlay does not intercept mouse or keyboard input and has no blur or animation. One reusable window per connected display is positioned below the focused window; windows above that layer, such as floating palettes and menus, remain visible.

The effect pauses when the active window cannot be identified unambiguously, ordering fails, or one-window mode is enabled externally. Accessibility loss hides the layer and stops tracking when detected at the next focus/refresh event. Settings changed outside MonkShift are rechecked on those events or with Refresh; there is no repeating check. Unsupported/ambiguous windows remain undimmed. The implementation uses only normal-level windows and matches public window metadata by process and frame; exact matches between overlapping same-sized windows are deliberately not guessed. Mission Control, full-screen transitions and Stage Manager animation behavior still require live validation.

Dimming stops on exit or crash because the windows belong to MonkShift. Its enabled preference is retained and resumes on reopening once permission and an eligible active window are available. Original enabled state and intensity remain in the restore journal until successfully restored. The preferred slider value is stored separately from the temporary runtime intensity restored with a session.

For dimming's window classification and ordering, see
[Architecture](ARCHITECTURE.md#background-dimming). Live compatibility and
resource measurements are covered in [Testing](TESTING.md#background-dimming-manual-checks).

## Desktop visibility and Reduce Motion

**Hide desktop icons and widgets** is one checkbox in the window's **Display**
group and in the menu. It is on only when icons and widgets are configured to be
hidden in both desktop modes. Mixed configurations show an explanation. Monk Mode
captures all four settings before hiding them, and disabling Monk Mode or using
Restore All restores the exact saved configuration. Older sessions without this
feature's snapshot leave its settings untouched. Files and widget placements are
preserved. This uses macOS's native visibility settings: clicking the desktop can
temporarily reveal hidden items, as described in Apple's
[Stage Manager guide](https://support.apple.com/en-gb/guide/mac-help/mchl534ba392/15.0/mac/15.0).
The widget preference keys are also used by
[WidgetToggler](https://github.com/sieren/WidgetToggler#toggling-widgets-from-cli).

Reduce Motion has its own checkbox in the window's **Display** group and in the
menu. Monk Mode saves its current state before enabling it. Disabling Monk Mode
restores that state, including an originally enabled setting. Existing sessions
created before Reduce Motion was added restore only their saved settings; they
leave Reduce Motion untouched unless it was subsequently captured. The setting
affects system and app motion preferences, including browsers' reduced-motion
behavior; it does not remove every animation. See Apple's
[Reduce Motion API documentation](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion).

## Restoration and local data

**Monk Mode (Enable Selected Settings)** first captures every available setting, including both focus-mode baselines and writes the restore file atomically before making changes. It then applies the common supported settings and only the last selected focus mode. Failures appear individually; an error does not count as successful application.

**Disable Monk Mode** restores exactly the saved state from immediately before that session, including prior filter type/enabled state/intensity and wallpaper URL/options. Quitting keeps the current system settings and the restore record; the transient dimming layer disappears until the next launch. Opening MonkShift again lets you disable/restore the saved session.

Individual checkbox changes also save their first baseline. Unchecking restores that feature's saved configuration and ensures the feature is off. **Restore All Changes** restores the Monk session first, then the earlier individual baselines. This means a previously enabled system feature can be restored to enabled. Individual edits during a Monk session do not replace the session baseline.

If restoration fails, the corresponding record stays on disk for retry. For a disconnected display, reconnect it and retry **Restore All Changes**. An unreadable/corrupted restore file blocks modifications rather than replacing the file. A missing file on a first launch is normal.

Local data:

```text
~/Library/Application Support/MonkShift/restore.json
~/Library/Application Support/MonkShift/profiles.json
~/Library/Application Support/MonkShift/black.png
```

Shortcuts, the preferred focus mode, dimming enabled state and both preferred slider positions live in the app's UserDefaults domain `app.monkshift.MonkShift`. Wallpaper restoration is limited to saved connected displays and their current desktop Space. Other Spaces, rotating wallpaper schedules, live/video wallpaper state, and displays attached after a snapshot are not managed. Keep original wallpaper files available until restoration. Independent system-setting edits made during a Monk session are overwritten when restoring that session, as expected from restoring its saved baseline.

Queued changes finish before Quit exits; see the
[operation lifecycle](ARCHITECTURE.md#restoration-and-operation-lifecycle).

## Settings profiles

The **Profile** dropdown in the window and the **Profile** submenu in the menu
bar select and immediately apply a saved configuration. On first use, **Default**
captures the current readable settings, both preferred intensities and the focus
mode choice without changing macOS. Unknown or unavailable settings are omitted
from that initial capture. **New Profile…** copies the selected profile and asks
for a unique name. Successful checkbox changes and preferred intensity changes
are saved automatically to the active profile. Global keyboard shortcuts are
shared across profiles.

Profile switches use the same serialized queue as individual controls. All target
settings are saved for restoration before the first mutation, and later switches
retain those original baselines. One-window profiles also enable Stage Manager
and preserve an explicitly saved **Hide recent apps** choice. When that choice
is absent, recent apps are hidden by default. Unavailable settings saved as off
are skipped unless a focus transition needs to change them; required snapshots
must still be saved before any mutation. Errors remain visible and a failed profile can be selected
again to retry. **Restore All** restores the pre-change state without erasing
saved profiles. Profiles selected inside a Monk session preserve that session's
baseline; the Monk Mode button retains its existing enable-all/restore behavior.

Profiles and the selected profile survive restart. Starting MonkShift reads the
current system state without automatically applying a saved profile. Settings
changed externally or by restoration do not overwrite profiles. Invalid profile
files are preserved and reported; restoration remains available independently.

## Global shortcuts

See the [default bindings](../README.md#global-shortcuts).

Click **Shortcuts…** and then **Edit…** to choose modifiers and a letter. The app validates duplicates and OS registration errors, retaining the previous working shortcut on a failed edit. Keys use physical ANSI positions so the same combination works across input languages. As with other Carbon shortcuts, secure input/system-reserved combinations may prevent delivery. Shortcuts work while MonkShift is running, even with its window closed or menu bar auto-hidden.

The focus shortcuts toggle their respective mode through the same queue,
permission checks and restoration flow as the window and menu controls. Existing
custom bindings are preserved. If a new default conflicts with a saved binding,
the new action uses Shift with its default letter, or another free letter.

## Apple Shortcuts

A standard build exposes three actions in the macOS **Shortcuts** app. Create a
shortcut, search for **MonkShift**, and add one of these actions:

| Action | Behavior |
| --- | --- |
| Toggle Monk Mode | Enable when there is no saved session; otherwise restore that session. |
| Enable Monk Mode | Apply Monk Mode; repeated runs preserve the original session baseline. |
| Disable Monk Mode | Restore the saved session. With no session, leave settings unchanged. |

For a keyboard toggle, add **Toggle Monk Mode** to a shortcut and assign a keyboard
shortcut in its details. These actions open MonkShift when needed. They use the
same queue and restore journal as the app's controls, wait for their operation
and read-back to finish, and report permission, storage, partial-apply and restore
errors to Shortcuts. Retrying **Disable Monk Mode** restores any remaining failed
records. Disable restores the saved baseline; settings that were enabled before
the session can remain enabled afterward.

Install the final bundle in `/Applications`, open it once and grant Automation
permission before using these actions. Automation consent is requested through
onboarding; normal app startup can also ask for Accessibility when it is missing. Builds made with `--without-app-shortcuts` omit the discovery
metadata and do not expose these actions. See Apple's
[App Shortcuts documentation](https://developer.apple.com/documentation/appintents/app-shortcuts).

## Compatibility

**Compatibility:** Dock, Stage Manager and desktop visibility preference keys, Reduce Motion setters and the color filter symbols are not stable public configuration APIs. Their actual visual effects require manual checks on each supported macOS version. Checkboxes read system preferences/API state, not screen pixels. A preference read-back confirms the stored value; it cannot prove the corresponding daemon rendered the effect. Missing symbols, failed writes and unknown states are shown explicitly. No SIP changes or administrator privileges are used.
