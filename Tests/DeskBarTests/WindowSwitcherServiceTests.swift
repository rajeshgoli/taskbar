import CoreGraphics
import Testing
@testable import DeskBar

@Test
func windowSwitcherEventTapIncludesPointerEventsForBareCommandCancellation() {
    let eventTypes = Set(WindowSwitcherService.eventTypesOfInterest)

    #expect(eventTypes.contains(.leftMouseDown))
    #expect(eventTypes.contains(.rightMouseDown))
    #expect(eventTypes.contains(.otherMouseDown))
    #expect(eventTypes.contains(.scrollWheel))
}

@Test
func windowSwitcherEventTapRequiresAccessibilityAndAtLeastOneShortcut() {
    #expect(
        WindowSwitcherService.shouldInstallEventTap(
            isAccessibilityGranted: true,
            enableWindowSwitcher: true,
            enableBareCommandLauncher: false
        )
    )
    #expect(
        WindowSwitcherService.shouldInstallEventTap(
            isAccessibilityGranted: true,
            enableWindowSwitcher: false,
            enableBareCommandLauncher: true
        )
    )
    #expect(
        WindowSwitcherService.shouldInstallEventTap(
            isAccessibilityGranted: true,
            enableWindowSwitcher: false,
            enableBareCommandLauncher: false
        ) == false
    )
    #expect(
        WindowSwitcherService.shouldInstallEventTap(
            isAccessibilityGranted: false,
            enableWindowSwitcher: true,
            enableBareCommandLauncher: true
        ) == false
    )
}

@Test
func appsLauncherShortcutMatchesConfiguredSpaceCombos() {
    #expect(
        WindowSwitcherService.matchesAppsLauncherShortcut(
            shortcut: .controlOptionSpace,
            type: .keyDown,
            keyCode: 49,
            flags: [.maskControl, .maskAlternate]
        )
    )
    #expect(
        WindowSwitcherService.matchesAppsLauncherShortcut(
            shortcut: .optionSpace,
            type: .keyDown,
            keyCode: 49,
            flags: [.maskAlternate]
        )
    )
    #expect(
        WindowSwitcherService.matchesAppsLauncherShortcut(
            shortcut: .commandTap,
            type: .keyDown,
            keyCode: 49,
            flags: [.maskCommand]
        ) == false
    )
}

@Test
func appsLauncherShortcutRejectsSystemAndCopyPasteLikeCombos() {
    #expect(
        WindowSwitcherService.matchesAppsLauncherShortcut(
            shortcut: .controlOptionSpace,
            type: .keyDown,
            keyCode: 49,
            flags: [.maskCommand, .maskAlternate]
        ) == false
    )
    #expect(
        WindowSwitcherService.matchesAppsLauncherShortcut(
            shortcut: .controlOptionSpace,
            type: .keyDown,
            keyCode: 8,
            flags: [.maskCommand]
        ) == false
    )
    #expect(
        WindowSwitcherService.matchesAppsLauncherShortcut(
            shortcut: .controlOptionSpace,
            type: .keyUp,
            keyCode: 49,
            flags: [.maskControl, .maskAlternate]
        ) == false
    )
}

@Test
func switchableWindowsFollowZOrderAndAppendUnlistedWindows() {
    let first = window(pid: 1, cgWindowID: 10, title: "First")
    let second = window(pid: 2, cgWindowID: 20, title: "Second")
    let third = window(pid: 3, cgWindowID: 30, title: "Third")

    let result = WindowSwitcherService.switchableWindows(
        from: [first, second, third],
        zOrderedWindowIDs: [20, 10]
    )

    #expect(result.map(\.id) == [second.id, first.id, third.id])
}

@Test
func switchableWindowsExcludeHiddenMinimizedAndProvisionalWindows() {
    let visible = window(pid: 1, cgWindowID: 10, title: "Visible")
    let minimized = window(pid: 2, cgWindowID: 20, title: "Minimized", isMinimized: true)
    let hidden = window(pid: 3, cgWindowID: 30, title: "Hidden", isHidden: true)
    let provisional = WindowInfo(
        pid: 4,
        provisionalID: "4-provisional",
        appName: "App",
        title: "Provisional",
        icon: nil,
        bundleIdentifier: "com.example.app",
        isProvisional: true
    )

    let result = WindowSwitcherService.switchableWindows(
        from: [visible, minimized, hidden, provisional],
        zOrderedWindowIDs: [30, 20, 10]
    )

    #expect(result.map(\.id) == [visible.id])
}

@Test
func nextSelectionStartsAfterCurrentWindow() {
    let ids = ["one", "two", "three"]

    let result = WindowSwitcherService.nextSelectionIndex(
        candidateIDs: ids,
        currentWindowID: "one",
        sessionIndex: nil,
        reverse: false
    )

    #expect(result == 1)
}

@Test
func reverseSelectionStartsBeforeCurrentWindow() {
    let ids = ["one", "two", "three"]

    let result = WindowSwitcherService.nextSelectionIndex(
        candidateIDs: ids,
        currentWindowID: "one",
        sessionIndex: nil,
        reverse: true
    )

    #expect(result == 2)
}

@Test
func nextSelectionContinuesFromSessionIndex() {
    let ids = ["one", "two", "three"]

    let result = WindowSwitcherService.nextSelectionIndex(
        candidateIDs: ids,
        currentWindowID: "one",
        sessionIndex: 1,
        reverse: false
    )

    #expect(result == 2)
}

@Test
func activationActionRaisesMatchedAXWindow() {
    #expect(
        WindowSwitcherService.activationAction(
            applicationIsRunning: true,
            hasMatchedAXWindow: true
        ) == .raiseAXWindow
    )
}

@Test
func activationActionFallsBackToApplicationWhenAXWindowIsMissing() {
    #expect(
        WindowSwitcherService.activationAction(
            applicationIsRunning: true,
            hasMatchedAXWindow: false
        ) == .activateApplication
    )
}

@Test
func activationActionNoopsWhenApplicationIsGone() {
    #expect(
        WindowSwitcherService.activationAction(
            applicationIsRunning: false,
            hasMatchedAXWindow: false
        ) == .none
    )
}

private func window(
    pid: pid_t,
    cgWindowID: CGWindowID,
    title: String,
    isMinimized: Bool = false,
    isHidden: Bool = false
) -> WindowInfo {
    WindowInfo(
        pid: pid,
        cgWindowID: cgWindowID,
        appName: "App \(pid)",
        title: title,
        icon: nil,
        bundleIdentifier: "com.example.app\(pid)",
        isMinimized: isMinimized,
        isHidden: isHidden
    )
}
