# Architecture

[README](../README.md) · [Development](DEVELOPMENT.md) · [Testing](TESTING.md)

The dependency-free core owns settings orchestration and restoration through
`SettingsBackend`; macOS integrations live in `Sources/MonkShift/System/`.

## Permissions and process lifecycle

Dock/menu-bar control sends typed Apple Events against System Events'
preferences dictionary. Requests have a five-second timeout and run on a serial
background queue. Preferences and color-filter operations run on a background
actor; AppKit wallpaper/UI access stays on the main actor. Global shortcuts use
Carbon registration.

Privacy state is checked before every mutation. Revocation blocks later actions
and preserves restore records. See the [permission guide](USER_GUIDE.md#permissions)
for consent, Accessibility and regranting access.

Only one MonkShift process may access a user's saved settings at a time. A file
lock is acquired before opening the restore journal or installing shortcuts. A
second launch asks the running instance to show its window and exits. The OS
releases the lock on exit or a crash; an old PID file alone cannot block startup.

## Settings adapters

| Setting | Implementation and scope |
| --- | --- |
| Instant Dock | `com.apple.dock` → `autohide-delay = 0`, `autohide-time-modifier = 0`; Dock reloads after applying the group. |
| Hide Dock | System Events → `autohide of dock preferences`. Auto-hides; reveal by moving to its screen edge. |
| Hide menu bar | System Events → `autohide menu bar of dock preferences`. Auto-hides; reveal by moving to the top edge. |
| Stage Manager | `com.apple.WindowManager` → `GloballyEnabled`. Requires “Displays have separate Spaces”; if disabled, MonkShift explains the prerequisite. |
| Hide recent apps | `com.apple.WindowManager` → `AutoHide = true`. Only affects Stage Manager while it is enabled. |
| One window at a time | `com.apple.WindowManager` → `AppWindowGroupingBehavior = 0`; disabling selects `1` (all windows). `2` is also a single-window mode. Automatically enables Stage Manager and Hide recent apps, saving both earlier states. Exiting focus stops Stage Manager and restores recent-app visibility; Restore All retains the original Stage Manager baseline. Mutually exclusive with background dimming. |
| Dim background windows | Native, click-through AppKit windows ordered immediately below the active normal-level window. Menus retain the last window's dimming; a new document window becomes the anchor. AX/Workspace and native menu notifications identify focus; no screen capture, private window API, helper or polling. Independent 0–90% intensity. |
| Hide desktop icons and widgets | `com.apple.WindowManager` → `StandardHideDesktopIcons`, `HideDesktop`, `StandardHideWidgets`, and `StageManagerHideWidgets` set to `1`. Hides both types of items on the desktop and in Stage Manager without restarting Finder. All four original values, including absent keys, are saved for restoration. |
| Reduce Motion | System Accessibility → Display → Reduce Motion, through dynamically resolved `_AXInterfaceGetReduceMotionEnabled` / `_AXInterfaceSetReduceMotionEnabled`. Included in Monk Mode and restored to its saved enabled/disabled state. |
| Black wallpaper | An 8 × 8 opaque black PNG generated locally, applied through `NSWorkspace` to each connected display in the current desktop Space. |
| Grayscale | System display color filter category 1, type 1, through dynamically resolved `MADisplayFilterPref*` APIs and the system Universal Access daemon. |

The grayscale slider normalizes the native exported minimum/maximum intensity
range to 0–100% (on the development Mac, native 0.25–1.0). Its 0% represents the
lowest supported filter intensity; disabling the filter removes it completely.

Grouping values were verified against the native
`WindowManager.AppWindowGroupingBehavior` enum on macOS 15.8.1. Missing or
unsupported values report Unknown instead of being coerced to a Boolean. Saved
snapshots preserve exact values, types and absent keys. The one-window checkbox
is off whenever Stage Manager is off. Dimming checks for an
active single-window mode only while Stage Manager is enabled.

**Compatibility:** Dock, Stage Manager and desktop visibility preference keys, Reduce Motion setters and the color filter symbols are not stable public configuration APIs. Their actual visual effects require manual checks on each supported macOS version. Checkboxes read system preferences/API state, not screen pixels. A preference read-back confirms the stored value; it cannot prove the corresponding daemon rendered the effect. Missing symbols, failed writes and unknown states are shown explicitly. No SIP changes or administrator privileges are used.

## Observed status

Every setting has a checkbox in the window and in the native menu bar menu.
Status is refreshed when opening the menu/window, returning to MonkShift and
after applying settings. Known Dock, menu bar, Stage Manager and desktop
visibility preferences are observed through KVO, including updates from other
processes. Public Accessibility display, Space, display configuration and wake
notifications also trigger a complete read. App switches provide another read
while the controls window or menu is visible.

Event bursts share one delayed read. Events received during a mutation, read or
slider drag remain pending until it is safe to refresh. External changes update
observed checkboxes and active intensities without saving them into a profile or
replacing restore snapshots. There is no repeating background polling. Event
delivery depends on macOS and the preference involved; changes without a
notification, including some wallpaper changes, appear on the next opening,
activation or **Refresh**. This does not promise instant detection of every
external system change. See Apple's [UserDefaults observation documentation](https://developer.apple.com/documentation/foundation/userdefaults/didchangenotification).

## Restoration and operation lifecycle

**Monk Mode (Enable Selected Settings)** first captures every available setting, including both focus-mode baselines and writes the restore file atomically before making changes. It then applies the common supported settings and only the last selected focus mode. Failures appear individually; an error does not count as successful application.

Changes run in a sequential queue. Checkboxes immediately show the requested
value, while the summary counts only confirmed macOS state. Further clicks and
slider releases remain available and execute in order after any current read or
change. Failed changes return to the observed value and retain their error and
restore record. Automation permission is checked before each queued change;
revocation cancels the remaining queue. Native menu items and the slider update
in place. Snapshots still reach durable storage before the first OS change, and
a failed finalization retains the relevant restore records. **Quit MonkShift**
stays active with the same appearance during changes. If clicked while changes
are pending, it finishes accepted changes before exiting and accepts no new ones.

Profile switches use this same queue and save all target settings before the
first mutation. Later switches retain original restore baselines. See
[profile behavior](USER_GUIDE.md#settings-profiles) and
[local data](USER_GUIDE.md#restoration-and-local-data).

## Background dimming

After reordering, a bounded deferred validation waits for WindowServer to publish the new layer (up to three checks, 40 ms apart). This is only triggered by an actual layer change; there is no repeating background timer. Stale validations are cancelled on focus changes or disable. Decorative overlays are excluded from Accessibility, and their own window-created/main-window notifications are not observed.

Ordinary app/window activation reuses the visible layer and reorders it directly
under the replacement window. An unresolved focus change has a one-shot 150 ms
handoff deadline. A confirmed, still-visible window can remain the anchor during
temporary loss of Accessibility focus in the same app or while a menu bar utility
takes focus. The window's ownership and visibility are checked before reuse.

Opening, closing or switching menus preserves the chosen dimming intensity below
the last document window, with menus above it. Repeated clicks do not discard the
confirmed window history when a temporary Accessibility reply is inconclusive.
Floating panels, popovers and accessory-app windows without a native close control
do not replace that anchor, even if they have the same WindowServer level as a
document window. Classification runs before geometry and WindowServer matching,
so a newly opened utility panel can retain the document even while its metadata
is unpublished or its frame is incomplete. Closable settings windows can become
the new anchor. Closing or minimizing the anchor, Space/display changes and wake
discard it. Permission loss,
conflicting one-window mode and disabling dimming remove the effect. There is no
animation, extra transition layer or idle polling. See the
[manual checks](TESTING.md#background-dimming-manual-checks) for remaining live compatibility
and resource measurements.

The effect pauses when the active window cannot be identified unambiguously, ordering fails, or one-window mode is enabled externally. Accessibility loss hides the layer and stops tracking when detected at the next focus/refresh event. Settings changed outside MonkShift are rechecked on those events or with Refresh; there is no repeating check. Unsupported/ambiguous windows remain undimmed. The implementation uses only normal-level windows and matches public window metadata by process and frame; exact matches between overlapping same-sized windows are deliberately not guessed. Mission Control, full-screen transitions and Stage Manager animation behavior still require live validation.

Dimming stops on exit or crash because the windows belong to MonkShift. Its enabled preference is retained and resumes on reopening once permission and an eligible active window are available. Original enabled state and intensity remain in the restore journal until successfully restored. The preferred slider value is stored separately from the temporary runtime intensity restored with a session.

## Resource design

The idle process retains one small model, native NSStatusItem/NSMenu, and Carbon shortcut registrations. Closing the window releases its SwiftUI hosting tree. There are no repeated timers, live previews, third-party frameworks, web views or helper daemons. While dimming is enabled, the app additionally retains AX/Workspace subscriptions and one reusable overlay per connected display. Disabling dimming releases its observers and windows. Move/resize events are not observed: the underlay does not need to follow window geometry. AX focus/geometry reads use a background actor with bounded messaging timeouts and coalesced requests. macOS system processes such as Dock and universalaccessd are managed by macOS, not resident MonkShift helpers.

Performance claims require release-build measurements of MonkShift and the
compositing work charged to system processes. See
[resource measurements](TESTING.md#resource-measurements).

## Source references

- [Apple: Stage Manager behavior and prerequisites](https://support.apple.com/en-ie/guide/mac-help/mchl534ba392/mac).
- [Apple: Automation permission API](https://developer.apple.com/documentation/coreservices/3025784-aedeterminepermissiontoautomate).
- [Apple: display color filters](https://support.apple.com/en-ie/guide/mac-help/mchl11ddd4b3/mac).
- [Apple: custom views in menu items](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MenuList/Articles/ViewsInMenuItems.html).
- API signatures/category/type and notification behavior were cross-checked against [brettferdosi/grayscale's API notes](https://github.com/brettferdosi/grayscale/blob/master/Sources/Bridge.h), system SDK exports and read-only runtime probes. No third-party runtime code is linked.
