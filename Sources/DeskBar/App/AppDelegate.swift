import AppKit
import Combine
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panels: [CGDirectDisplayID: TaskbarPanel] = [:]
    private var contentViews: [CGDirectDisplayID: TaskbarContentView] = [:]
    private var windowManager: WindowManager?
    private var permissionsManager: PermissionsManager?
    private var settings: TaskbarSettings?
    private var dockManager: DockManager?
    private var blacklistManager: BlacklistManager?
    private var pinnedAppManager: PinnedAppManager?
    private var loginItemManager: LoginItemManager?
    private var badgeMonitor: BadgeMonitor?
    private var settingsWindowController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []
    private var isHandlingTerminationSignal = false
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = TaskbarSettings()
        self.settings = settings
        loginItemManager = LoginItemManager(settings: settings)

        let dockManager = DockManager()
        self.dockManager = dockManager

        let blacklistManager = BlacklistManager()
        self.blacklistManager = blacklistManager

        let permissions = PermissionsManager()
        permissionsManager = permissions

        let pinnedAppManager = PinnedAppManager()
        self.pinnedAppManager = pinnedAppManager

        let wm = WindowManager(
            blacklistManager: blacklistManager,
            pinnedAppManager: pinnedAppManager
        )
        windowManager = wm

        let badgeMonitor = BadgeMonitor()
        self.badgeMonitor = badgeMonitor

        configureObservers(
            windowManager: wm,
            permissionsManager: permissions,
            settings: settings
        )
        refreshPanelsForCurrentConfiguration()
        DispatchQueue.main.async { [weak self] in
            self?.refreshPanelsForCurrentConfiguration()
        }

        settingsWindowController = SettingsWindowController(
            settings: settings,
            blacklistManager: blacklistManager,
            pinnedAppManager: pinnedAppManager
        )
        configureStatusItem()
        bindDockMode(settings: settings)
        configureSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
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

    private func configureObservers(
        windowManager: WindowManager,
        permissionsManager: PermissionsManager,
        settings: TaskbarSettings
    ) {
        permissionsManager.$isAccessibilityGranted
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleAccessibilityPermissionChange()
            }
            .store(in: &cancellables)

        settings.$showOnAllMonitors
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshPanelsForCurrentConfiguration()
            }
            .store(in: &cancellables)

        settings.$showOverFullScreenApps
            .receive(on: RunLoop.main)
            .sink { [weak self] showOverFullScreenApps in
                guard let self else {
                    return
                }

                self.panels.values.forEach {
                    $0.updateCollectionBehavior(showOverFullScreenApps: showOverFullScreenApps)
                }
                self.updatePanelVisibility()
            }
            .store(in: &cancellables)

        windowManager.$windows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePanelVisibility()
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPanelsForCurrentConfiguration()
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]

        workspaceObservers = workspaceNames.map { name in
            workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updatePanelVisibility()
            }
        }
    }

    private func reconcilePanels() {
        guard
            let settings,
            let windowManager,
            let permissionsManager,
            let badgeMonitor,
            let blacklistManager,
            let pinnedAppManager
        else {
            return
        }

        let targetScreens = screensToShow(showOnAllMonitors: settings.showOnAllMonitors)
        let targetIDs = Set(targetScreens.compactMap(ScreenGeometry.displayID(for:)))

        for screen in targetScreens {
            guard let displayID = ScreenGeometry.displayID(for: screen) else {
                continue
            }

            if let panel = panels[displayID] {
                panel.updateFrame(for: screen)
                continue
            }

            let contentView = TaskbarContentView(
                windowManager: windowManager,
                badgeMonitor: badgeMonitor,
                permissionsManager: permissionsManager,
                settings: settings,
                blacklistManager: blacklistManager,
                pinnedAppManager: pinnedAppManager,
                displayID: displayID
            )
            let panel = TaskbarPanel(
                permissionsManager: permissionsManager,
                settings: settings,
                screen: screen
            )
            panel.updateCollectionBehavior(showOverFullScreenApps: settings.showOverFullScreenApps)
            panel.setContentSubview(contentView)

            contentViews[displayID] = contentView
            panels[displayID] = panel
        }

        let staleDisplayIDs = Set(panels.keys).subtracting(targetIDs)
        for displayID in staleDisplayIDs {
            panels[displayID]?.orderOut(nil)
            panels.removeValue(forKey: displayID)
            contentViews.removeValue(forKey: displayID)
        }
    }

    private func refreshPanelsForCurrentConfiguration() {
        reconcilePanels()
        handleAccessibilityPermissionChange()
        updatePanelVisibility()
    }

    private func updatePanelVisibility() {
        guard let settings, let windowManager else {
            return
        }

        if settings.showOverFullScreenApps {
            panels.values.forEach { $0.orderFront(nil) }
            return
        }

        for (displayID, panel) in panels {
            guard let screen = ScreenGeometry.screen(for: displayID) else {
                panel.orderOut(nil)
                continue
            }

            if windowManager.hasFullScreenWindow(on: screen) {
                panel.orderOut(nil)
            } else {
                panel.orderFront(nil)
            }
        }
    }

    private func handleAccessibilityPermissionChange() {
        contentViews.values.forEach { $0.handleAccessibilityPermissionChange() }
        panels.values.forEach { $0.updateForAccessibilityPermissionChange() }
    }

    private func screensToShow(showOnAllMonitors: Bool) -> [NSScreen] {
        if showOnAllMonitors {
            return NSScreen.screens
        }

        if let mainScreen = NSScreen.main {
            return [mainScreen]
        }

        return NSScreen.screens.prefix(1).map { $0 }
    }
}
