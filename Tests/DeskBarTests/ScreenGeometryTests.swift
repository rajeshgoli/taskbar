import CoreGraphics
import Testing
@testable import DeskBar

@Test
func windowBelongsToDisplayWhenOriginIsContained() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 120, y: 40, width: 900, height: 700)

    #expect(ScreenGeometry.isWindow(bounds: windowBounds, onDisplay: displayBounds))
}

@Test
func windowBelongsToDisplayWhenFrameBorderExtendsOutsideDisplay() {
    let displayBounds = CGRect(x: -3440, y: 0, width: 3440, height: 1440)
    let windowBounds = CGRect(x: -3441, y: 30, width: 3440, height: 1370)

    #expect(ScreenGeometry.isWindow(bounds: windowBounds, onDisplay: displayBounds))
}

@Test
func windowBelongsToDisplayWhenMidpointFallsOffscreen() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 1800, y: 40, width: 600, height: 700)

    #expect(ScreenGeometry.isWindow(bounds: windowBounds, onDisplay: displayBounds))
}

@Test
func windowRoutesToOriginDisplayWhenMidpointFallsOnAdjacentDisplay() {
    let leftDisplayBounds = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let rightDisplayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: -1, y: 40, width: 100, height: 700)

    let owningDisplayBounds = ScreenGeometry.owningDisplayBounds(
        for: windowBounds,
        among: [leftDisplayBounds, rightDisplayBounds]
    )

    #expect(owningDisplayBounds == leftDisplayBounds)
}

@Test
func windowDoesNotBelongToDisplayWhenOriginFallsOutside() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 1921, y: 10, width: 400, height: 300)

    #expect(!ScreenGeometry.isWindow(bounds: windowBounds, onDisplay: displayBounds))
}

@Test
func fullScreenWindowMatchesDisplayBoundsWithinTolerance() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 1, y: 0, width: 1919, height: 1080)

    #expect(ScreenGeometry.matchesFullScreenWindow(bounds: windowBounds, onDisplay: displayBounds))
}

@Test
func fullScreenWindowAllowsMenuBarInsetFallback() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 0, y: 25, width: 1920, height: 1055)

    #expect(ScreenGeometry.matchesFullScreenWindow(bounds: windowBounds, onDisplay: displayBounds))
}

@Test
func nonFullScreenWindowDoesNotMatchDisplayBounds() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 0, y: 0, width: 1800, height: 1080)

    #expect(!ScreenGeometry.matchesFullScreenWindow(bounds: windowBounds, onDisplay: displayBounds))
}

@Test
func fullWidthSystemFillWindowIsAdjustedAboveTaskbar() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 0, y: 25, width: 1920, height: 1055)

    let adjusted = ScreenGeometry.adjustedFrameAvoidingTaskbar(
        for: windowBounds,
        onDisplay: displayBounds,
        taskbarHeight: 40
    )

    #expect(adjusted?.height == 1015)
    #expect(adjusted?.maxY == 1040)
}

@Test
func leftHalfSystemFillWindowIsAdjustedAboveTaskbar() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 0, y: 30, width: 960, height: 1050)

    let adjusted = ScreenGeometry.adjustedFrameAvoidingTaskbar(
        for: windowBounds,
        onDisplay: displayBounds,
        topInset: 30,
        taskbarHeight: 40
    )

    #expect(adjusted?.width == 960)
    #expect(adjusted?.height == 1010)
    #expect(adjusted?.maxY == 1040)
}

@Test
func rightHalfSystemFillWindowIsAdjustedAboveTaskbar() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 960, y: 30, width: 960, height: 1050)

    let adjusted = ScreenGeometry.adjustedFrameAvoidingTaskbar(
        for: windowBounds,
        onDisplay: displayBounds,
        topInset: 30,
        taskbarHeight: 40
    )

    #expect(adjusted?.minX == 960)
    #expect(adjusted?.height == 1010)
    #expect(adjusted?.maxY == 1040)
}

@Test
func leftHalfSystemFillWindowRoutesToLeftTaskbarZone() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 0, y: 30, width: 960, height: 1010)

    let zone = ScreenGeometry.taskbarZone(
        for: windowBounds,
        onDisplay: displayBounds,
        topInset: 30,
        taskbarHeight: 40
    )

    #expect(zone == .left)
}

@Test
func rightHalfSystemFillWindowRoutesToRightTaskbarZone() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 960, y: 30, width: 960, height: 1010)

    let zone = ScreenGeometry.taskbarZone(
        for: windowBounds,
        onDisplay: displayBounds,
        topInset: 30,
        taskbarHeight: 40
    )

    #expect(zone == .right)
}

@Test
func fullWidthSystemFillWindowRoutesToNeutralTaskbarZone() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 0, y: 30, width: 1920, height: 1010)

    let zone = ScreenGeometry.taskbarZone(
        for: windowBounds,
        onDisplay: displayBounds,
        topInset: 30,
        taskbarHeight: 40
    )

    #expect(zone == .neutral)
}

@Test
func shortManualSideWindowRoutesToNeutralTaskbarZone() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 0, y: 30, width: 960, height: 500)

    let zone = ScreenGeometry.taskbarZone(
        for: windowBounds,
        onDisplay: displayBounds,
        topInset: 30,
        taskbarHeight: 40
    )

    #expect(zone == .neutral)
}

@Test
func shortManualWindowIsNotAdjustedForTaskbar() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 0, y: 600, width: 960, height: 480)

    let adjusted = ScreenGeometry.adjustedFrameAvoidingTaskbar(
        for: windowBounds,
        onDisplay: displayBounds,
        taskbarHeight: 40
    )

    #expect(adjusted == nil)
}

@Test
func tallManualSideWindowIsNotAdjustedWhenNotTopAligned() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 0, y: 240, width: 960, height: 840)

    let adjusted = ScreenGeometry.adjustedFrameAvoidingTaskbar(
        for: windowBounds,
        onDisplay: displayBounds,
        taskbarHeight: 40
    )

    #expect(adjusted == nil)
}
