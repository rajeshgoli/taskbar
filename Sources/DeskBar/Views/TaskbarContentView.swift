import AppKit
import ApplicationServices
import Combine
import Darwin

final class TaskbarContentView: NSView {
    private typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private let windowManager: WindowManager
    private let badgeMonitor: BadgeMonitor
    private let permissionsManager: PermissionsManager
    private let settings: TaskbarSettings
    private let blacklistManager: BlacklistManager
    private let launcherZoneView: LauncherZoneView
    private let runningAppTrayView: RunningAppTrayView
    private let axGetWindow: AXUIElementGetWindowFunc?

    private let rootStackView = NSStackView()
    private let bannerButton = NSButton()
    private let zonesStackView = NSStackView()
    private let taskZoneScrollView = NSScrollView()
    private let taskZoneStackView = NSStackView()

    private var cancellables = Set<AnyCancellable>()

    init(
        windowManager: WindowManager,
        badgeMonitor: BadgeMonitor,
        permissionsManager: PermissionsManager,
        settings: TaskbarSettings,
        blacklistManager: BlacklistManager,
        pinnedAppManager: PinnedAppManager
    ) {
        self.windowManager = windowManager
        self.badgeMonitor = badgeMonitor
        self.permissionsManager = permissionsManager
        self.settings = settings
        self.blacklistManager = blacklistManager
        launcherZoneView = LauncherZoneView(
            settings: settings,
            pinnedAppManager: pinnedAppManager,
            windowManager: windowManager
        )
        runningAppTrayView = RunningAppTrayView(
            windowManager: windowManager,
            pinnedAppManager: pinnedAppManager
        )
        if let symbol = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") {
            axGetWindow = unsafeBitCast(symbol, to: AXUIElementGetWindowFunc.self)
        } else {
            axGetWindow = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        configureLayout()
        bindState()
        updateTaskbarLayout()
        rebuildTaskZone()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func handleAccessibilityPermissionChange() {
        launcherZoneView.refresh()
        rebuildTaskZone()
    }

    private func configureLayout() {
        rootStackView.orientation = .vertical
        rootStackView.alignment = .leading
        rootStackView.distribution = .fill
        rootStackView.spacing = 0
        rootStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStackView)

        NSLayoutConstraint.activate([
            rootStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStackView.topAnchor.constraint(equalTo: topAnchor),
            rootStackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        bannerButton.title = "Accessibility permission required — Click to grant"
        bannerButton.isBordered = false
        bannerButton.bezelStyle = .regularSquare
        bannerButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        bannerButton.contentTintColor = NSColor.black.withAlphaComponent(0.85)
        bannerButton.alignment = .center
        bannerButton.wantsLayer = true
        bannerButton.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
        bannerButton.translatesAutoresizingMaskIntoConstraints = false
        bannerButton.target = self
        bannerButton.action = #selector(openAccessibilitySettings)
        rootStackView.addArrangedSubview(bannerButton)

        NSLayoutConstraint.activate([
            bannerButton.leadingAnchor.constraint(equalTo: rootStackView.leadingAnchor),
            bannerButton.trailingAnchor.constraint(equalTo: rootStackView.trailingAnchor),
            bannerButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        zonesStackView.orientation = .horizontal
        zonesStackView.alignment = .centerY
        zonesStackView.distribution = .fill
        zonesStackView.spacing = 0
        zonesStackView.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        zonesStackView.translatesAutoresizingMaskIntoConstraints = false
        rootStackView.addArrangedSubview(zonesStackView)

        NSLayoutConstraint.activate([
            zonesStackView.leadingAnchor.constraint(equalTo: rootStackView.leadingAnchor),
            zonesStackView.trailingAnchor.constraint(equalTo: rootStackView.trailingAnchor)
        ])

        let taskZoneContainer = NSView()
        taskZoneContainer.translatesAutoresizingMaskIntoConstraints = false
        taskZoneContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        taskZoneContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        taskZoneScrollView.drawsBackground = false
        taskZoneScrollView.borderType = .noBorder
        taskZoneScrollView.hasHorizontalScroller = false
        taskZoneScrollView.hasVerticalScroller = false
        taskZoneScrollView.autohidesScrollers = true
        taskZoneScrollView.translatesAutoresizingMaskIntoConstraints = false
        taskZoneContainer.addSubview(taskZoneScrollView)

        NSLayoutConstraint.activate([
            taskZoneScrollView.leadingAnchor.constraint(equalTo: taskZoneContainer.leadingAnchor),
            taskZoneScrollView.trailingAnchor.constraint(equalTo: taskZoneContainer.trailingAnchor),
            taskZoneScrollView.topAnchor.constraint(equalTo: taskZoneContainer.topAnchor),
            taskZoneScrollView.bottomAnchor.constraint(equalTo: taskZoneContainer.bottomAnchor),
            taskZoneContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])

        taskZoneStackView.orientation = .horizontal
        taskZoneStackView.alignment = .centerY
        taskZoneStackView.spacing = 8
        taskZoneStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        taskZoneStackView.translatesAutoresizingMaskIntoConstraints = false

        let taskZoneDocumentView = NSView()
        taskZoneDocumentView.translatesAutoresizingMaskIntoConstraints = false
        taskZoneDocumentView.addSubview(taskZoneStackView)

        NSLayoutConstraint.activate([
            taskZoneStackView.leadingAnchor.constraint(equalTo: taskZoneDocumentView.leadingAnchor),
            taskZoneStackView.trailingAnchor.constraint(equalTo: taskZoneDocumentView.trailingAnchor),
            taskZoneStackView.topAnchor.constraint(equalTo: taskZoneDocumentView.topAnchor),
            taskZoneStackView.bottomAnchor.constraint(equalTo: taskZoneDocumentView.bottomAnchor)
        ])

        taskZoneScrollView.documentView = taskZoneDocumentView

        zonesStackView.addArrangedSubview(launcherZoneView)
        zonesStackView.addArrangedSubview(taskZoneContainer)
        zonesStackView.addArrangedSubview(runningAppTrayView)
    }

    private func bindState() {
        windowManager.$visibleWindows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        badgeMonitor.$appBadges
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        settings.$taskbarHeight
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateTaskbarLayout()
            }
            .store(in: &cancellables)

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        let notificationNames: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        notificationNames.forEach { name in
            workspaceNotifications.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.rebuildTaskZone()
                }
                .store(in: &cancellables)
        }
    }

    private func rebuildTaskZone() {
        bannerButton.isHidden = permissionsManager.isAccessibilityGranted

        taskZoneStackView.arrangedSubviews.forEach { view in
            taskZoneStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for window in windowManager.visibleWindows {
            let buttonView = TaskButtonView(
                windowInfo: window,
                isActive: window.pid == frontmostPID,
                hasBadge: window.bundleIdentifier.flatMap { badgeMonitor.appBadges[$0] } ?? false,
                isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
                settings: settings,
                blacklistManager: blacklistManager
            ) { [weak self] windowInfo in
                self?.activate(windowInfo: windowInfo)
            }
            taskZoneStackView.addArrangedSubview(buttonView)
            buttonView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
    }

    private func updateTaskbarLayout() {
        let verticalInset = max(0, floor((settings.taskbarHeight - 32) / 2))
        zonesStackView.edgeInsets = NSEdgeInsets(
            top: verticalInset,
            left: 10,
            bottom: verticalInset,
            right: 10
        )
        layoutSubtreeIfNeeded()
    }

    private func activate(windowInfo: WindowInfo) {
        guard let application = NSWorkspace.shared.runningApplications.first(
            where: { $0.processIdentifier == windowInfo.pid }
        ) else {
            return
        }

        if windowInfo.isHidden {
            application.unhide()
        }

        if windowInfo.isMinimized {
            unminimize(windowInfo: windowInfo, application: application)
            return
        }

        application.activate(options: .activateAllWindows)
    }

    private func unminimize(windowInfo: WindowInfo, application: NSRunningApplication) {
        guard let windowElement = matchingWindowElement(for: windowInfo, application: application) else {
            application.activate(options: .activateAllWindows)
            return
        }

        _ = AXUIElementSetAttributeValue(
            windowElement,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        )
        _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        application.activate(options: .activateAllWindows)
    }

    private func matchingWindowElement(
        for windowInfo: WindowInfo,
        application: NSRunningApplication
    ) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
            let values = value as? [Any]
        else {
            return nil
        }

        let windows = values.compactMap { value -> AXUIElement? in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(cfValue, to: AXUIElement.self)
        }

        if let cgWindowID = windowInfo.cgWindowID,
           let matchedByID = windows.first(where: { axWindowID(for: $0) == cgWindowID }) {
            return matchedByID
        }

        let trimmedTitle = windowInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty,
           let matchedByTitle = windows.first(where: { axTitle(for: $0) == trimmedTitle }) {
            return matchedByTitle
        }

        return windows.first(where: { axIsMinimized($0) == windowInfo.isMinimized })
    }

    private func axWindowID(for element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else {
            return nil
        }

        var windowID: CGWindowID = 0
        let error = axGetWindow(element, &windowID)

        guard error == .success, windowID != 0 else {
            return nil
        }

        return windowID
    }

    private func axTitle(for element: AXUIElement) -> String? {
        var value: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
            let title = value as? String
        else {
            return nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    private func axIsMinimized(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success,
            let isMinimized = value as? Bool
        else {
            return false
        }

        return isMinimized
    }

    @objc
    private func openAccessibilitySettings() {
        permissionsManager.openAccessibilitySettings()
    }
}
