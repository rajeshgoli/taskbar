import AppKit

enum AppsLauncher {
    private static let appsBundleIdentifier = "com.apple.apps.launcher"
    private static let appsPath = "/System/Applications/Apps.app"
    private static let legacyLaunchpadPath = "/System/Applications/Launchpad.app"

    static func open() {
        LauncherApplicationActivator.launch(
            bundleIdentifier: appsBundleIdentifier,
            applicationURL: applicationURL()
        )
    }

    static func applicationURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appsBundleIdentifier) {
            return url
        }

        for path in [appsPath, legacyLaunchpadPath] where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    static func icon() -> NSImage? {
        if let url = applicationURL() {
            return NSWorkspace.shared.icon(forFile: url.path).scaled(to: NSSize(width: 32, height: 32))
        }

        let image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Apps")
        image?.isTemplate = true
        return image
    }
}
