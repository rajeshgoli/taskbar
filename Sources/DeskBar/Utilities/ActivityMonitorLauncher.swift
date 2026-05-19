import AppKit
import ApplicationServices

enum ActivityMonitorPane {
    case cpu
    case memory
    case gpu
}

enum ActivityMonitorLauncher {
    private static let bundleIdentifier = "com.apple.ActivityMonitor"

    static func open(_ pane: ActivityMonitorPane) {
        guard let applicationURL = activityMonitorURL() else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            if let error {
                print("DeskBar: failed to open Activity Monitor: \(error.localizedDescription)")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                runNavigation(for: pane)
            }
        }
    }

    static func navigationScript(for pane: ActivityMonitorPane) -> String {
        switch pane {
        case .cpu:
            return historyWindowScript(menuItemTitle: "CPU History", fallbackCommandNumber: "3")
        case .memory:
            return paneScript(commandNumber: "2")
        case .gpu:
            return historyWindowScript(menuItemTitle: "GPU History", fallbackCommandNumber: "6")
        }
    }

    private static func paneScript(commandNumber: String) -> String {
        return """
        tell application "Activity Monitor" to activate
        tell application "System Events"
            if exists process "Activity Monitor" then
                tell process "Activity Monitor"
                    set frontmost to true
                    keystroke "\(commandNumber)" using command down
                end tell
            end if
        end tell
        """
    }

    private static func historyWindowScript(menuItemTitle: String, fallbackCommandNumber: String) -> String {
        return """
        tell application "Activity Monitor" to activate
        tell application "System Events"
            if exists process "Activity Monitor" then
                tell process "Activity Monitor"
                    set frontmost to true
                    try
                        click menu item "\(menuItemTitle)" of menu "Window" of menu bar item "Window" of menu bar 1
                    on error
                        keystroke "\(fallbackCommandNumber)" using command down
                    end try
                end tell
            end if
        end tell
        """
    }

    private static func activityMonitorURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }

        let fallbackPaths = [
            "/System/Applications/Utilities/Activity Monitor.app",
            "/Applications/Utilities/Activity Monitor.app"
        ]

        return fallbackPaths
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func runNavigationScript(for pane: ActivityMonitorPane) {
        var errorInfo: NSDictionary?
        NSAppleScript(source: navigationScript(for: pane))?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            print("DeskBar: failed to select Activity Monitor pane: \(errorInfo)")
        }
    }

    private static func runNavigation(for pane: ActivityMonitorPane) {
        switch pane {
        case .cpu:
            if pressActivityMonitorWindowMenuItem(title: "CPU History") {
                return
            }
        case .gpu:
            if pressActivityMonitorWindowMenuItem(title: "GPU History") {
                return
            }
        case .memory:
            break
        }

        runNavigationScript(for: pane)
    }

    private static func pressActivityMonitorWindowMenuItem(title: String) -> Bool {
        guard
            AXIsProcessTrusted(),
            let application = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else {
            return false
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard
            let menuBar = axAttribute(appElement, kAXMenuBarAttribute as CFString),
            let windowMenuBarItem = axChildren(of: menuBar).first(where: { axTitle(of: $0) == "Window" })
        else {
            return false
        }

        AXUIElementPerformAction(windowMenuBarItem, kAXPressAction as CFString)

        guard let menu = waitForMenu(ownedBy: windowMenuBarItem) else {
            return false
        }

        guard let menuItem = axChildren(of: menu).first(where: { axTitle(of: $0) == title }) else {
            return false
        }

        return AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success
    }

    private static func waitForMenu(ownedBy menuBarItem: AXUIElement) -> AXUIElement? {
        for _ in 0 ..< 8 {
            if let menu = axChildren(of: menuBarItem).first(where: { axRole(of: $0) == kAXMenuRole as String }) {
                return menu
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        return nil
    }

    private static func axAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(cfValue, to: AXUIElement.self)
    }

    private static func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let values = value as? [Any] else {
            return []
        }

        return values.compactMap { value in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(cfValue, to: AXUIElement.self)
        }
    }

    private static func axTitle(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private static func axRole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }
}
