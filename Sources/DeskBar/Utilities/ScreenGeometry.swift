import AppKit

struct ScreenGeometry {
    private static let fullScreenTolerance: CGFloat = 2
    private static let menuBarInset: CGFloat = 25
    private static let systemFillTolerance: CGFloat = 24
    private static let minimumSystemFillHeightRatio: CGFloat = 0.6
    private static let frameBorderTolerance: CGFloat = 2

    /// Calculate the taskbar frame for a given screen
    static func taskbarFrame(for screen: NSScreen, height: CGFloat = 40) -> NSRect {
        NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y,
            width: screen.frame.width,
            height: height
        )
    }

    /// Find which screen a window belongs to based on its bounds.
    static func screen(for windowBounds: CGRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            isWindow(bounds: windowBounds, onDisplay: displayBounds(for: screen))
        }
    }

    /// Get the main display bounds for CGWindowList filtering
    static func mainDisplayBounds() -> CGRect {
        guard let main = NSScreen.main else { return .zero }
        return CGRect(
            x: main.frame.origin.x,
            y: main.frame.origin.y,
            width: main.frame.width,
            height: main.frame.height
        )
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    static func screen(for targetDisplayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(for: $0) == targetDisplayID }
    }

    static func displayBounds(for screen: NSScreen) -> CGRect {
        if let displayID = displayID(for: screen) {
            return CGDisplayBounds(displayID)
        }

        return screen.frame
    }

    static func topInset(for screen: NSScreen) -> CGFloat {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Check if a window belongs to a specific display.
    ///
    /// CGWindowList can include frame shadows/borders that extend a point
    /// outside the owning display. Preserve origin-based routing for normal and
    /// partially off-screen windows, then fall back to midpoint routing only
    /// when the origin is within the frame-border tolerance of the display.
    static func isWindow(bounds: CGRect, onDisplay displayBounds: CGRect) -> Bool {
        if displayBounds.contains(bounds.origin) {
            return true
        }

        let expandedDisplayBounds = displayBounds.insetBy(
            dx: -frameBorderTolerance,
            dy: -frameBorderTolerance
        )
        guard expandedDisplayBounds.contains(bounds.origin) else {
            return false
        }

        return displayBounds.contains(CGPoint(x: bounds.midX, y: bounds.midY))
    }

    static func matchesFullScreenWindow(bounds: CGRect, onDisplay displayBounds: CGRect) -> Bool {
        guard
            nearlyEqual(bounds.minX, displayBounds.minX),
            nearlyEqual(bounds.maxX, displayBounds.maxX),
            nearlyEqual(bounds.maxY, displayBounds.maxY)
        else {
            return false
        }

        return nearlyEqual(bounds.minY, displayBounds.minY) ||
            nearlyEqual(bounds.minY, displayBounds.minY + menuBarInset)
    }

    static func adjustedFrameAvoidingTaskbar(
        for frame: CGRect,
        on screen: NSScreen,
        taskbarHeight: CGFloat
    ) -> CGRect? {
        adjustedFrameAvoidingTaskbar(
            for: frame,
            onDisplay: displayBounds(for: screen),
            topInset: topInset(for: screen),
            taskbarHeight: taskbarHeight
        )
    }

    static func adjustedFrameAvoidingTaskbar(
        for frame: CGRect,
        onDisplay displayBounds: CGRect,
        taskbarHeight: CGFloat
    ) -> CGRect? {
        adjustedFrameAvoidingTaskbar(
            for: frame,
            onDisplay: displayBounds,
            topInset: menuBarInset,
            taskbarHeight: taskbarHeight
        )
    }

    static func adjustedFrameAvoidingTaskbar(
        for frame: CGRect,
        onDisplay displayBounds: CGRect,
        topInset: CGFloat,
        taskbarHeight: CGFloat
    ) -> CGRect? {
        guard resemblesSystemFillWindow(frame: frame, onDisplay: displayBounds, topInset: topInset) else {
            return nil
        }

        let taskbarTop = displayBounds.maxY - taskbarHeight
        guard frame.maxY > taskbarTop + fullScreenTolerance else {
            return nil
        }

        let adjustedHeight = taskbarTop - frame.minY
        guard adjustedHeight > 100 else {
            return nil
        }

        return CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: adjustedHeight
        )
    }

    static func resemblesSystemFillWindow(
        frame: CGRect,
        onDisplay displayBounds: CGRect,
        topInset: CGFloat = menuBarInset
    ) -> Bool {
        guard
            isTopAlignedSystemFill(frame: frame, onDisplay: displayBounds, topInset: topInset),
            frame.height >= displayBounds.height * minimumSystemFillHeightRatio
        else {
            return false
        }

        return resemblesFullWidthFill(frame: frame, onDisplay: displayBounds) ||
            resemblesHalfWidthFill(frame: frame, onDisplay: displayBounds)
    }

    private static func isTopAlignedSystemFill(
        frame: CGRect,
        onDisplay displayBounds: CGRect,
        topInset: CGFloat
    ) -> Bool {
        nearlyEqual(frame.minY, displayBounds.minY) ||
            nearlyEqual(frame.minY, displayBounds.minY + topInset)
    }

    private static func resemblesFullWidthFill(frame: CGRect, onDisplay displayBounds: CGRect) -> Bool {
        nearlyEqual(frame.minX, displayBounds.minX, tolerance: systemFillTolerance) &&
            nearlyEqual(frame.width, displayBounds.width, tolerance: systemFillTolerance)
    }

    private static func resemblesHalfWidthFill(frame: CGRect, onDisplay displayBounds: CGRect) -> Bool {
        let expectedWidth = displayBounds.width / 2
        guard nearlyEqual(frame.width, expectedWidth, tolerance: systemFillTolerance) else {
            return false
        }

        return nearlyEqual(frame.minX, displayBounds.minX, tolerance: systemFillTolerance) ||
            nearlyEqual(frame.maxX, displayBounds.maxX, tolerance: systemFillTolerance)
    }

    private static func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        nearlyEqual(lhs, rhs, tolerance: fullScreenTolerance)
    }

    private static func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
