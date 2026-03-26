import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: TaskbarPanel?
    private var windowManager: WindowManager?
    private var permissionsManager: PermissionsManager?
    private var settings: TaskbarSettings?
    private var blacklistManager: BlacklistManager?
    private var settingsWindowController: SettingsWindowController?
    private var contentView: TaskbarContentView?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = TaskbarSettings()
        self.settings = settings

        let blacklistManager = BlacklistManager()
        self.blacklistManager = blacklistManager

        let permissions = PermissionsManager()
        permissionsManager = permissions

        let wm = WindowManager(blacklistManager: blacklistManager)
        windowManager = wm

        let contentView = TaskbarContentView(
            windowManager: wm,
            permissionsManager: permissions,
            settings: settings,
            blacklistManager: blacklistManager
        )
        self.contentView = contentView

        let taskbarPanel = TaskbarPanel(
            permissionsManager: permissions,
            settings: settings
        )
        taskbarPanel.setContentSubview(contentView)
        taskbarPanel.orderFrontRegardless()
        panel = taskbarPanel

        settingsWindowController = SettingsWindowController(
            settings: settings,
            blacklistManager: blacklistManager
        )
        configureStatusItem()

        permissions.$isAccessibilityGranted
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.contentView?.handleAccessibilityPermissionChange()
                self?.panel?.updateForAccessibilityPermissionChange()
            }
            .store(in: &cancellables)

        contentView.handleAccessibilityPermissionChange()
    }

    @objc
    private func openSettings(_ sender: Any?) {
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "gear",
                accessibilityDescription: "Settings"
            )
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }
}
