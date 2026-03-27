# DeskBar

A native macOS taskbar replacement built with Swift and AppKit. Sits at the bottom of your screen and shows your running windows — click to switch, right-click for a Dock-style menu.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Why

macOS doesn't have a Windows-style taskbar — the Dock shows apps, not windows. If you work with many windows across multiple apps, switching between them means Cmd+Tab, Mission Control, or clicking through stacks. DeskBar gives you a persistent bottom bar with one button per window, so you always know what's open and can switch with a single click.

Lightweight, native, no external dependencies. Does not modify any system settings or shortcuts.

## Features

- **Three-zone layout** — Launcher (pinned apps) | Task Zone (windows) | Running-App Tray
- **Per-window switching** — click a task button to raise that specific window, not all windows from the app
- **Dock-style right-click menu** — window list with checkmark on active window, plus Show All Windows, Hide, Quit
- **Real-time updates** — windows appear/disappear as you open/close them, no polling lag
- **Multi-monitor** — taskbar on every display, each showing only that display's windows
- **Hover thumbnails** — live window previews via ScreenCaptureKit (requires Screen Recording permission)
- **Window grouping** — optionally group windows by app with expandable groups
- **Drag reorder** — rearrange task buttons, pinned items hold position across activations
- **Stable ordering** — tasks stay where they are, no jarring MRU jumps
- **Minimized windows stay visible** — dimmed in the taskbar (Windows-style), click to restore
- **Settings** — 14 configurable options (height, font size, thumbnails, Dock mode, etc.)
- **Dock coexistence** — three modes (independent, auto-hide, hidden) with crash-safe restore
- **Start at login** — LaunchAgent-based, works with ad-hoc signed builds
- **Blacklist** — hide apps you don't want in the taskbar
- **Badge dots** — best-effort notification indicators
- **Smooth animations** — fade in/out on window appear/disappear
- **Accessibility graceful degradation** — works in reduced mode without AX permission

## Install

```bash
# Clone and build
git clone https://github.com/rajeshgoli/taskbar.git
cd taskbar
swift build -c release

# Package into .app bundle
bash scripts/package.sh

# Install
cp -r .build/release/DeskBar.app /Applications/
```

Then open `/Applications/DeskBar.app`.

## First Launch

1. **Accessibility permission** — an amber banner will appear. Click it to open System Settings, then add DeskBar under Privacy & Security > Accessibility.
2. **Screen Recording permission** (optional, for hover thumbnails) — System Settings > Privacy & Security > Screen Recording > add DeskBar.
3. **Gear icon** in the menu bar — access Settings or Quit.

If you rebuild and reinstall, you may need to re-grant permissions:
```bash
tccutil reset Accessibility com.deskbar.app
```

## Usage

| Action | What happens |
|--------|-------------|
| **Click** a task button | Raises that specific window |
| **Right-click** a task button | Dock-style menu: window list, Show All Windows, Hide, Pin, Blacklist, Quit |
| **Click** a launcher icon | Activates the app (launches if not running) |
| **Right-click** a launcher icon | Unpin from launcher |
| **Hover** a task button | Shows live window thumbnail (if Screen Recording granted) |
| **Middle-click** a task button | Closes that window |
| **Drag** task buttons | Reorder; dragged items hold position |
| **Gear icon** in menu bar | Open Settings or Quit |

## Settings

Accessible via the gear icon in the menu bar.

| Tab | Options |
|-----|---------|
| General | Start at login, Launchpad button, Dock mode |
| Appearance | Taskbar height, font size, max button width, show titles, thumbnail size |
| Behavior | Hover delay, group by app, drag reorder, middle-click closes, show over full-screen, multi-monitor |
| Launcher | Manage pinned apps |
| Blacklist | Manage hidden apps |

## Requirements

- macOS 14.0+
- No external dependencies — system frameworks only
- No Xcode required — builds with Swift Package Manager

## Architecture

Pure AppKit, no SwiftUI. Key components:

- **TaskbarPanel** — `NSPanel` with `.nonactivatingPanel` at `.statusBar` level
- **WindowManager** — two-tier storage (authoritative + provisional), AXObserver + CGWindowList polling
- **AccessibilityService** — `_AXUIElementGetWindow` via dlsym with frame-matching fallback
- **ThumbnailService** — ScreenCaptureKit capture with 2s cache
- **DockManager** — three-mode Dock control with watchdog LaunchAgent for crash recovery

## License

MIT
