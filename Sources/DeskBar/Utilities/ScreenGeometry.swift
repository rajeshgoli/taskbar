import AppKit

struct ScreenGeometry {
    private static let fullScreenTolerance: CGFloat = 2
    private static let menuBarInset: CGFloat = 25

    /// Calculate the taskbar frame for a given screen
    static func taskbarFrame(for screen: NSScreen, height: CGFloat = 40) -> NSRect {
        NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y,
            width: screen.frame.width,
            height: height
        )
    }

    /// Find which screen a window belongs to based on its bounds
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

    /// Check if a window belongs to a specific display using CGDisplayBounds containment.
    static func isWindow(bounds: CGRect, onDisplay displayBounds: CGRect) -> Bool {
        displayBounds.contains(bounds.origin)
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

    private static func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= fullScreenTolerance
    }
}
