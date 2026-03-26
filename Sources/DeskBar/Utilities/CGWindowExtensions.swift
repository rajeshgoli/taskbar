import AppKit

struct CGWindowHelpers {
    /// Get all on-screen windows as dictionaries
    static func onScreenWindows() -> [[String: Any]] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windowList
    }

    /// Extract window bounds from a CGWindowList entry
    static func windowBounds(from entry: [String: Any]) -> CGRect? {
        guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
        guard let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let w = boundsDict["Width"] as? CGFloat,
              let h = boundsDict["Height"] as? CGFloat else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Check if a window entry is eligible for display in the taskbar
    static func isEligible(_ entry: [String: Any]) -> Bool {
        // Layer must be 0 (normal window layer)
        guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { return false }

        // Alpha must be > 0
        guard let alpha = entry[kCGWindowAlpha as String] as? Float, alpha > 0 else { return false }

        // Bounds area must be >= 100px
        guard let bounds = windowBounds(from: entry) else { return false }
        guard bounds.width * bounds.height >= 100 else { return false }

        return true
    }

    /// Get the pid from a window entry
    static func pid(from entry: [String: Any]) -> pid_t? {
        entry[kCGWindowOwnerPID as String] as? pid_t
    }

    /// Get the window ID from a window entry
    static func windowID(from entry: [String: Any]) -> CGWindowID? {
        entry[kCGWindowNumber as String] as? CGWindowID
    }
}
