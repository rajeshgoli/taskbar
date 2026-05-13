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
    let windowBounds = CGRect(x: 0, y: 25, width: 960, height: 1055)

    let adjusted = ScreenGeometry.adjustedFrameAvoidingTaskbar(
        for: windowBounds,
        onDisplay: displayBounds,
        taskbarHeight: 40
    )

    #expect(adjusted?.width == 960)
    #expect(adjusted?.height == 1015)
    #expect(adjusted?.maxY == 1040)
}

@Test
func rightHalfSystemFillWindowIsAdjustedAboveTaskbar() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowBounds = CGRect(x: 960, y: 25, width: 960, height: 1055)

    let adjusted = ScreenGeometry.adjustedFrameAvoidingTaskbar(
        for: windowBounds,
        onDisplay: displayBounds,
        taskbarHeight: 40
    )

    #expect(adjusted?.minX == 960)
    #expect(adjusted?.height == 1015)
    #expect(adjusted?.maxY == 1040)
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
