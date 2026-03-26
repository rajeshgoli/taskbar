import AppKit

struct ScreenGeometry {
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
            screen.frame.contains(CGPoint(x: windowBounds.origin.x, y: windowBounds.origin.y))
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

    /// Check if a window is on a specific display (within tolerance)
    static func isWindow(bounds: CGRect, onDisplay displayBounds: CGRect, tolerance: CGFloat = 2) -> Bool {
        let expandedDisplay = displayBounds.insetBy(dx: -tolerance, dy: -tolerance)
        return expandedDisplay.contains(CGPoint(x: bounds.midX, y: bounds.midY))
    }
}
