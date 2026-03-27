import AppKit

class SettingsWindowController: NSWindowController {
    convenience init(
        settings: TaskbarSettings,
        blacklistManager: BlacklistManager,
        pinnedAppManager: PinnedAppManager
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeskBar Settings"
        window.center()
        self.init(window: window)

        let settingsView = SettingsView(
            settings: settings,
            pinnedAppManager: pinnedAppManager,
            blacklistManager: blacklistManager
        )
        window.contentView = settingsView
    }
}
