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
    let movedApplication = WindowInfo(
        pid: 11,
        cgWindowID: 42,
        appName: "Alpha",
        title: "Dashboard",
        icon: matchingIcon,
        bundleIdentifier: "com.example.alpha",
        applicationURL: URL(fileURLWithPath: "/Applications/Alpha.app")
    )

    #expect(first == second)
    #expect(first != changedIcon)
    #expect(first != renamed)
    #expect(first != movedApplication)
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
func trayApplicationCandidatesHideAppsWithVisibleBundleSiblings() {
    let candidates = [
        RunningApplicationCandidate(pid: 11, bundleIdentifier: "com.valvesoftware.steam", name: "Steam"),
        RunningApplicationCandidate(pid: 22, bundleIdentifier: "com.example.notes", name: "Notes")
    ]

    let result = WindowManager.trayApplicationCandidates(
        from: candidates,
        visibleWindowPIDs: [],
        visibleWindowBundleIdentifiers: Set(["com.valvesoftware.steam"]),
        pinnedBundleIdentifiers: [],
        blacklistedBundleIdentifiers: [],
        currentBundleIdentifier: "com.deskbar.app"
    )

    #expect(result.map(\.bundleIdentifier) == ["com.example.notes"])
}

@Test
func trayApplicationCandidatesDeduplicateByBundleIdentifier() {
    let candidates = [
        RunningApplicationCandidate(pid: 11, bundleIdentifier: "com.valvesoftware.steam", name: "Steam"),
        RunningApplicationCandidate(pid: 22, bundleIdentifier: "com.valvesoftware.steam", name: "Steam Helper"),
        RunningApplicationCandidate(pid: 33, bundleIdentifier: nil, name: "Script")
    ]

    let result = WindowManager.trayApplicationCandidates(
        from: candidates,
        visibleWindowPIDs: [],
        pinnedBundleIdentifiers: [],
        blacklistedBundleIdentifiers: [],
        currentBundleIdentifier: "com.deskbar.app"
    )

    #expect(result.count == 2)
    #expect(result.map(\.bundleIdentifier).contains("com.valvesoftware.steam"))
    #expect(result.map(\.name).contains("Script"))
}

@Test
func preferredDisplayBundleUsesContainingAppForUIElementHelper() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskBarTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let steamBundleURL = rootURL.appendingPathComponent("Steam", isDirectory: true)
    let helperBundleURL = steamBundleURL
        .appendingPathComponent("Contents/Frameworks/Steam Helper.app", isDirectory: true)
    let helperExecutableURL = helperBundleURL
        .appendingPathComponent("Contents/MacOS/Steam Helper")

    try writeApplicationBundleInfo(
        at: steamBundleURL,
        name: "Steam",
        bundleIdentifier: "com.valvesoftware.steam"
    )
    try writeApplicationBundleInfo(
        at: helperBundleURL,
        name: "Steam Helper",
        bundleIdentifier: "com.valvesoftware.steam.helper",
        isUIElement: true
    )
    try FileManager.default.createDirectory(
        at: helperExecutableURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let result = WindowManager.preferredDisplayBundleURL(
        containingExecutableAt: helperExecutableURL.path
    )

    #expect(result?.standardizedFileURL == steamBundleURL.standardizedFileURL)
}

@Test
func preferredDisplayBundleUsesNearestRegularAppBundle() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskBarTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let gameBundleURL = rootURL.appendingPathComponent("Age Of Empires II.app", isDirectory: true)
    let executableURL = gameBundleURL.appendingPathComponent("Contents/MacOS/Age Of Empires II")
    try writeApplicationBundleInfo(
        at: gameBundleURL,
        name: "Age Of Empires II",
        bundleIdentifier: "com.feralinteractive.ageofempires2"
    )
    try FileManager.default.createDirectory(
        at: executableURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let result = WindowManager.preferredDisplayBundleURL(containingExecutableAt: executableURL.path)

    #expect(result?.standardizedFileURL == gameBundleURL.standardizedFileURL)
}

@Test
func preferredDisplayBundleUsesNestedAppWhenUIElementIsFalse() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskBarTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let parentBundleURL = rootURL.appendingPathComponent("Parent.app", isDirectory: true)
    let nestedBundleURL = parentBundleURL
        .appendingPathComponent("Contents/Applications/Nested Tool.app", isDirectory: true)
    let executableURL = nestedBundleURL.appendingPathComponent("Contents/MacOS/Nested Tool")

    try writeApplicationBundleInfo(
        at: parentBundleURL,
        name: "Parent",
        bundleIdentifier: "com.example.parent"
    )
    try writeApplicationBundleInfo(
        at: nestedBundleURL,
        name: "Nested Tool",
        bundleIdentifier: "com.example.nested-tool",
        lsUIElement: false
    )
    try FileManager.default.createDirectory(
        at: executableURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let result = WindowManager.preferredDisplayBundleURL(containingExecutableAt: executableURL.path)

    #expect(result?.standardizedFileURL == nestedBundleURL.standardizedFileURL)
}

@Test
func knownNonregularApplicationInferenceRequiresContainingBundle() {
    let parentURL = URL(fileURLWithPath: "/Applications/Parent.app")
    let nestedURL = parentURL.appendingPathComponent("Contents/Frameworks/Helper.app")
    let standaloneURL = URL(fileURLWithPath: "/Applications/Menu Agent.app")

    #expect(WindowManager.knownNonregularApplicationCanUseInferredBundle(
        knownApplicationBundleURL: nestedURL,
        inferredBundleURL: parentURL
    ))
    #expect(!WindowManager.knownNonregularApplicationCanUseInferredBundle(
        knownApplicationBundleURL: standaloneURL,
        inferredBundleURL: standaloneURL
    ))
    #expect(!WindowManager.knownNonregularApplicationCanUseInferredBundle(
        knownApplicationBundleURL: nil,
        inferredBundleURL: parentURL
    ))
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

private func writeApplicationBundleInfo(
    at bundleURL: URL,
    name: String,
    bundleIdentifier: String,
    isUIElement: Bool = false,
    lsUIElement: Any? = nil
) throws {
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

    var info: [String: Any] = [
        "CFBundleName": name,
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundlePackageType": "APPL"
    ]
    if isUIElement {
        info["LSUIElement"] = "1"
    } else if let lsUIElement {
        info["LSUIElement"] = lsUIElement
    }

    let plistData = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
}
