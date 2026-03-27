import AppKit
import Combine
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: TaskbarPanel?
    private var windowManager: WindowManager?
    private var permissionsManager: PermissionsManager?
    private var settings: TaskbarSettings?
    private var dockManager: DockManager?
    private var blacklistManager: BlacklistManager?
    private var pinnedAppManager: PinnedAppManager?
    private var settingsWindowController: SettingsWindowController?
    private var contentView: TaskbarContentView?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []
    private var isHandlingTerminationSignal = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = TaskbarSettings()
        self.settings = settings

        let dockManager = DockManager()
        self.dockManager = dockManager

        let blacklistManager = BlacklistManager()
        self.blacklistManager = blacklistManager

        let permissions = PermissionsManager()
        permissionsManager = permissions

        let pinnedAppManager = PinnedAppManager()
        self.pinnedAppManager = pinnedAppManager

        let wm = WindowManager(blacklistManager: blacklistManager)
        windowManager = wm

        let contentView = TaskbarContentView(
            windowManager: wm,
            permissionsManager: permissions,
            settings: settings,
            blacklistManager: blacklistManager,
            pinnedAppManager: pinnedAppManager
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
            blacklistManager: blacklistManager,
            pinnedAppManager: pinnedAppManager
        )
        configureStatusItem()

        permissions.$isAccessibilityGranted
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.contentView?.handleAccessibilityPermissionChange()
                self?.panel?.updateForAccessibilityPermissionChange()
            }
            .store(in: &cancellables)

        bindDockMode(settings: settings)
        configureSignalHandlers()
        contentView.handleAccessibilityPermissionChange()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockManager?.restoreDockState()
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

    private func bindDockMode(settings: TaskbarSettings) {
        dockManager?.apply(mode: settings.dockMode)

        settings.$dockMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.dockManager?.apply(mode: mode)
            }
            .store(in: &cancellables)
    }

    private func configureSignalHandlers() {
        [SIGTERM, SIGINT].forEach { signalNumber in
            signal(signalNumber, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else {
                    return
                }

                self.dockManager?.restoreDockState()

                guard !self.isHandlingTerminationSignal else {
                    return
                }

                self.isHandlingTerminationSignal = true
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
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
