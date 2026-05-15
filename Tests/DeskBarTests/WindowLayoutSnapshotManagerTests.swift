import CoreGraphics
import Foundation
import Testing
@testable import DeskBar

@Test
func displayMappingPrefersUUIDMatch() {
    let captured = WindowLayoutDisplaySnapshot(
        displayID: 1,
        uuidString: "display-a",
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        scale: 2,
        resolution: CGSize(width: 1920, height: 1080),
        isMain: true
    )
    let current = WindowLayoutDisplaySnapshot(
        displayID: 9,
        uuidString: "display-a",
        bounds: CGRect(x: 100, y: 0, width: 1920, height: 1080),
        scale: 2,
        resolution: CGSize(width: 1920, height: 1080),
        isMain: false
    )

    let result = WindowLayoutSnapshotManager.currentDisplay(for: captured, in: [current])

    #expect(result == current)
}

@Test
func displayMappingFallsBackToUniqueResolutionAndScaleWhenUUIDIsUnavailable() {
    let captured = WindowLayoutDisplaySnapshot(
        displayID: 1,
        uuidString: nil,
        bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        scale: 1,
        resolution: CGSize(width: 3440, height: 1440),
        isMain: false
    )
    let current = WindowLayoutDisplaySnapshot(
        displayID: 7,
        uuidString: nil,
        bounds: CGRect(x: -3440, y: 0, width: 3440, height: 1440),
        scale: 1,
        resolution: CGSize(width: 3440, height: 1440),
        isMain: false
    )

    let result = WindowLayoutSnapshotManager.currentDisplay(for: captured, in: [current])

    #expect(result == current)
}

@Test
func displayMappingFallsBackToUniqueResolutionAndScaleWhenCurrentUUIDExists() {
    let captured = WindowLayoutDisplaySnapshot(
        displayID: 1,
        uuidString: nil,
        bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        scale: 1,
        resolution: CGSize(width: 3440, height: 1440),
        isMain: false
    )
    let current = WindowLayoutDisplaySnapshot(
        displayID: 7,
        uuidString: "display-current",
        bounds: CGRect(x: -3440, y: 0, width: 3440, height: 1440),
        scale: 1,
        resolution: CGSize(width: 3440, height: 1440),
        isMain: false
    )

    let result = WindowLayoutSnapshotManager.currentDisplay(for: captured, in: [current])

    #expect(result == current)
}

@Test
func displayMappingRejectsAmbiguousFallbackMatches() {
    let captured = WindowLayoutDisplaySnapshot(
        displayID: 1,
        uuidString: nil,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        scale: 2,
        resolution: CGSize(width: 1920, height: 1080),
        isMain: true
    )
    let first = WindowLayoutDisplaySnapshot(
        displayID: 2,
        uuidString: nil,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        scale: 2,
        resolution: CGSize(width: 1920, height: 1080),
        isMain: true
    )
    let second = WindowLayoutDisplaySnapshot(
        displayID: 3,
        uuidString: nil,
        bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        scale: 2,
        resolution: CGSize(width: 1920, height: 1080),
        isMain: false
    )

    let result = WindowLayoutSnapshotManager.currentDisplay(for: captured, in: [first, second])

    #expect(result == nil)
}

@Test
func mappedDisplaysRejectsManyToOneFallbackMatches() {
    let firstCaptured = WindowLayoutDisplaySnapshot(
        displayID: 1,
        uuidString: nil,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        scale: 2,
        resolution: CGSize(width: 1920, height: 1080),
        isMain: true
    )
    let secondCaptured = WindowLayoutDisplaySnapshot(
        displayID: 2,
        uuidString: nil,
        bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        scale: 2,
        resolution: CGSize(width: 1920, height: 1080),
        isMain: false
    )
    let onlyCurrent = WindowLayoutDisplaySnapshot(
        displayID: 9,
        uuidString: nil,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        scale: 2,
        resolution: CGSize(width: 1920, height: 1080),
        isMain: true
    )

    let result = WindowLayoutSnapshotManager.mappedDisplays(
        capturedDisplays: [firstCaptured, secondCaptured],
        currentDisplays: [onlyCurrent]
    )

    #expect(result == nil)
}

@Test
func relativeFrameRoundTripsAcrossEquivalentDisplayBounds() {
    let originalDisplay = CGRect(x: -3440, y: 0, width: 3440, height: 1440)
    let currentDisplay = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    let frame = CGRect(x: -1720, y: 40, width: 1200, height: 900)

    let relativeFrame = WindowLayoutSnapshotManager.relativeFrame(for: frame, in: originalDisplay)
    let restoredFrame = WindowLayoutSnapshotManager.absoluteFrame(from: relativeFrame, in: currentDisplay)

    #expect(restoredFrame == CGRect(x: 1720, y: 40, width: 1200, height: 900))
}

@Test
func clampedFramePreservesSizeWhenWindowWouldRestoreOffDisplay() {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let frame = CGRect(x: 1700, y: 900, width: 500, height: 300)

    let clamped = WindowLayoutSnapshotManager.clampedFrame(frame, to: display)

    #expect(clamped == CGRect(x: 1420, y: 780, width: 500, height: 300))
}

@Test
func liveWindowMatchingPrefersPIDAndWindowIDBeforeTitle() {
    let snapshot = windowSnapshot(
        pid: 11,
        cgWindowID: 42,
        bundleIdentifier: "com.example.app",
        title: "Original"
    )
    let titleMatch = liveWindow(
        pid: 22,
        cgWindowID: 100,
        bundleIdentifier: "com.example.app",
        title: "Original"
    )
    let idMatch = liveWindow(
        pid: 11,
        cgWindowID: 42,
        bundleIdentifier: "com.example.other",
        title: "Different"
    )

    let result = WindowLayoutSnapshotManager.matchingLiveWindow(
        for: snapshot,
        in: [titleMatch, idMatch]
    )

    #expect(result?.pid == 11)
    #expect(result?.cgWindowID == 42)
}

@Test
func liveWindowMatchingRejectsAmbiguousTitleMatches() {
    let snapshot = windowSnapshot(
        pid: 11,
        cgWindowID: nil,
        bundleIdentifier: "com.example.app",
        title: "Shared"
    )
    let first = liveWindow(pid: 20, cgWindowID: 1, bundleIdentifier: "com.example.app", title: "Shared")
    let second = liveWindow(pid: 21, cgWindowID: 2, bundleIdentifier: "com.example.app", title: "Shared")

    let result = WindowLayoutSnapshotManager.matchingLiveWindow(for: snapshot, in: [first, second])

    #expect(result == nil)
}

private func windowSnapshot(
    pid: pid_t,
    cgWindowID: CGWindowID?,
    bundleIdentifier: String?,
    title: String
) -> WindowLayoutWindowSnapshot {
    WindowLayoutWindowSnapshot(
        pid: pid,
        cgWindowID: cgWindowID,
        bundleIdentifier: bundleIdentifier,
        appName: "Example",
        title: title,
        displayKey: "display-a",
        absoluteFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
        relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
        isMinimized: false,
        isHidden: false,
        isFullScreen: false,
        capturedAt: Date(timeIntervalSince1970: 100)
    )
}

private func liveWindow(
    pid: pid_t,
    cgWindowID: CGWindowID?,
    bundleIdentifier: String?,
    title: String
) -> WindowLayoutLiveWindow {
    WindowLayoutLiveWindow(
        pid: pid,
        cgWindowID: cgWindowID,
        bundleIdentifier: bundleIdentifier,
        title: title,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        isMinimized: false,
        isHidden: false,
        isFullScreen: false,
        element: nil
    )
}
