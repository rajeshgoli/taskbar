import AppKit
import Testing
@testable import DeskBar

@Test
func windowInfoEqualityTracksTaskbarVisibleFields() {
    let first = WindowInfo(
        pid: 11,
        cgWindowID: 42,
        appName: "Alpha",
        title: "Dashboard",
        icon: NSImage(size: NSSize(width: 16, height: 16)),
        bundleIdentifier: "com.example.alpha"
    )
    let matchingIcon = NSImage(size: NSSize(width: 16, height: 16))
    let second = WindowInfo(
        pid: 11,
        cgWindowID: 42,
        appName: "Alpha",
        title: "Dashboard",
        icon: matchingIcon,
        bundleIdentifier: "com.example.alpha"
    )
    let changedIcon = WindowInfo(
        pid: 11,
        cgWindowID: 42,
        appName: "Alpha",
        title: "Dashboard",
        icon: NSImage(size: NSSize(width: 32, height: 32)),
        bundleIdentifier: "com.example.alpha"
    )
    let renamed = WindowInfo(
        pid: 11,
        cgWindowID: 42,
        appName: "Alpha",
        title: "Reports",
        icon: nil,
        bundleIdentifier: "com.example.alpha"
    )

    #expect(first == second)
    #expect(first != changedIcon)
    #expect(first != renamed)
}

@Test
func visibleWindowPIDsRequireAtLeastOneVisibleLocalWindow() {
    let windows = [
        WindowInfo(
            pid: 11,
            appName: "Alpha",
            title: "Visible",
            icon: nil,
            bundleIdentifier: "com.example.alpha",
            isMinimized: false,
            isHidden: false
        ),
        WindowInfo(
            pid: 11,
            appName: "Alpha",
            title: "Minimized sibling",
            icon: nil,
            bundleIdentifier: "com.example.alpha",
            isMinimized: true,
            isHidden: false
        ),
        WindowInfo(
            pid: 22,
            appName: "Beta",
            title: "Minimized only",
            icon: nil,
            bundleIdentifier: "com.example.beta",
            isMinimized: true,
            isHidden: false
        ),
        WindowInfo(
            pid: 33,
            appName: "Gamma",
            title: "Hidden only",
            icon: nil,
            bundleIdentifier: "com.example.gamma",
            isMinimized: false,
            isHidden: true
        )
    ]

    let result = WindowManager.visibleWindowPIDs(from: windows)

    #expect(result == Set([11]))
}

@Test
func trayApplicationCandidatesRespectZoneRoutingAndAlphabeticalOrder() {
    let candidates = [
        RunningApplicationCandidate(pid: 11, bundleIdentifier: "com.example.visible", name: "Visible"),
        RunningApplicationCandidate(pid: 22, bundleIdentifier: "com.example.pinned", name: "Pinned"),
        RunningApplicationCandidate(pid: 33, bundleIdentifier: "com.example.blacklisted", name: "Blacklisted"),
        RunningApplicationCandidate(pid: 44, bundleIdentifier: "com.example.notes", name: "notes"),
        RunningApplicationCandidate(pid: 55, bundleIdentifier: nil, name: "Arc"),
        RunningApplicationCandidate(pid: 66, bundleIdentifier: "com.deskbar.app", name: "DeskBar")
    ]

    let result = WindowManager.trayApplicationCandidates(
        from: candidates,
        visibleWindowPIDs: Set([11]),
        pinnedBundleIdentifiers: Set(["com.example.pinned"]),
        blacklistedBundleIdentifiers: Set(["com.example.blacklisted"]),
        currentBundleIdentifier: "com.deskbar.app"
    )

    #expect(result.map(\.pid) == [55, 44])
    #expect(result.map(\.name) == ["Arc", "notes"])
}

@Test
func stableWindowOrderKeepsExistingPositionsAndAppendsNewWindowsToTheEnd() {
    let result = WindowManager.reconcileStableWindowOrder(
        previousOrder: ["window:alpha", "window:beta", "window:gamma"],
        currentOrder: ["window:beta", "window:delta", "window:alpha"]
    )

    #expect(result == ["window:alpha", "window:beta", "window:delta"])
}

@Test
func stableWindowOrderDeduplicatesCurrentRefreshIDs() {
    let result = WindowManager.reconcileStableWindowOrder(
        previousOrder: [],
        currentOrder: ["window:alpha", "window:alpha", "window:beta"]
    )

    #expect(result == ["window:alpha", "window:beta"])
}
