# DeskBar Execution Plan

## Context

DeskBar is a native macOS taskbar replacement (Swift/AppKit/SPM). The product spec (`SPEC.md`) is converged after 8 review rounds. No code exists yet. This plan decomposes all 8 implementation phases into parallelizable execution tickets scoped for up to 6 agents per deliverable.

## Tenets

1. **Validate before proceeding.** The spec for step N+1 is not written until step N validates. Each phase has a concrete milestone that must pass before the next phase begins.
2. **Parallel where independent, sequential where coupled.** Force-fitting parallelism on tightly coupled work creates merge conflicts and integration bugs. Each phase identifies the natural concurrency ceiling.
3. **Interface contracts before implementation.** Parallel agents within a phase must agree on type signatures and protocols upfront. The agent that defines the type goes first (or the interface is declared in the ticket spec).
4. **Minimize merge conflict surface.** When multiple tickets touch the same file across phases, the modification order is explicit and sequential within that file.

## Phase Dependency Chain

```
P1 (Foundation) → P2 (Window Switching) → P3 (Visual Polish) → P4 (Thumbnails)
                                        ↘ P5 (Settings) → P6 (Three Zones) → P7 (Advanced) → P8 (Packaging)
```

P3-C (utilities) can start during P2. P4 can overlap with P5. P8 sub-tickets are fully parallel.

---

## Phase 1: Foundation — 3 agents

**Milestone:** `swift run` shows a floating bar at the bottom with app icons.

| Ticket | Scope | Files | Blocked By |
|--------|-------|-------|------------|
| **1-A: SPM + Bootstrap** | Package.swift (executable target, macOS 14), main.swift (NSApp accessory policy), AppDelegate (create panel, init WindowManager, wire content view) | Package.swift, main.swift, AppDelegate.swift | 1-B, 1-C interfaces |
| **1-B: Data Model** | WindowInfo struct (Phase 1 fields: appName, icon, pid; Phase 2 fields declared with defaults), WindowManager (query NSWorkspace.runningApplications, filter .regular policy, expose windows array) | WindowInfo.swift, WindowManager.swift | None |
| **1-C: Panel + Views** | TaskbarPanel (NSPanel: .statusBar, .borderless+.nonactivatingPanel, .canJoinAllSpaces+.stationary+.ignoresCycle, NSVisualEffectView), TaskbarContentView (horizontal icon row, 32x32 icons, tooltips) | TaskbarPanel.swift, TaskbarContentView.swift | 1-B interface |

**Parallelism:** 1-B and 1-C parallel. 1-A integrates last.

---

## Phase 2: Window Switching — 4 agents

**Milestone:** Clicking a task switches to that window. Windows appear/disappear in real time.

| Ticket | Scope | Files | Blocked By |
|--------|-------|-------|------------|
| **2-A: AccessibilityService** | dlsym `_AXUIElementGetWindow`, frame-matching fallback (2px tolerance), AX window enumeration per app, eligibility checks (role/subrole), raise/activate | AccessibilityService.swift | P1 |
| **2-B: Permissions + Banner** | AXIsProcessTrustedWithOptions (non-prompting), 5s poll timer, persistent amber banner view, degraded-mode rendering (Task Zone collapses to per-app buttons, context menu shows only Quit), grant/revoke transitions rebuild task list | PermissionsManager.swift, AppDelegate.swift (mod), TaskbarPanel.swift (mod), TaskbarContentView.swift (mod) | P1 |
| **2-C: Monitors + Two-Tier Storage** | WorkspaceMonitor (6 NSWorkspace notifications incl. activeSpaceDidChangeNotification), AXObserverManager (per-app observers, 6 AX notifications), Debouncer (100ms), WindowManager upgrade (authoritative + provisional dicts, 500ms promotion with 100ms retry, 2s CGWindowList poll with kCGWindowListOptionOnScreenOnly + main display bounds filtering for local Space/monitor scoping, dedup on promotion) | WorkspaceMonitor.swift, AXObserverManager.swift, Debouncer.swift, WindowManager.swift (mod) | P1, 2-A interface |
| **2-D: TaskButtonView + Click** | NSView with icon + title, click-to-activate (raise + activate), NSTrackingArea hover highlight, active window detection via frontmostApplication | TaskButtonView.swift, TaskbarContentView.swift (mod) | P1 |

**Parallelism:** All 4 parallel (agreed interfaces). Integration wires AppDelegate → PermissionsManager → AccessibilityService → WindowManager → ContentView.

---

## Phase 3: Visual Polish — 3 agents

**Milestone:** Polished native appearance with proper state indicators.

| Ticket | Scope | Files | Blocked By |
|--------|-------|-------|------------|
| **3-A: State Indicators** | Active highlight (accent background), minimized (greyed + `[title]`), hidden (semi-transparent + `(title)`), all-minimized removal from Task Zone | TaskButtonView.swift (mod), TaskbarContentView.swift (mod) | P2 |
| **3-B: Context Menu** | Right-click: Close (AX close button), Minimize (AX attribute), Hide (NSRunningApplication.hide). Degraded mode: only Quit | TaskButtonView.swift (mod) | P2 |
| **3-C: Utilities** | ScreenGeometry (taskbar frame math, multi-monitor coords), NSImageExtensions (scale, desaturate, withAlpha), CGWindowExtensions (onScreenWindows, windowBounds, isEligible) | ScreenGeometry.swift, NSImageExtensions.swift, CGWindowExtensions.swift, TaskbarPanel.swift (mod) | P1 (can start during P2) |

**Parallelism:** All 3 parallel. 3-C can start early (only needs P1).

---

## Phase 4: Thumbnails — 2 agents

**Milestone:** Hovering 400ms shows a live window thumbnail.

| Ticket | Scope | Files | Blocked By |
|--------|-------|-------|------------|
| **4-A: ThumbnailService** | ScreenCaptureKit capture (SCScreenshotManager.captureSampleBuffer), Screen Recording permission check, 2s image cache, nil for provisional windows | ThumbnailService.swift | P2 |
| **4-B: Popover + Hover** | NSTrackingArea on TaskButtonView, 400ms delay timer, NSPopover above button, rapid-movement handling, provisional window "(syncing...)" tooltip | ThumbnailPopover.swift, TaskButtonView.swift (mod) | P2 (prefer P3 first) |

---

## Phase 5: Settings — 3 agents

**Milestone:** Settings model complete with all properties, UI rendered with all controls, early settings wired (settings whose consumers exist post-P4).

| Ticket | Scope | Files | Blocked By |
|--------|-------|-------|------------|
| **5-A: Settings Model** | Observable class backed by UserDefaults("com.deskbar.app"), all 14 settings with defaults, dockMode as Swift enum. Tests. | TaskbarSettings.swift, TaskbarSettingsTests.swift | P1 |
| **5-B: Settings UI** | NSWindow with NSTabView (5 tabs: General, Appearance, Behavior, Launcher placeholder, Blacklist placeholder), standard AppKit controls | SettingsWindowController.swift, SettingsView.swift | None (stubs 5-A; must merge after 5-A) |
| **5-C: Integration + Status Item** | NSStatusItem (gear icon, "Settings...", "Quit"), wire early settings only: taskbarHeight, titleFontSize, maxTaskWidth, showTitles, thumbnailSize, hoverDelay. Remaining settings wired by their owning tickets: groupByApp/dragReorder (7-A/7-B), middleClickCloses (7-C), showOverFullScreenApps (8-C), dockMode (8-A), startAtLogin (8-B), showOnAllMonitors (8-C), showLaunchpadButton (8-D) | AppDelegate.swift (mod), TaskbarPanel.swift (mod), TaskButtonView.swift (mod), ThumbnailPopover.swift (mod) | 5-A, 5-B |

**Parallelism:** 5-A and 5-B start in parallel (5-B stubs `TaskbarSettings` initially). 5-B cannot merge before 5-A. 5-C sequential after both.

---

## Phase 6: Three-Zone Layout — 4 agents

**Milestone:** Launcher pins, task windows, and running-app tray all populated correctly.

| Ticket | Scope | Files | Blocked By |
|--------|-------|-------|------------|
| **6-A: PinnedApp Model** | PinnedApp struct, UserDefaults persistence (ordered bundle IDs), pin/unpin/reorder API, resolve to NSRunningApplication or icon, wire into Settings > Launcher tab | PinnedApp.swift, SettingsView.swift (mod) | P5 |
| **6-B: BlacklistManager** | Blacklisted bundle ID set in UserDefaults, add/remove API, change notifications, wire into Settings > Blacklist tab, "Add to Blacklist" in context menus. Tests. | BlacklistManager.swift, BlacklistManagerTests.swift, SettingsView.swift (mod), TaskButtonView.swift (mod) | P5 |
| **6-C: Launcher Zone Views** | LauncherZoneView (horizontal row + divider), LauncherButtonView (3 states: greyed/underline/dot, click behavior per state, right-click window list + unpin). Order is user-defined and persisted but reordered only via Settings > Launcher tab (drag-reorder deferred to 7-B) | LauncherZoneView.swift, LauncherButtonView.swift | 6-A |
| **6-D: Tray + Zone Integration** | RunningAppTrayView (24pt icons, alphabetical, no titles), TrayIconView (click activate, right-click Quit/Hide/Pin), transition logic (Task<->Tray, Task<->Launcher dot), no-duplicate-representation invariant enforcement in WindowManager, three-zone layout in TaskbarContentView | RunningAppTrayView.swift, TrayIconView.swift, WindowManager.swift (mod), TaskbarContentView.swift (mod) | 6-A, 6-B, 6-C |

**Parallelism:** 6-A and 6-B parallel. 6-C after 6-A. 6-D integrates last.

---

## Phase 7: Advanced Interactions — 4 agents

**Milestone:** Grouping, drag-reorder, middle-click, badge dots all working.

| Ticket | Scope | Files | Blocked By |
|--------|-------|-------|------------|
| **7-A: Window Grouping** | AppGroup struct, group button (icon + count badge), inline expand/collapse, MRU ordering as group unit, state table (1 window / N ungrouped / N grouped) | AppGroup.swift, TaskZoneView.swift (mod), TaskButtonView.swift (mod) | P6 |
| **7-B: Drag-Reorder** | NSDraggingSource/Destination on task + launcher buttons, zone rules (launcher persisted, task ephemeral, tray blocked, cross-zone blocked), userPositioned flag (holds rank, MRU reorders around, new windows insert at leftmost non-positioned, flag ephemeral) | TaskZoneView.swift (mod), TaskButtonView.swift (mod), LauncherZoneView.swift (mod) | 7-A |
| **7-C: Middle-Click Close** | otherMouseDown where buttonNumber==2, controlled by middleClickCloses setting, close via AX | TaskButtonView.swift (mod) | P6 |
| **7-D: Badge Dots** | Best-effort badge detection (heuristic), dot overlay on task button icon (6-8pt, top-right corner) | BadgeMonitor.swift, NSImageExtensions.swift (mod) | P6 |

**Parallelism:** 7-A, 7-C, 7-D parallel. 7-B after 7-A.

---

## Phase 8: System Integration + Packaging — 5 agents

**Milestone:** Fully packaged `.app` bundle, installable replacement for Taskbar.app.

| Ticket | Scope | Files | Blocked By |
|--------|-------|-------|------------|
| **8-A: DockManager** | Three modes (independent/autoHide/hidden), prior-state to ~/.config/deskbar/dock-prior-state.json, defense-in-depth restore (applicationWillTerminate, SIGTERM/SIGINT handlers, watchdog LaunchAgent with 30s interval), watchdog install/remove on mode switch | DockManager.swift | P5 |
| **8-B: LoginItemManager** | LaunchAgent plist to ~/Library/LaunchAgents/com.deskbar.app.plist, enable/disable, runtime binary path detection, wire to startAtLogin setting | LoginItemManager.swift | P5 |
| **8-C: Multi-Monitor + Full-Screen** | Panel per NSScreen.screens, display-scoped window filtering (CGDisplayBounds containment), per-display full-screen detection + panel hide/show (orderOut/orderFront), screen connect/disconnect handling, showOnAllMonitors toggle, showOverFullScreenApps toggle (adds .fullScreenAuxiliary to collectionBehavior + skips hide/show logic). Single-monitor full-screen detection also lands here. | TaskbarPanel.swift (mod), TaskbarContentView.swift (mod), WindowManager.swift (mod), AppDelegate.swift (mod), ScreenGeometry.swift (mod) | P5 |
| **8-D: Launchpad Button** | LaunchpadButtonView (Launchpad icon, opens /System/Applications/Launchpad.app), leftmost in LauncherZone, showLaunchpadButton toggle | LaunchpadButtonView.swift, LauncherZoneView.swift (mod) | P6 |
| **8-E: Build Scripts** | build.sh (swift build -c release), package.sh (.app bundle assembly), Info.plist.template (LSUIElement=true, com.deskbar.app, macOS 14), ad-hoc codesign | scripts/build.sh, scripts/package.sh, Info.plist.template | None |

**Parallelism:** All 5 fully parallel.

---

## Merge Conflict Hotspots

Files modified by multiple tickets across phases, requiring sequential merging:

1. **TaskButtonView.swift** — Created 2-D, modified 3-A, 3-B, 4-B, 6-B, 7-A, 7-B, 7-C (highest frequency)
2. **WindowManager.swift** — Created 1-B, rewritten 2-C, modified 6-D, 8-C
3. **TaskbarContentView.swift** — Created 1-C, modified 2-B, 2-D, 3-A, 6-D, 8-C
4. **AppDelegate.swift** — Created 1-A, modified 2-B, 5-C, 8-C
5. **LauncherZoneView.swift** — Created 6-C, modified 7-B, 8-D
6. **TaskZoneView.swift** — Modified 7-A, 7-B
7. **SettingsView.swift** — Created 5-B, modified 6-A, 6-B

## Totals

- **8 phases**, **28 sub-tickets**, **up to 6 concurrent agents per phase**
- Critical path: P1 -> P2 -> P3 -> P6 -> P7 -> P8 (P4 and P5 can overlap with P3)
- Each ticket scoped to fit in one agent context window

## Verification

After each phase merges, run `swift build` to confirm compilation. SPEC.md verification cases (lines 576-632) are bound to their owning phases:

**Phase 1:** `swift run` shows the panel (case 2). `swift build` compiles (case 1).

**Phase 2 — SPEC.md cases 11-14, 21-24:**
- AX denied on launch: amber banner, app-level buttons, left-click activates app, right-click shows only Quit (case 11)
- AX granted while running: banner disappears within 5s, per-window buttons rebuild (case 12)
- AX revoked while running: collapses to app-level, banner reappears, no crash (case 13)
- Active app highlighting in degraded mode (case 14)
- `_AXUIElementGetWindow` available: CGWindowID-keyed authoritative dict, no duplicates (case 21)
- `_AXUIElementGetWindow` unavailable: console warning, frame-matching fallback (case 22)
- Provisional window lifecycle: appears immediately, promotes in-place, no flicker, dedup on race (case 23)
- Local Space visibility: only current-Space windows in Task Zone, Space switch updates immediately (case 24)

**Phase 3 — SPEC.md cases 3, 5:**
- All running GUI app windows appear as tasks with proper state indicators (case 3)
- Opening/closing windows updates in real time with correct visual states (case 5)

**Phase 4:** Thumbnails appear on hover after granting Screen Recording permission (case 6).

**Phase 5:** Settings persist across restarts (case 7). Run `TaskbarSettingsTests`.

**Phase 6 — SPEC.md cases 30-37:**
- Launcher Zone: not running (greyed), running with local windows (underline), running no local windows (dot) (cases 30-32)
- Task Zone: local windows only (case 33)
- Running-App Tray: populated correctly, launcher dedup (cases 34-35)
- Tray-to-Task and Task-to-Tray transitions (cases 36-37)
- Run `BlacklistManagerTests`. Pinned apps and blacklist work correctly (case 8).

**Phase 7 — SPEC.md cases 38-39:**
- Drag vs MRU precedence: dragged items hold position, non-positioned reorder around them (case 38)
- Group expansion: click expands inline, individual windows actionable, second click collapses (case 39)

**Phase 8 — SPEC.md cases 15-20, 25-29:**
- Dock coexistence: typical setup (case 15), independent mode (case 16), Dock on bottom (case 17), autoHide switch (case 18), normal quit restore (case 19), crash restore via watchdog (case 20)
- Multi-monitor local visibility (case 25)
- Full-screen single-monitor hide/show (case 26)
- Multi-monitor full-screen on one display (case 27), background full-screen (case 28)
- "Show over full-screen apps" enabled (case 29)
- `scripts/build.sh` produces working DeskBar.app bundle (case 9)

**Every phase:** Verify Cmd+Tab, Cmd+Space, and all system shortcuts continue to work (case 10).

## Ticket Classification

This is an **epic**. 28 sub-tickets across 8 phases. No single agent can complete this without compacting context.

---

## Review History

1 review round between spec-owner-deskbar-exec-plan and spec-reviewer-deskbar. Converged from a draft with 3 blocking, 4 important, and 1 minor issue to an agreed spec in 2 passes.

### Round 1 — 3 blocking, 4 important, 1 minor

**Local Space/monitor scoping deferred to Phase 8 (blocking).** The draft deferred all display-scoped and local-visibility filtering to ticket 8-C (Multi-Monitor), but SPEC.md:196-204 and 303-305 make current Space/monitor scoping a core window-model behavior from Phase 2 onward. As written, Phases 2-7 would show windows from all Spaces and monitors — the wrong window set. **Fix:** Moved single-monitor local visibility filtering into ticket 2-C. The CGWindowList poll now uses `kCGWindowListOptionOnScreenOnly` with main display bounds filtering, and `activeSpaceDidChangeNotification` handling was already scoped to 2-C's WorkspaceMonitor. Ticket 8-C retains only the multi-monitor extension (panel-per-screen, per-display filtering, per-display full-screen detection).

**Phase 5 over-claimed settings wiring (blocking).** The draft said P5 delivers all settings and wires them all, but several settings (groupByApp, dragReorder, middleClickCloses, dockMode, startAtLogin, showOnAllMonitors, showLaunchpadButton, showOverFullScreenApps) belong to features that don't exist until Phases 6-8. P5 cannot truthfully complete wiring before those consumers are built. **Fix:** P5 now declares all 14 settings in the model and renders all UI controls, but ticket 5-C wires only the 6 settings whose consumers exist post-P4 (taskbarHeight, titleFontSize, maxTaskWidth, showTitles, thumbnailSize, hoverDelay). Each remaining setting is explicitly assigned to its owning ticket: groupByApp/dragReorder to 7-A/7-B, middleClickCloses to 7-C, dockMode to 8-A, startAtLogin to 8-B, showOnAllMonitors and showOverFullScreenApps to 8-C, showLaunchpadButton to 8-D. Milestone updated to reflect partial wiring.

**Tickets not self-contained in declared file scope (blocking).** Five tickets listed files that didn't cover their full write scope: 2-B claimed to build the banner and degraded-mode transitions but only listed PermissionsManager.swift and AppDelegate.swift, omitting the view-layer changes needed for the banner and degraded-mode rendering. 6-A and 6-B claimed to wire Settings tabs and context menus but only listed model files. 8-D claimed launcher placement and setting toggle but only listed the view file. **Fix:** Expanded file scopes: 2-B added TaskbarPanel.swift (mod) and TaskbarContentView.swift (mod) for banner and degraded-mode rendering. 6-A added SettingsView.swift (mod) for Launcher tab. 6-B added SettingsView.swift (mod) and TaskButtonView.swift (mod) for Blacklist tab and context menu. 8-D added LauncherZoneView.swift (mod) for placement.

**Launcher drag-reorder placed in wrong phase (important).** Ticket 6-C pulled launcher drag-reorder into Phase 6, but SPEC.md:546-552 places all drag-and-drop reordering in Phase 7. This duplicated scope with 7-B and weakened the P6/P7 boundary. **Fix:** Removed drag-reorder from 6-C. Phase 6 launcher order is user-defined and persisted but reordered only via Settings > Launcher tab. Ticket 7-B implements drag-reorder for both Launcher Zone and Task Zone together.

**Merge conflict hotspots under-called (important).** The draft listed only 4 hotspot files but missed LauncherZoneView.swift (modified by 6-C, 7-B, 8-D) and TaskZoneView.swift (modified by 7-A, 7-B), which are multi-ticket files that should drive merge sequencing. **Fix:** Added LauncherZoneView.swift, TaskZoneView.swift, and SettingsView.swift (5-B, 6-A, 6-B) to the hotspot list.

**Verification section too shallow to support Tenet 1 (important).** The draft's verification was a single paragraph that didn't bind the risky falsification cases from SPEC.md:591-632 to their owning phases. Key scenarios like AX denied/revoked, `_AXUIElementGetWindow` fallback, provisional promotion race, local Space visibility, and background full-screen detection were unaddressed. **Fix:** Expanded verification to bind all 39 SPEC.md test cases to their owning phases, organized by phase with specific case numbers and descriptions.

**5-B blocking status internally inconsistent (important).** The table said 5-B was blocked by 5-A, but the prose said "5-A and 5-B parallel." These contradicted each other. **Fix:** Clarified that 5-A and 5-B start in parallel (5-B stubs `TaskbarSettings` initially), but 5-B cannot merge before 5-A. Updated the table to "None (stubs 5-A; must merge after 5-A)."

**Agent count inconsistency (minor).** The context section said "up to 6 agents per deliverable" while the totals section said "up to 5 concurrent agents per phase." **Fix:** Corrected totals to "up to 6."

### Round 2 — 1 important

**Settings count stale after P5 fix (important).** Ticket 5-A still said "all 13 settings" after the Phase 5 revision correctly distributed all 14 settings (SPEC.md:516-529 defines 14, not 13). The rest of the plan was internally consistent at 14. **Fix:** Updated 5-A scope to "all 14 settings with defaults."
