# Sleep Window Layout Restore Spec

## Context

macOS can wake external displays one at a time after laptop sleep. During that gap, the window server may resize and relocate windows onto the first available display, then leave them scrambled after the remaining displays return. DeskBar already has Accessibility permission, display-scoped window tracking, and taskbar frame adjustment logic, so it is a reasonable place to remember the last stable visible layout and restore it after wake.

## Goal

Restore normal desktop windows to their last known pre-sleep display and frame when the same display topology becomes available again after wake.

## Non-Goals

- Do not restore true full-screen windows or full-screen Spaces.
- Do not move windows from inactive Spaces in the first implementation.
- Do not create a general-purpose layout profile manager.
- Do not override user window moves made after wake once DeskBar has already attempted a restore.

## User Experience

DeskBar captures the visible window layout when the system is about to sleep or the screens are about to sleep. After wake, DeskBar waits for the previously captured displays to return and for screen-configuration changes to settle. If the captured topology is available, DeskBar restores eligible windows automatically.

The DeskBar status menu gets one manual fallback command:

`Restore Windows From Last Sleep`

The command is enabled when a pre-sleep snapshot exists. It runs the same restore path as the automatic wake restore, but reports skipped windows in the console instead of silently ignoring them.

No always-visible taskbar button is added. A status-menu command keeps the taskbar surface focused on launching and switching windows.

## Snapshot Timing

DeskBar creates a snapshot on:

- `NSWorkspace.willSleepNotification`
- `NSWorkspace.screensDidSleepNotification`
- The final debounced display-configuration state immediately before sleep, when available

Only the newest snapshot is retained. It is stored in memory and persisted to:

`~/Library/Application Support/DeskBar/window-layout-last-sleep.json`

Persistence lets the manual restore command survive a DeskBar restart after wake.

## Display Identity

Each display in the snapshot records:

- `CGDirectDisplayID`
- `CGDisplayCreateUUIDFromDisplayID` value when available
- Pixel bounds from `CGDisplayBounds`
- Backing scale factor
- Resolution
- Whether it was the main display

Restore maps old displays to current displays by UUID first. If UUID matching is unavailable, it falls back to a unique resolution-and-scale match. If a captured display cannot be mapped uniquely, windows from that display are skipped.

## Window Identity

Each captured window records:

- DeskBar canonical identity: `pid` and `cgWindowID` when available
- Bundle identifier
- App name
- Window title
- Owning display identity
- Absolute frame
- Frame relative to the owning display bounds
- Minimized, hidden, and AX full-screen state
- Capture timestamp

Restore finds a live window in this order:

1. Same `pid` and `cgWindowID`
2. Same bundle identifier and title
3. Same bundle identifier with only one eligible live window

If no live match is found, the window is skipped.

## Eligibility

A window is captured and restored only when all of these are true:

- The owning app has `.regular` activation policy.
- The window passes DeskBar's existing standard-window eligibility rules.
- The window is visible on the current Space and belongs to a DeskBar-managed display.
- The window is not true full-screen (`AXFullScreen != true`).
- Accessibility permission is granted.

Minimized and hidden windows may be captured for diagnostics, but automatic restore does not unminimize or unhide them. Manual restore also leaves their minimized or hidden state unchanged.

## Restore Timing

After `NSWorkspace.didWakeNotification`, DeskBar enters a pending restore state for up to 60 seconds.

During that window it listens for:

- `NSApplication.didChangeScreenParametersNotification`
- CG display reconfiguration callbacks
- DeskBar panel rebuild events

Each display-change event restarts a 2-second debounce timer. When the debounce fires, DeskBar checks whether all snapshot displays can be mapped to current displays. If they can, DeskBar performs one automatic restore and exits pending state. If the displays never return within 60 seconds, automatic restore is abandoned but the manual menu command remains available.

## Restore Algorithm

For each eligible captured window:

1. Resolve the current display for the captured display identity.
2. Resolve the live AX window using the matching rules above.
3. Skip if the live window is full-screen, minimized, hidden, or no longer standard.
4. Convert the captured relative frame onto the current display bounds.
5. Clamp the frame inside the current display bounds while preserving the captured size when possible.
6. Apply `kAXPositionAttribute` and `kAXSizeAttribute`.
7. Let DeskBar's existing taskbar-avoidance pass trim any system-filled window above the taskbar if needed.

The restore operation should batch AX writes on the main queue and avoid activating applications.

## User-Change Protection

Automatic restore runs only once per wake cycle. It does not retry after the first restore attempt unless the user invokes the manual command.

If a live window's frame already matches its captured frame within 4 points, DeskBar skips it. If a live window was created after the snapshot timestamp, DeskBar skips it.

Manual restore is explicit and may move any live eligible window that matches the snapshot.

## Failure Modes

- No Accessibility permission: skip restore and leave the manual command disabled with a console message.
- Display topology differs: keep snapshot, skip automatic restore, leave manual command enabled.
- App or window closed: skip that window.
- Ambiguous display or window match: skip rather than guessing.
- AX write failure: log the app/window identity and continue with remaining windows.

## Implementation Plan

Add `WindowLayoutSnapshotManager` under `Sources/DeskBar/Services/`.

Responsibilities:

- Observe sleep, wake, and display-change notifications.
- Capture display and window snapshots using existing `WindowManager`, `ScreenGeometry`, and `AccessibilityService` helpers.
- Persist and load the latest snapshot.
- Determine when a post-wake display topology is stable.
- Restore live AX windows from the latest snapshot.

Add a status-menu item in `AppDelegate`:

- Title: `Restore Windows From Last Sleep`
- Enabled when `WindowLayoutSnapshotManager` has a usable snapshot
- Action: manual restore from the latest snapshot

Add focused tests for:

- Display identity mapping by UUID and unique fallback.
- Relative-frame conversion across equivalent display bounds.
- Window matching priority.
- Eligibility filtering for full-screen, minimized, hidden, and non-standard windows.
- Pending wake restore timeout/debounce behavior with injectable clocks.

## Acceptance Criteria

- With two external displays visible, put Chrome/Finder windows on both displays, sleep the laptop, wake with one display appearing before the other, and confirm windows return to their captured displays and frames after both displays are back.
- If only one captured display returns, DeskBar does not move windows automatically.
- Manual `Restore Windows From Last Sleep` restores the latest snapshot after the displays are available.
- Full-screen windows and full-screen Spaces are not moved.
- Minimized and hidden windows are not unminimized or unhidden.
- DeskBar does not activate apps while restoring.
- `swift test` passes.

## Ticket Classification

Single ticket. One agent can implement the snapshot manager, status-menu command, and focused tests without splitting the work into an epic.
