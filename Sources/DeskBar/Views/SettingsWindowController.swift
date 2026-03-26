import AppKit

class SettingsWindowController: NSWindowController {
    convenience init(settings: TaskbarSettings) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeskBar Settings"
        window.center()
        self.init(window: window)

        let settingsView = SettingsView(settings: settings)
        window.contentView = settingsView
    }
}
