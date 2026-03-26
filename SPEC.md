# DeskBar: Native macOS Taskbar

## Context

Taskbar.app (bundle ID `com.fpfxtknjju.wbgcdolfev`) was disabling macOS system keyboard shortcuts (Cmd+Tab, Cmd+Space, Mission Control) on every boot by writing `enabled = 0` to keys 15-26 in `com.apple.symbolichotkeys.plist`. See `~/Documents/taskbar.md` for the full investigation.

Rather than work around a buggy third-party app with a suspicious bundle ID, we're building our own. The goal: a Windows-style taskbar for macOS that does NOT touch system shortcuts.

## Requirements

- **Framework:** Swift / AppKit (pure native, no Electron)
- **Build system:** Swift Package Manager (no Xcode required)
- **Min deployment:** macOS 14.0
- **Position:** Bottom edge of screen, full width (see Dock Coexistence for interaction with the macOS Dock)
- **Bundle ID:** `com.deskbar.app`

## Features

### Must Have (Phases 1-6)
1. Persistent bottom bar showing running application windows on the current Space/monitor
2. Click a task to activate/bring that window to front
3. Real-time updates as windows open, close, minimize, change title
4. App icons + window titles on each task button
5. Active window highlighting
6. Minimized/hidden window visual indicators (greyed out, brackets/parens)
7. Right-click context menu (Close, Minimize, Hide)
8. Thumbnails on hover (via ScreenCaptureKit)
9. Pinned launcher zone (leftmost) — quick-launch frequently used apps, always visible
10. Running-app tray (rightmost) — icons for running apps with no visible windows in the current context
11. Blacklist (hide specific apps from taskbar)

### Should Have (Phase 5, 7)
12. Preferences window (General, Appearance, Behavior, Launcher, Blacklist tabs)
13. Window grouping by app (optional toggle)
14. Drag-and-drop task reordering
15. Middle-click to close window
16. Launchpad button
17. Notification badge dots (best-effort)

### Nice to Have (Phase 8)
18. Start at login (via LaunchAgent)
19. Option to auto-hide macOS Dock
20. Multi-monitor support (taskbar on all screens, each scoped to its own display)
21. Configurable taskbar height, font size, max task width

## Non-Requirements

- **MUST NOT modify `com.apple.symbolichotkeys`** -- this is what broke the original Taskbar.app
- No Dock icon (LSUIElement = true, accessory app)
- No external dependencies -- system frameworks only

---

## Architecture

### Project Structure

```
~/automation/taskbar/
  Package.swift
  SPEC.md                            # This file
  CLAUDE.md                          # Build/test/lint instructions

  Sources/DeskBar/
    App/
      main.swift                     # Bootstrap NSApp, set .accessory policy, run
      AppDelegate.swift              # App lifecycle, create panel, init services
      PermissionsManager.swift       # Check/request Accessibility + Screen Recording

    Models/
      WindowInfo.swift               # Data model for a tracked window
      AppGroup.swift                 # Grouped windows by app
      TaskbarSettings.swift          # Observable settings backed by UserDefaults
      PinnedApp.swift                # Pinned application model

    Services/
      WindowManager.swift            # Central coordinator: authoritative window list
      AccessibilityService.swift     # AXUIElement: enumerate, raise, minimize, close
      WorkspaceMonitor.swift         # NSWorkspace notification observer
      AXObserverManager.swift        # Per-app AXObserver lifecycle
      ThumbnailService.swift         # ScreenCaptureKit thumbnail capture
      DockManager.swift              # Show/hide macOS Dock
      LoginItemManager.swift         # LaunchAgent management for start-at-login
      BadgeMonitor.swift             # Best-effort notification badge detection
      BlacklistManager.swift         # Manage hidden apps

    Views/
      TaskbarPanel.swift             # NSPanel: the taskbar window itself
      TaskbarContentView.swift       # Three-zone horizontal layout container
      LauncherZoneView.swift         # Left zone: pinned app launchers
      LauncherButtonView.swift       # Individual launcher icon
      TaskZoneView.swift             # Middle zone: window-level task buttons
      TaskButtonView.swift           # Individual task (icon + title + interactions)
      RunningAppTrayView.swift       # Right zone: backgrounded app icons
      TrayIconView.swift             # Individual tray icon
      LaunchpadButtonView.swift      # Launchpad launcher button
      ThumbnailPopover.swift         # NSPopover for hover thumbnail preview
      SettingsWindowController.swift # Preferences window controller
      SettingsView.swift             # Preferences UI content

    Utilities/
      CGWindowExtensions.swift       # Helpers for CGWindowListCopyWindowInfo
      NSImageExtensions.swift        # Icon scaling, badge overlay
      ScreenGeometry.swift           # Screen math, taskbar positioning
      Debouncer.swift                # Coalesce rapid update events

  Resources/
    AppIcon.icns                     # App icon (generate later)

  scripts/
    build.sh                         # swift build + package into .app bundle
    package.sh                       # Assemble .app bundle structure
    Info.plist.template              # Plist with placeholders

  Tests/DeskBarTests/
    WindowManagerTests.swift
    TaskbarSettingsTests.swift
    BlacklistManagerTests.swift
```

### Key Architectural Decisions

**NSPanel with `.nonactivatingPanel`** -- Clicks on the taskbar must not steal focus from the target app. NSPanel with this style mask is non-negotiable.

**Window level: `.statusBar` (25)** -- Above normal windows and the Dock, below system alerts. Always visible.

**Panel configuration:**
```swift
level = .statusBar
styleMask = [.borderless, .nonactivatingPanel]
collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
// .fullScreenAuxiliary added only when "Show over full-screen apps" is enabled — see Spaces and Full-Screen Behavior
isFloatingPanel = true
hidesOnDeactivate = false
backgroundColor = .clear  // vibrancy via NSVisualEffectView
```

**AXObserver + polling fallback** -- AXObserver provides real-time window change notifications per-app. A 2-second CGWindowList poll catches edge cases from non-AX-compliant apps.

**ScreenCaptureKit for thumbnails** -- `CGWindowListCreateImage` is deprecated in macOS 15. Use `SCScreenshotManager.captureSampleBuffer` (macOS 14+).

**No screen space reservation** -- macOS has no public API for this. Mitigation: high window level ensures visibility; optional Dock hiding frees its reserved space.

**Pure AppKit UI** -- SwiftUI cannot expose NSPanel's non-activating behavior. Hover tracking, middle-click, and drag-and-drop all need direct NSView control.

**LaunchAgent for login item** -- SPM + ad-hoc signing means `SMAppService` won't work reliably. Write a plist to `~/Library/LaunchAgents/`.

### Window Identity Model

A window must be tracked consistently across four APIs that each identify it differently. This section defines the canonical identity, eligibility rules, and cross-API matching strategy.

**Canonical identity.** Each promoted (authoritative) window is keyed by `(pid: pid_t, cgWindowID: CGWindowID)`. The `CGWindowID` is the stable numeric identifier that bridges all four APIs. Windows that have not yet been assigned a CGWindowID are tracked separately under a provisional key — see Two-tier storage below.

**Private API dependency: `_AXUIElementGetWindow`.** The CGWindowID is obtained from an `AXUIElement` by calling `_AXUIElementGetWindow()`, a private SPI in the ApplicationServices framework. This is not a public API. We rely on it because there is no public equivalent, and it has been stable since macOS 10.9. Every major macOS window manager (yabai, Amethyst, Spectacle, Hammerspoon, Rectangle) depends on it. The symbol is loaded at runtime via `dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow")` and its availability is checked at launch.

**Fallback when `_AXUIElementGetWindow` is unavailable.** If the symbol cannot be resolved (e.g., a future macOS removes it), DeskBar falls back to a heuristic match: for each AXUIElement window, read its `kAXPositionAttribute` and `kAXSizeAttribute`, then match against the `kCGWindowBounds` from `CGWindowListCopyWindowInfo` for the same pid. A position+size match within 2px tolerance on the same pid is treated as the same window. This fallback is lossy — two identically-sized windows from the same app at the same position will collide — but it keeps the app functional until a proper fix is shipped. A console warning is logged at launch: "DeskBar: _AXUIElementGetWindow unavailable, using frame-matching fallback. Thumbnail accuracy may be reduced."

**Eligibility rules.** A window is eligible for display in the taskbar when ALL of the following hold:

1. The owning process has `NSApplication.ActivationPolicy.regular` (visible in Dock under normal circumstances)
2. `kCGWindowLayer == 0` (normal window layer — excludes menus, status bars, system overlays)
3. `kCGWindowAlpha > 0` (not fully transparent)
4. Bounds width × height ≥ 100 px (excludes zero-size helper windows)
5. The window's AX role is `kAXWindowRole` with subrole `kAXStandardWindowSubrole` or `kAXDialogSubrole` (excludes sheets, drawers, popovers, floating utility panels)
6. The owning app's bundle ID is not in the user's blacklist

**Example.** Safari with two tabs open and a Downloads popover: the two main browser windows pass all six checks. The Downloads popover has subrole `kAXFloatingWindowSubrole` and is excluded by rule 5.

**Cross-API matching.**

| Source | Identifier | Join path |
|--------|-----------|-----------|
| AXUIElement | AXUIElement ref | `_AXUIElementGetWindow(axRef)` → CGWindowID |
| CGWindowListCopyWindowInfo | `kCGWindowNumber` | Direct CGWindowID |
| ScreenCaptureKit | `SCWindow.windowID` | Direct CGWindowID |
| NSWorkspace | `NSRunningApplication.processIdentifier` | pid → filter AX/CG results |

**Two-tier storage: authoritative and provisional.** WindowManager maintains two dictionaries:

1. `authoritative: [CGWindowID: WindowInfo]` — windows with a confirmed CGWindowID. This is the primary data store. Cross-API matching, thumbnails, and deduplication all operate on this dict.
2. `provisional: [ProvisionalID: WindowInfo]` — windows discovered by AXObserver that have no CGWindowID yet. `ProvisionalID` is a struct containing `(pid: pid_t, axElement: AXUIElement)` and is compared by AXUIElement equality.

When AXObserver reports a new window, `_AXUIElementGetWindow` is called immediately. If it returns a valid CGWindowID, the window goes directly into `authoritative`. If it returns an error or zero (the window server occasionally lags a frame behind AX), the window enters `provisional` with a 500ms promotion timer.

**Promotion and merge.** Every 100ms during the 500ms window, `_AXUIElementGetWindow` is retried. The moment a valid CGWindowID is obtained, the entry moves from `provisional` to `authoritative`, keyed by the real CGWindowID. If 500ms elapses with no CGWindowID, the entry stays in `provisional` indefinitely (until the window closes or a CGWindowID appears on a later poll cycle).

**Rendering provisional windows.** Provisional entries ARE rendered in the taskbar — the user should see a window appear immediately, not after a 500ms delay. However, provisional windows have these limitations:
- No thumbnail capture (ScreenCaptureKit requires a CGWindowID)
- No cross-API deduplication guarantee (a matching CGWindowList entry could theoretically create a brief duplicate until promotion merges them)
- The tooltip shows "(syncing...)" after the window title as a subtle indicator

When a provisional entry is promoted, the corresponding TaskButtonView updates in place — no visual flicker.

**Deduplication.** For `authoritative` entries, CGWindowID uniqueness guarantees no duplicates. For `provisional` entries, dedup is by `(pid, AXUIElement)` identity. The promotion step checks whether the newly obtained CGWindowID already exists in `authoritative` (e.g., from a CGWindowList poll that raced ahead). If so, the provisional entry is silently discarded and the authoritative entry is kept.

**Space and monitor scoping — local visibility.** Each DeskBar panel shows only the windows that belong to its current desktop (Space) and monitor. Windows on other Spaces or other monitors are not displayed.

**Filtering rule.** `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)` returns only windows on the currently visible Space(s). For each window, its `kCGWindowBounds` determines which display it belongs to (the display whose `CGDisplayBounds` contains the window's origin). A panel on Display N shows only windows whose bounds fall within Display N's region.

**Single-monitor behavior.** When "Show on all monitors" is disabled (the default), a single panel on the main display shows only windows on the main display's current Space. Switching Spaces causes the task list to update immediately — windows from the old Space disappear, windows from the new Space appear.

**Multi-monitor behavior.** When "Show on all monitors" is enabled, each display gets its own panel. Each panel shows only the windows on that display. A window moved from Display 1 to Display 2 disappears from Display 1's panel and appears on Display 2's panel.

**Space-switch updates.** `NSWorkspace.activeSpaceDidChangeNotification` fires when the user switches Spaces. On this event, WindowManager re-queries `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, ...)` and rebuilds the task list for each panel. The 2-second polling fallback also catches any missed transitions.

**Launcher Zone and local visibility.** Launcher pins always appear regardless of whether the app has windows on the current Space/monitor. If a launcher app is running but all its windows are on a different Space or monitor, the launcher slot shows the dot indicator (running, no local windows). Clicking it activates the app, which may cause macOS to switch Spaces to where its windows are — this is standard macOS behavior, not something DeskBar controls.

### Accessibility Permission Handling

DeskBar's core features depend on Accessibility (AX) permission. This section defines behavior across the full permission lifecycle: not-yet-granted, denied, granted, and revoked-while-running.

**Permission check on launch.** `AppDelegate` calls `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: false])` — a non-prompting check. If `false`, DeskBar enters degraded mode immediately and shows the grant flow (below). It does NOT use the `prompt: true` variant because that shows a system dialog that the user might dismiss without understanding why it matters.

**Grant flow.** When AX is unavailable, the taskbar displays a persistent banner at the top of the panel: a full-width amber strip reading "Accessibility permission required — Click to grant". The banner is NOT dismissible — it remains visible until permission is granted, because DeskBar is severely limited without AX and the user should be reminded. Below the banner, the three-zone layout still renders in degraded form (see below). Clicking anywhere on the banner opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. A 5-second `DispatchSource.makeTimerSource` polls `AXIsProcessTrusted()` and transitions to full mode the moment permission is detected, at which point the banner is removed and all three zones rebuild with full functionality.

**Degraded mode — three-zone behavior.** Without AX, per-window enumeration is unavailable. Each zone adapts:

| Zone | Degraded behavior |
|------|-------------------|
| **Launcher Zone** | Fully functional. Pinned launchers still appear. Running state is detected via `NSWorkspace.runningApplications`. Appearance states (not running / running with dot / running with underline) still work, and the underline vs. dot distinction uses `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, ...)`: if the app has at least one on-screen window on this display, it shows the underline indicator and also appears in the Task Zone; if it has no on-screen windows, it shows the dot indicator and does NOT appear in the Task Zone. Note: without AX, minimized windows are not distinguishable from absent windows in CGWindowList (both are off-screen), so a launcher app with only minimized local windows will show the dot indicator in degraded mode — a minor imprecision accepted for the no-AX fallback. Click behavior: not-running launches the app; running activates via `NSRunningApplication.activate()`. |
| **Task Zone** | Collapses from per-window buttons to per-app buttons. Each running `.regular`-policy app with at least one on-screen window on this display (per `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, ...)`) gets one app-level button (icon + app name, no window title). This includes launcher apps that have on-screen windows — they appear in both the Launcher Zone and the Task Zone, matching the full-mode dual-representation rule. |
| **Running-App Tray** | Still populated. Apps running with no on-screen windows (per CGWindowList) that are not represented in the Launcher Zone appear here. The tray is populated from `NSWorkspace.runningApplications` minus apps visible in the Task Zone, minus apps in the Launcher Zone. |

**Degraded mode interaction contract:**

| Action | Behavior |
|--------|----------|
| Left-click Task Zone app button | `NSRunningApplication.activate(options: .activateAllWindows)` — brings all app windows forward. Cannot target a specific window. |
| Right-click Task Zone app button | Context menu shows only: "Quit" (calls `terminate()`). Close/Minimize/Hide are omitted because they require AX. |
| Hover Task Zone app button | No thumbnail. Tooltip shows app name only. |
| Active app highlighting | Still works in Task Zone: `NSWorkspace.shared.frontmostApplication` identifies the active app, and the corresponding button gets the highlight style. |
| Minimized/hidden indicators | Not available — there is no way to detect per-window minimize/hide state without AX. All Task Zone buttons appear in normal style. |
| Running-App Tray interactions | Same as full mode: left-click activates, right-click shows Quit/Hide/Pin to Launcher. |

**Degraded mode dedup rule:** Same as full mode. A Launcher Zone app with on-screen windows appears in both the Launcher Zone (underline indicator) and the Task Zone (app-level button). A Launcher Zone app with no on-screen windows appears only in the Launcher Zone (dot indicator). All other apps appear in exactly one of the Task Zone or the tray, never both.

**Revocation while running.** AX permission can be revoked in System Settings without quitting DeskBar. The 5-second poll detects revocation and transitions back to degraded mode: per-window Task Zone buttons collapse to app-level buttons, the banner reappears, and all AX-dependent features disable. The Launcher Zone and Running-App Tray remain but lose AX-dependent precision. In-flight AX calls will return `kAXErrorAPIDisabled`; all AX call sites must handle this error by returning `nil`/empty rather than crashing.

### Dock Coexistence

The macOS Dock and DeskBar both target the screen edge. This section defines how they coexist and how DeskBar safely manages Dock visibility.

**Primary usage scenario.** The user's typical setup is Dock on the left edge with autohide enabled, and DeskBar at the bottom edge. In this configuration, the Dock and DeskBar occupy different edges and do not overlap. DeskBar spans the full screen width at the bottom. When the Dock auto-reveals on the left edge, it overlaps the leftmost portion of the taskbar — this is acceptable because the Dock reveal is transient and the user is interacting with the Dock at that moment, not the taskbar. No special handling is needed.

**Three modes.** The setting "Dock mode" (stored as `dockMode` in UserDefaults) determines how DeskBar interacts with the Dock:

| Mode | Dock state | DeskBar position | Default? |
|------|-----------|-----------------|----------|
| `independent` | Unchanged (user manages Dock separately) | Bottom edge of screen, full width | Yes |
| `autoHide` | `autohide = true` | Bottom edge of screen | No |
| `hidden` | `autohide = true` + `autohide-delay = 1000` | Bottom edge of screen | No |

**Default mode: `independent`.** DeskBar does not modify Dock settings. DeskBar always positions at the bottom edge of the screen: `x = screen.frame.origin.x`, `y = screen.frame.origin.y`, `width = screen.frame.width`, `height = taskbarHeight`. The Dock's position (left, right, or bottom) and visibility are entirely the user's choice. In this mode, DeskBar never writes to `com.apple.dock` defaults — zero risk.

**Dock on left or right (the typical case).** When the Dock is on the left or right edge, DeskBar occupies the full bottom edge with no adjustment. The Dock's `visibleFrame` inset is irrelevant because the Dock and taskbar are on different edges. If the Dock auto-reveals, it temporarily overlaps the taskbar edge — this is the same behavior as any window overlapping the Dock's reveal area.

**Dock on bottom.** When the Dock is also on the bottom edge, DeskBar's `.statusBar` window level places it above the Dock. If the Dock is visible (not auto-hidden), the taskbar floats above it. If the user wants to avoid this stacking, they can switch to `autoHide` or `hidden` mode, or move their Dock to the left/right edge.

**Mode: `autoHide`.** DeskBar executes `defaults write com.apple.dock autohide -bool true && killall Dock`. Before doing so, it reads the current `autohide` value and writes the prior state to `~/.config/deskbar/dock-prior-state.json`:
```json
{"autohide": false, "autohide-delay": 0, "timestamp": "2026-03-26T..."}
```

**Mode: `hidden`.** Same as `autoHide`, plus sets `autohide-delay` to 1000 (effectively invisible). Prior state file captures original `autohide-delay` value.

**Dock restore — defense in depth.** This section applies only to `autoHide` and `hidden` modes, which mutate `com.apple.dock` defaults. In `independent` mode (the default), DeskBar never writes to Dock preferences and no restore logic is needed.

When the user switches to `autoHide` or `hidden` mode, DeskBar writes the prior state file before mutating. Restoration must survive normal quit, crash, force-quit, and login restart:

1. **Normal quit:** `applicationWillTerminate` reads `dock-prior-state.json` and restores. Deletes the state file on success.
2. **SIGTERM/SIGINT:** Signal handlers (via `DispatchSource.makeSignalSource`) trigger the same restore logic.
3. **Crash / force-quit:** A companion LaunchAgent (`com.deskbar.dock-watchdog.plist`) runs a 30-second interval shell script: if `dock-prior-state.json` exists and DeskBar is not running (`pgrep -x DeskBar` fails), it restores the Dock and deletes the state file.
4. **Login restart:** The same LaunchAgent fires on login, catches the case where DeskBar crashed before a reboot.

The watchdog LaunchAgent is installed when the user first switches to `autoHide` or `hidden` mode, and removed when Dock mode is set back to `independent`. In `independent` mode, no watchdog is running and no state file exists.

### Task Model Rules

The taskbar is divided into three zones, separated by subtle vertical dividers. Each zone has distinct content, ordering rules, and interaction behavior.

**Three-zone layout:**

```
[  Launcher Zone  |  Task Zone  |  Running-App Tray  ]
     (left)           (middle)         (right)
```

#### Launcher Zone (leftmost)

Pinned app launchers in user-defined order. This zone is always visible — it does not change when the user switches Spaces or monitors. It provides quick access to frequently launched apps, similar to the left side of the Windows 11 taskbar.

**Content:** Each launcher slot shows an app icon (no window title — these are app-level, not window-level). The user configures launchers via right-click "Pin to Launcher" on any task button, or via the Settings > Launcher tab.

**Appearance states:**
- **Not running:** Greyed-out icon. Click launches the app.
- **Running, with visible windows on this Space/monitor:** Icon with an underline indicator (a small colored bar below the icon, matching system accent color). Click activates the most recent window. Right-click shows window list for quick switching.
- **Running, no visible windows on this Space/monitor:** Icon with a subtle dot indicator (smaller than the underline — indicates the app is alive but has no local windows). Click activates the app, which may switch Spaces to where its windows are.

**Ordering:** User-defined, persisted to UserDefaults. Drag-reorderable within the zone.

#### Task Zone (middle)

Window-level task buttons for the current Space/monitor. This is the primary working area of the taskbar.

**Content:** One button per eligible window (see Window Identity Model eligibility rules), filtered to the current Space and monitor (see Space and monitor scoping). Each button shows app icon + window title.

**Minimized and hidden window rules.** Whether minimized/hidden windows appear in the Task Zone or cause the app to move to the tray depends on whether the app has ANY visible (non-minimized, non-hidden) local windows:

- **Mixed state (some visible, some minimized/hidden):** The visible windows appear as normal Task Zone buttons. The minimized/hidden windows ALSO appear as Task Zone buttons with visual indicators:
  - **Minimized:** Greyed-out icon, title in brackets: `[Document.txt]`. Click unminimizes and activates.
  - **Hidden (app hidden via Cmd+H):** Semi-transparent icon, title in parens: `(Document.txt)`. Click unhides the app and activates.
- **All-minimized / all-hidden:** When ALL of an app's local windows are minimized or hidden, the app has no usable windows in the current context. The per-window buttons are removed from the Task Zone. Where the app appears next depends on whether it is launcher-pinned:
  - **Launcher-pinned app:** Stays in the Launcher Zone only, switching from underline to dot indicator. Does NOT appear in the tray (see No duplicate representation).
  - **Non-launcher app:** Moves to the Running-App Tray. Clicking the tray icon activates the app, which unminimizes/unhides its windows.

**Ordering:** Most-recently-activated order (newest left). When a window is activated, it moves to the leftmost position.

**State table (with grouping):**

| Windows | Grouping | Display |
|---------|----------|---------|
| 1 window from app | Either | Single window button. |
| N>1 windows from app | Off | N individual window buttons in MRU order. |
| N>1 windows from app | On | Single group button with app icon + count badge. Click expands inline. |

**Group expansion.** When a group button is clicked, it expands inline (pushes neighbors aside) to show individual window buttons. A second click or clicking outside collapses it. While expanded, individual windows can be activated, closed, or minimized normally.

#### Running-App Tray (rightmost)

Icons for running apps that have no visible windows in the current Space/monitor context. This fills the role the macOS Dock serves for backgrounded apps — the user can always see what's running even if those apps have no windows here.

**An app appears in the tray when ALL of the following are true:**
1. The app is running (present in `NSWorkspace.runningApplications` with `.regular` activation policy)
2. The app has no usable windows on the current Space/monitor. This means: no windows at all, all windows are on other Spaces/monitors, OR all local windows are minimized/hidden (no visible local window remains). An app with at least one visible local window does NOT appear in the tray — its minimized/hidden siblings stay in the Task Zone as indicator buttons.
3. The app is not blacklisted
4. The app is not already represented in the Launcher Zone (a launcher pin with a dot indicator already covers this case — no double representation)

**Appearance:** Smaller icons than the Task Zone (24pt vs 32pt default), tightly packed, no window titles. Similar to macOS Dock icons. A subtle separator divides the tray from the Task Zone.

**Interactions:**
- **Left-click:** `NSRunningApplication.activate(options: .activateAllWindows)`. If the app has windows on another Space, macOS switches to that Space. If the app has no windows at all (e.g., a menu-bar-only app that also has `.regular` policy, or an app where the user closed all windows), clicking activates the app which typically opens a new window.
- **Right-click:** Context menu with "Quit", "Hide", and "Pin to Launcher". No Close/Minimize since there are no local windows to act on.
- **Hover:** Tooltip shows app name. No thumbnail (no local window to capture).

**Ordering:** Alphabetical by app name. Not drag-reorderable (this zone is informational, not a workspace organizer).

**Transitions.**
- **Tray → Task Zone:** When a tray app opens or receives a visible window on the current Space/monitor, it moves from the tray to the Task Zone.
- **Task Zone → Tray (non-launcher apps):** When a non-launcher app's last local window is closed, moved to another Space/monitor, or minimized/hidden (leaving zero visible local windows), all its buttons disappear from the Task Zone and the app moves to the tray — unless the app quits entirely.
- **Task Zone → Launcher dot (launcher apps):** When a launcher app's last visible local window is closed, moved, or minimized/hidden, its per-window buttons leave the Task Zone and the Launcher Zone icon switches from underline to dot indicator. The app does NOT appear in the tray.
- **Partial minimize (mixed state):** When one of several windows is minimized but others remain visible, the minimized window stays in the Task Zone with a greyed/bracket indicator. No tray transition occurs.
- **Unminimize from tray:** Clicking a tray icon for an all-minimized app activates the app, which brings its windows back. The app transitions from tray to Task Zone.

#### No duplicate representation

An app must appear in at most one zone at a time, with one exception:

- A **Launcher Zone** app that is running with visible local windows appears in BOTH the Launcher Zone (with underline indicator) AND the Task Zone (per-window buttons). This is intentional — the launcher is a persistent shortcut, the task buttons are the working windows.
- A **Launcher Zone** app that is running with NO visible local windows appears ONLY in the Launcher Zone (with dot indicator). It does NOT also appear in the tray.
- A **non-launched** running app appears ONLY in the tray (or only in the Task Zone if it has local windows — never both).

#### Drag-reorder scope

1. **Launcher Zone:** Drag-reorderable. Order is persisted.
2. **Task Zone, grouping on:** Group buttons can be reordered. Order is ephemeral (see precedence rule below).
3. **Task Zone, grouping off:** Individual window buttons can be reordered. Also ephemeral.
4. **Running-App Tray:** Not drag-reorderable.
5. **Cross-zone drag is NOT allowed.** Use right-click "Pin to Launcher" to move an app to the launcher zone. Attempting a cross-zone drag snaps the item back.

#### Drag vs. MRU precedence in the Task Zone

When the user manually drags a window or group to a new position in the Task Zone, that item gets a `userPositioned` flag. The precedence rules:

- **User-positioned items hold their rank.** Subsequent activate/focus events do NOT move a `userPositioned` item. It stays where the user put it until the window closes or the app quits, at which point the flag is discarded.
- **Non-positioned items reorder by MRU among themselves.** When a non-positioned window is activated, it moves to the leftmost available slot among non-positioned items — but it does not leapfrog user-positioned items.
- **New windows insert at the left of the non-positioned region.** A newly opened window appears at the leftmost position that is not occupied by a user-positioned item.
- **The flag is ephemeral.** `userPositioned` is not persisted across restarts. On relaunch, the Task Zone resets to pure MRU ordering.

Example: the Task Zone has [Chrome-1, Terminal, Safari] in MRU order. The user drags Terminal to the rightmost position. Now [Chrome-1, Safari, Terminal*]. The user then activates Safari — the non-positioned items reorder by MRU: [Safari, Chrome-1, Terminal*]. Terminal stays put because it has `userPositioned`.

### Spaces and Full-Screen Behavior

**Cross-Space presence.** DeskBar uses `.canJoinAllSpaces` and `.stationary` in its `collectionBehavior`. This is intentional and non-negotiable — a taskbar that disappears when the user switches Spaces defeats its purpose. This is the Windows taskbar model: always present, regardless of virtual desktop.

**Full-screen apps.** By default, DeskBar hides its panel on any display that has a full-screen window, regardless of whether that app is frontmost. The reasoning: full-screen is an intentional "I want all the pixels" gesture (video, presentations, games), and a persistent bar covering the bottom edge violates that intent.

**Full-screen detection — display-scoped scan.** The detection algorithm must find full-screen windows on ANY display, not just for the frontmost app. A user may have a full-screen video on Display 1 while actively working in a windowed app on Display 2 — Display 1's panel must stay hidden even though the full-screen app is not frontmost.

Detection runs on two triggers:
1. **Event-driven:** `NSWorkspace.didActivateApplicationNotification` (app switch), `NSWorkspace.activeSpaceDidChangeNotification` (Space switch).
2. **Polling fallback:** Every 2 seconds (piggybacking on the existing CGWindowList poll), re-scan all displays. This catches full-screen transitions that don't fire workspace notifications (e.g., a video player entering full-screen via its own UI).

**Per-display scan algorithm.** On each trigger, for each display that has a DeskBar panel:

1. Get the display's bounds via `CGDisplayBounds(displayID)`.
2. *With AX:* Iterate all running `.regular`-policy apps. For each app, query AX windows and check `kAXFullScreenAttribute`. If any AX window reports full-screen and its `kAXPositionAttribute`/`kAXSizeAttribute` place it on this display, mark this display as full-screen-occupied.
3. *Without AX (degraded mode):* Use `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)`. For each entry with `kCGWindowLayer == 0`, compare `kCGWindowBounds` to the display's `CGDisplayBounds`. A match within 2px tolerance on all four edges (accounting for the menu bar: the window may start at y=0 or y=25) indicates full-screen. This heuristic can false-positive on a maximized non-full-screen window, but that edge case is acceptable — a momentary panel hide when a window is maximized to exact screen bounds is a minor UX glitch, not a correctness failure.
4. If display is full-screen-occupied, `panel.orderOut(nil)`. Otherwise, `panel.orderFront(nil)`.

**Per-monitor hide/show behavior.** Each panel independently decides its visibility based on its own display's scan result. If Display 1 has a full-screen app and Display 2 does not, only Display 1's panel hides. When "Show on all monitors" is disabled (single panel on main display), only the main display is scanned.

**Setting: "Show over full-screen apps"** (default: `false`). When enabled, DeskBar re-adds `.fullScreenAuxiliary` to `collectionBehavior` and skips the runtime hide/show logic entirely. This is for users who want the taskbar always visible, even over full-screen content. The authoritative panel configuration in Key Architectural Decisions reflects the default (`.fullScreenAuxiliary` absent).

### Data Flow

```
WorkspaceMonitor (app launch/terminate/activate/hide/Space-switch)
       |
       v
WindowManager  <--- AXObserverManager (window create/destroy/title/minimize/hide)
  (central)    <--- CGWindowList poll (2s fallback, Space/monitor filter)
       |       <--- BlacklistManager (filter)
       |       <--- LauncherPins list
       |
       v  (per Space/monitor: visible + minimized/hidden windows, running apps)
TaskbarContentView
  |-- LauncherZoneView -----> LauncherButtonView (per pinned app, always present)
  |-- TaskZoneView ----------> TaskButtonView (per window: visible, minimized, or hidden)
  |                            [full mode: per-window | degraded mode: per-app]
  |-- RunningAppTrayView ----> TrayIconView (per app with no usable local windows)
```

### Feature-to-API Mapping

| Feature | API |
|---|---|
| List running apps | `NSWorkspace.shared.runningApplications` (filter `.regular` policy) |
| List windows per app | `AXUIElement` + `kAXWindowsAttribute` |
| Window titles | `AXUIElement` + `kAXTitleAttribute` |
| App icons | `NSRunningApplication.icon` |
| Activate window | `NSRunningApplication.activate()` + `AXUIElement kAXRaiseAction` |
| Minimize window | `AXUIElement` + `kAXMinimizedAttribute` |
| Close window | `AXUIElement` + `kAXCloseButtonAttribute` + `kAXPressAction` |
| Detect window changes | `AXObserver` notifications |
| Detect app launch/quit | `NSWorkspace` notifications |
| Thumbnails | `SCScreenshotManager.captureSampleBuffer` |
| Dark/light mode | `NSVisualEffectView` auto-adapts |
| Multi-monitor | `NSScreen.screens` + `didChangeScreenParametersNotification` |
| Settings persistence | `UserDefaults(suiteName: "com.deskbar.app")` |
| Start at login | Write LaunchAgent plist to `~/Library/LaunchAgents/` |
| Open Launchpad | `NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))` |
| Hide Dock | `defaults write com.apple.dock autohide` + `killall Dock` |
| Drag reorder | `NSDraggingSource` / `NSDraggingDestination` |
| Hover detection | `NSTrackingArea` with `.mouseEnteredAndExited` |
| Middle-click | `otherMouseDown(with:)` where `event.buttonNumber == 2` |

---

## Implementation Phases

### Phase 1: Foundation (Get something on screen)

Create: `Package.swift`, `main.swift`, `AppDelegate.swift`, `TaskbarPanel.swift`, `TaskbarContentView.swift`, `WindowManager.swift`, `WindowInfo.swift`

- Bootstrap NSApp as accessory app
- Create borderless NSPanel at bottom of screen with NSVisualEffectView
- Query `NSWorkspace.runningApplications` for GUI apps
- Display app icons in a horizontal row
- Build with `swift build`

**Milestone:** `swift run` shows a floating bar at the bottom with app icons.

### Phase 2: Window Switching + Real-Time Updates

Create: `AccessibilityService.swift`, `PermissionsManager.swift`, `WorkspaceMonitor.swift`, `AXObserverManager.swift`, `TaskButtonView.swift`, `Debouncer.swift`

- Implement Accessibility permission lifecycle (see Accessibility Permission Handling): check on launch, grant flow with persistent banner, degraded mode, revocation detection
- AXUIElement window enumeration per app
- Window identity: `_AXUIElementGetWindow` via `dlsym`, with frame-matching fallback if unavailable (see Window Identity Model)
- Two-tier storage: authoritative `[CGWindowID: WindowInfo]` dict + provisional dict with 500ms promotion timer (see Two-tier storage)
- Left-click activates window (raise + activate)
- NSWorkspace notification observer for app launch/terminate
- AXObserver per app for window create/destroy/title/minimize
- Debounce rapid events (100ms window)

**Milestone:** Clicking a task switches to that window. New windows appear, closed windows disappear in real time.

### Phase 3: Visual Polish

Modify: `TaskButtonView.swift`, `TaskbarContentView.swift`. Create: `ScreenGeometry.swift`, `NSImageExtensions.swift`, `CGWindowExtensions.swift`

- Active window highlight (different background)
- Minimized/hidden indicators in Task Zone (mixed state): greyed out + `[title]` for minimized, semi-transparent + `(title)` for hidden. See Task Model Rules > Task Zone for mixed vs. all-minimized behavior.
- All-minimized/all-hidden transition: non-launcher apps move from Task Zone to Running-App Tray; launcher-pinned apps leave Task Zone and switch to dot indicator in Launcher Zone (no tray entry).
- Right-click context menu: Close, Minimize, Hide
- Proper multi-screen positioning math
- Icon scaling helpers

**Milestone:** Polished native appearance with proper state indicators.

### Phase 4: Thumbnails on Hover

Create: `ThumbnailService.swift`, `ThumbnailPopover.swift`

- NSTrackingArea on TaskButtonView for mouse enter/exit
- Configurable hover delay timer
- ScreenCaptureKit thumbnail capture
- NSPopover displaying thumbnail above the button
- Graceful fallback if Screen Recording permission denied

**Milestone:** Hovering over a task for 400ms shows a live window thumbnail.

### Phase 5: Settings and Preferences

Create: `TaskbarSettings.swift`, `SettingsWindowController.swift`, `SettingsView.swift`

- UserDefaults-backed settings model
- Menu bar status item (gear icon) to open Settings
- Tabbed preferences window: General, Appearance, Behavior, Launcher, Blacklist
- All settings wired to relevant components

Settings table:

| Setting | Default |
|---|---|
| Show Launchpad button | true |
| Taskbar height | 40pt |
| Title font size | 12pt |
| Max task width | 200pt |
| Show titles | true |
| Group by app | false |
| Drag reorder | true |
| Middle-click closes | true |
| Thumbnail size | 200pt |
| Hover delay | 400ms |
| Dock mode | `independent` (options: `independent`, `autoHide`, `hidden`) |
| Show over full-screen apps | false |
| Start at login | false |
| Show on all monitors | false |

**Milestone:** All settings configurable and persistent.

### Phase 6: Launcher Zone, Running-App Tray, + Blacklist

Create: `PinnedApp.swift`, `BlacklistManager.swift`, `RunningAppTrayView.swift`

- Launcher Zone (leftmost): pin/unpin via right-click "Pin to Launcher", persisted via UserDefaults, three appearance states (not running, running with local windows, running with no local windows). See Task Model Rules > Launcher Zone.
- Running-App Tray (rightmost): icons for running apps with no visible windows in current context. Alphabetical order, smaller icons, no titles. See Task Model Rules > Running-App Tray.
- Transitions: non-launcher apps move between Task Zone and tray as windows appear/disappear on current Space/monitor. Launcher-pinned apps transition between underline (visible local windows, Task Zone buttons present) and dot indicator (no visible local windows, Task Zone buttons removed) without entering the tray.
- "Add to Blacklist" in right-click context menu
- Blacklist management UI in Settings
- Blacklisted apps filtered from WindowManager

**Milestone:** Three-zone layout working: launcher pins, task windows, and running-app tray all populated correctly.

### Phase 7: Advanced Interactions

Create: `AppGroup.swift`, `BadgeMonitor.swift`

- Window grouping by app (expandable groups showing count)
- Drag-and-drop reordering with zone rules (see Drag-reorder scope): left zone persisted, right zone ephemeral, cross-zone blocked
- `userPositioned` flag for drag vs. MRU precedence in live zone (see Drag vs. MRU precedence)
- Middle-click to close
- Best-effort badge dot detection
- Badge dot overlay on task buttons

**Milestone:** All advanced interaction features working.

### Phase 8: System Integration + Packaging

Create: `LoginItemManager.swift`, `DockManager.swift`, `LaunchpadButtonView.swift`, `scripts/build.sh`, `scripts/package.sh`, `Info.plist.template`

- LaunchAgent plist for start-at-login
- Dock coexistence: three-mode DockManager (`independent`/`autoHide`/`hidden`), prior-state persistence to `~/.config/deskbar/dock-prior-state.json`, defense-in-depth restore (applicationWillTerminate, SIGTERM/SIGINT handlers, companion watchdog LaunchAgent). See Dock Coexistence section.
- Launchpad button widget
- Multi-monitor: taskbar panel per screen, each panel scoped to its own display's windows. Display-scoped full-screen scan hides only the affected panel. See Spaces and Full-Screen Behavior.
- App bundle packaging script
- Ad-hoc codesign

**Milestone:** Fully packaged `.app` bundle, installable replacement for Taskbar.app.

---

## Verification

### Happy path

1. `swift build` compiles without errors
2. `swift run` launches the taskbar at screen bottom
3. All running GUI app windows appear as tasks
4. Clicking a task activates that window
5. Opening/closing windows updates the taskbar in real time
6. Thumbnails appear on hover (after granting Screen Recording permission)
7. Settings persist across restarts
8. Pinned apps and blacklist work correctly
9. `scripts/build.sh` produces a working `DeskBar.app` bundle
10. **Cmd+Tab, Cmd+Space, and all system shortcuts continue to work**

### Accessibility permission lifecycle

11. **AX denied on launch:** DeskBar shows the non-dismissible amber banner and app-level buttons. Left-clicking an app button activates the app (all windows). Right-click shows only "Quit". No thumbnails shown.
12. **AX granted while running:** After granting permission in System Settings, the banner disappears within 5 seconds and the task list rebuilds with per-window buttons.
13. **AX revoked while running:** After revoking permission in System Settings, within 5 seconds the task list collapses to app-level buttons and the banner reappears. No crash.
14. **Active app highlighting in degraded mode:** The frontmost app's button is highlighted even without AX.

### Dock coexistence and crash restore

15. **Typical setup (Dock left, autohide on):** DeskBar occupies full bottom edge. Dock auto-reveals on left without affecting taskbar positioning. No overlap issues.
16. **Independent mode (default):** DeskBar does not modify Dock settings. No state file exists, no watchdog runs.
17. **Dock on bottom, visible:** DeskBar floats above the Dock at `.statusBar` level. Both are usable.
18. **autoHide mode switch:** Switching to `autoHide` writes `dock-prior-state.json` before mutating Dock state. Dock auto-hides. DeskBar at bottom edge.
19. **Normal quit restore:** Quitting DeskBar in `autoHide` or `hidden` mode restores the Dock to its prior state and deletes the state file.
20. **Crash restore:** Force-kill DeskBar while in `autoHide`/`hidden` mode. The watchdog LaunchAgent restores the Dock within 30 seconds.

### Window identity and local visibility

21. **`_AXUIElementGetWindow` available:** Windows are keyed by CGWindowID in the authoritative dict. No duplicates across AX/CG/ScreenCaptureKit.
22. **`_AXUIElementGetWindow` unavailable:** Console warning is logged. Frame-matching fallback activates. Windows are still displayed (with reduced thumbnail accuracy).
23. **Provisional window lifecycle:** A new window discovered by AXObserver appears immediately in the taskbar (even before CGWindowID is obtained). Once promoted, the button updates in place — no flicker. If CGWindowList poll discovers the same window first, the provisional entry is silently discarded on promotion (no duplicate).
24. **Local Space visibility:** Only windows on the current Space appear in the Task Zone. Switching Spaces updates the task list immediately — old Space windows disappear, new Space windows appear.
25. **Local monitor visibility (multi-monitor):** Each panel shows only windows on its own display. Moving a window from Display 1 to Display 2 removes it from Display 1's panel and adds it to Display 2's panel.

### Full-screen per-monitor hide/show

26. **Single monitor, full-screen app:** DeskBar panel hides. Exiting full-screen re-shows the panel.
27. **Multi-monitor, full-screen on one display:** Only the panel on the full-screen display hides. The other display's panel remains visible.
28. **Background full-screen:** A full-screen video plays on Display 1 while the user works in a windowed app on Display 2. Display 1's panel stays hidden (the 2-second poll catches this even though the full-screen app is not frontmost).
29. **"Show over full-screen apps" enabled:** Panel remains visible over full-screen content on all displays.

### Three-zone layout and task model

30. **Launcher Zone — not running:** Pinned launcher icon appears greyed. Click launches the app.
31. **Launcher Zone — running with local windows:** Icon shows underline indicator. Click activates most recent window.
32. **Launcher Zone — running, no local windows:** Icon shows dot indicator. Click activates app (may switch Spaces).
33. **Task Zone — local windows only:** Only windows on the current Space/monitor appear. No windows from other Spaces/monitors.
34. **Running-App Tray — populated correctly:** An app running with no visible local windows appears in the tray. An app with visible local windows does NOT appear in the tray.
35. **Running-App Tray — launcher dedup:** A launcher-pinned app with no local windows shows a dot indicator in the Launcher Zone and does NOT appear in the tray.
36. **Tray-to-Task transition:** Opening a window for a tray app on the current Space removes it from the tray and adds a window button to the Task Zone.
37. **Task-to-Tray transition:** Closing the last visible local window for a non-launcher app moves it from the Task Zone to the tray (if still running).
38. **Drag vs. MRU precedence:** Manually dragging a Task Zone window holds its position through subsequent activate events. Non-positioned windows reorder around it. The flag clears on window close or app quit.
39. **Group expansion:** Clicking a group button expands inline. Individual windows within are activatable, closeable, minimizable. Second click or click-outside collapses.

---

## Review History

8 review rounds between spec-owner and spec-reviewer. Converged from an initial happy-path-only spec to a fully contracted design document.

### Round 1 — 3 blocking, 2 important

**Dock integration underspecified.** The spec said "bottom of screen" and "no screen space reservation" with "Hide macOS Dock" defaulting to false, leaving the Dock and taskbar fighting for the same edge with no defined resolution. **Fix:** Added a Dock Coexistence section with three modes (`aboveDock`/`autoHide`/`hidden`), positioning math using `visibleFrame`, and a defense-in-depth Dock restore mechanism (state file + signal handlers + watchdog LaunchAgent).

**Missing Accessibility-denied behavior.** The spec said "check/prompt for permission" but never defined what happens when the user denies or revokes AX. Every core feature depends on AX. **Fix:** Added a full permission lifecycle section: non-prompting check on launch, grant flow with persistent banner, degraded mode with app-level fallback, and 5-second polling for grant/revoke detection at runtime.

**Window identity and filtering rules missing.** WindowManager was supposed to reconcile four APIs (AX, CGWindowList, ScreenCaptureKit, NSWorkspace) but the spec never defined a canonical window ID, eligibility rules, or cross-API matching. **Fix:** Added a Window Identity Model with `(pid, CGWindowID)` as canonical key, six eligibility rules, and a cross-API join table.

**Task model ambiguous with pinned apps + grouping.** The UI was window-based but pinned items were app-based, with no rules for what appears when a pinned app is running with multiple windows. **Fix:** Added an explicit state table covering all pinned/running/grouping combinations, a no-duplication invariant, and zone-based ordering rules.

**Full-screen / Spaces behavior hard-coded.** `.canJoinAllSpaces` + `.fullScreenAuxiliary` was an implementation detail with user-visible downsides for video/games/presentations, presented without acknowledging the tradeoff. **Fix:** Kept `.canJoinAllSpaces` (non-negotiable for a taskbar), replaced `.fullScreenAuxiliary` with runtime full-screen detection, added a configurable "Show over full-screen apps" setting.

### Round 2 — sharpening contracts

**Position requirement contradicted default behavior.** "Bottom of screen, full width" conflicted with the new `aboveDock` mode that offsets upward. **Fix:** Reconciled the requirement line to reference Dock Coexistence.

**Left/right Dock not handled.** Positioning math only covered a bottom Dock. **Fix:** Added `visibleFrame`-based handling that auto-adapts to any Dock position.

**`_AXUIElementGetWindow` not called out as private API.** The spec relied on a private SPI without saying so or defining a fallback. **Fix:** Explicitly documented it as a private API loaded via `dlsym`, added a frame-matching heuristic fallback with documented limitations.

**Space scoping undefined.** The spec never said whether each Space shows only its own windows or all windows across Spaces. **Fix:** Added Space scoping section (initially all-Spaces; later changed to local-only per user requirement).

**Degraded-mode interaction contract vague.** "One button per app" without specifying what each click/right-click/hover does. **Fix:** Added exact interaction table for every action in degraded mode.

**Drag vs MRU precedence ambiguous.** Both MRU reordering and drag reordering applied to the live zone with no rule for which wins. **Fix:** Added `userPositioned` flag — dragged items hold rank, MRU reorders around them.

### Round 3 — internal consistency

**Provisional windows contradicted canonical identity.** The authoritative store was `[CGWindowID: WindowInfo]` but the spec also said windows without a CGWindowID are shown. **Fix:** Defined two-tier storage (authoritative + provisional dicts), explicit promotion/merge behavior, and rendering rules for provisional windows.

**Full-screen detection missed background full-screen.** The algorithm only checked the frontmost app, missing a full-screen video on Display 1 while working on Display 2. **Fix:** Replaced frontmost-app heuristic with a per-display scan that checks all windows on each display, running on both workspace notifications and a 2-second poll.

**Verification section stale.** Only 10 happy-path items covering none of the new contracts. **Fix:** Expanded to 30+ items covering AX lifecycle, Dock restore, window identity, full-screen hide/show, and task model invariants.

### Round 4 — consistency + user requirements

**Full-screen summary out of sync with algorithm.** Summary said "hides when a full-screen app is in the foreground" but the algorithm was display-scoped and frontmost-agnostic. **Fix:** Reworded to "hides its panel on any display that has a full-screen window, regardless of whether that app is frontmost."

**Implementation phases stale.** Phases still described the original lighter-weight work, not the new Dock watchdog, provisional window lifecycle, or display-scoped scanning. **Fix:** Updated Phase 2, 7, and 8 bullets to reference the actual spec contracts.

**Canonical identity overstated.** "Each tracked window is keyed by (pid, cgWindowID)" was no longer literally true with provisional windows. **Fix:** Narrowed to "Each promoted (authoritative) window."

**User requirement: local visibility.** User wanted each desktop/monitor to show only its own windows, not all Spaces. **Fix:** Replaced all-Spaces model with local Space/monitor scoping using `kCGWindowListOptionOnScreenOnly` filter. Removed off-Space badge/click-to-switch behavior.

**User requirement: three-zone layout.** User wanted a pinned launcher on the left and running-app icons on the right. **Fix:** Replaced two-zone model (pinned/live) with three zones: Launcher Zone (leftmost, app-level launchers), Task Zone (middle, per-window buttons), Running-App Tray (rightmost, backgrounded apps). Defined dedup rules, transitions, and interactions for each zone.

**User requirement: primary usage scenario.** User's typical setup is Dock-left with autohide. **Fix:** Elevated from edge case to primary scenario. Renamed default Dock mode from `aboveDock` to `independent`. Simplified positioning to always use full screen bottom edge.

### Round 5 — three-zone alignment

**Degraded mode out of sync with three-zone model.** AX-denied behavior still described generic "one button per app" without mapping to the three zones. **Fix:** Defined explicit degraded behavior for each zone: Launcher Zone fully functional, Task Zone collapses to per-app buttons using CGWindowList, Running-App Tray still populated.

**Minimized/hidden behavior contradicted tray rules.** Must-have feature said minimized windows get visual indicators in the Task Zone, but the tray rule said apps move to the tray when all windows are minimized. **Fix:** Split into two cases: mixed state (some visible, some minimized) keeps indicators in Task Zone; all-minimized moves app to tray.

**Settings tabs inconsistent with launcher feature.** Launcher Zone referenced a "Settings > Launcher tab" that didn't exist in the preferences spec. **Fix:** Added Launcher tab to the preferences window definition.

### Round 6 — user requirement + dedup

**All-minimized rule didn't match user requirement.** Previous fix kept minimized windows in Task Zone, but user explicitly asked for right-side tray icons for apps that are "minimized everywhere." **Fix:** Reversed: all-minimized apps move to tray, matching user's stated requirement. Per-window indicators only appear in the mixed case.

**Degraded mode dedup contradicted Task Zone rule.** Task Zone said "apps NOT in the Launcher Zone" but dedup rule said launcher apps appear in both. **Fix:** Made Task Zone rule include launcher apps with on-screen windows, consistent with the dedup exception.

**Data Flow diagram stale.** Still said "per visible window" but Task Zone now includes minimized/hidden windows and degraded mode uses per-app buttons. **Fix:** Updated diagram to show full model including minimized/hidden state and degraded mode annotation.

### Round 7 — launcher edge cases

**All-minimized rule inconsistent for launcher-pinned apps.** Task Zone said "app moves to tray" but dedup rules said launcher apps never enter the tray. **Fix:** Scoped the all-minimized rule: launcher-pinned apps switch to dot indicator in Launcher Zone; non-launcher apps move to tray. Updated Transitions section with separate bullets for each path.

**Degraded-mode launcher indicator contradicted CGWindowList-based rules.** "Any running launcher app shows underline" conflicted with the Task Zone rule that uses CGWindowList to determine on-screen status. **Fix:** Degraded launcher indicator now uses CGWindowList: on-screen windows → underline + Task Zone button; no on-screen windows → dot only. Documented accepted imprecision for minimized windows.

**Not-running launcher appearance inconsistent.** Launcher Zone said "Normal icon" but Verification said "greyed." **Fix:** Changed to greyed-out, matching the convention used throughout the spec for inactive/unavailable states.

### Round 8 — final phase sync

**Phase bullets stale after launcher exception.** Phase 3 and Phase 6 still described transitions without distinguishing launcher from non-launcher apps in the all-minimized case. **Fix:** Updated both phase bullets to specify the launcher-dot path alongside the non-launcher tray path.
