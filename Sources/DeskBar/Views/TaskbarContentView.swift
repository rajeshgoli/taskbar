import AppKit
import ApplicationServices
import Combine
import Darwin

final class TaskbarContentView: NSView {
    private typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private let windowManager: WindowManager
    private let permissionsManager: PermissionsManager
    private let settings: TaskbarSettings
    private let blacklistManager: BlacklistManager
    private let pinnedAppManager: PinnedAppManager
    private let launcherZoneView: LauncherZoneView
    private let axGetWindow: AXUIElementGetWindowFunc?

    private let rootStackView = NSStackView()
    private let bannerButton = NSButton()
    private let zonesStackView = NSStackView()
    private let taskZoneScrollView = NSScrollView()
    private let taskZoneStackView = NSStackView()
    private let trayZoneStackView = NSStackView()

    private var cancellables = Set<AnyCancellable>()

    init(
        windowManager: WindowManager,
        permissionsManager: PermissionsManager,
        settings: TaskbarSettings,
        blacklistManager: BlacklistManager,
        pinnedAppManager: PinnedAppManager
    ) {
        self.windowManager = windowManager
        self.permissionsManager = permissionsManager
        self.settings = settings
        self.blacklistManager = blacklistManager
        self.pinnedAppManager = pinnedAppManager
        launcherZoneView = LauncherZoneView(
            pinnedAppManager: pinnedAppManager,
            windowManager: windowManager
        )
        if let symbol = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") {
            self.axGetWindow = unsafeBitCast(symbol, to: AXUIElementGetWindowFunc.self)
        } else {
            self.axGetWindow = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        configureLayout()
        bindState()
        updateTaskbarLayout()
        rebuildViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func handleAccessibilityPermissionChange() {
        launcherZoneView.refresh()
        rebuildViews()
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

        let trayContainer = makeZoneContainer(for: trayZoneStackView, width: 140)
        trayZoneStackView.orientation = .horizontal
        trayZoneStackView.alignment = .centerY
        trayZoneStackView.spacing = 6
        trayZoneStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        zonesStackView.addArrangedSubview(launcherZoneView)
        zonesStackView.addArrangedSubview(taskZoneContainer)
        zonesStackView.addArrangedSubview(makeDivider())
        zonesStackView.addArrangedSubview(trayContainer)
    }

    private func bindState() {
        windowManager.$windows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildViews()
            }
            .store(in: &cancellables)

        settings.$taskbarHeight
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateTaskbarLayout()
            }
            .store(in: &cancellables)

        pinnedAppManager.$pinnedApps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildViews()
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
                    self?.rebuildViews()
                }
                .store(in: &cancellables)
        }
    }

    private func rebuildViews() {
        bannerButton.isHidden = permissionsManager.isAccessibilityGranted

        taskZoneStackView.arrangedSubviews.forEach { view in
            taskZoneStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        trayZoneStackView.arrangedSubviews.forEach { view in
            trayZoneStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let runningApplications = regularRunningApplications()
        let pinnedBundleIdentifiers = Set(pinnedAppManager.pinnedApps.map(\.bundleIdentifier))
        let visibleApplicationPIDs = onScreenApplicationPIDs()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let appsWithoutVisibleWindows = Set(
            Dictionary(grouping: windowManager.windows, by: \.pid)
                .compactMap { pid, windows in
                    windows.allSatisfy { $0.isMinimized || $0.isHidden } ? pid : nil
                }
        )

        if permissionsManager.isAccessibilityGranted {
            for window in windowManager.windows where !appsWithoutVisibleWindows.contains(window.pid) {
                let buttonView = TaskButtonView(
                    windowInfo: window,
                    isActive: window.pid == frontmostPID,
                    isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
                    settings: settings,
                    blacklistManager: blacklistManager
                ) { [weak self] windowInfo in
                    self?.activate(windowInfo: windowInfo)
                }
                taskZoneStackView.addArrangedSubview(buttonView)
                buttonView.heightAnchor.constraint(equalToConstant: 32).isActive = true
            }
        } else {
            let taskItems: [TaskbarItem] = runningApplications.compactMap { application in
                guard visibleApplicationPIDs.contains(application.processIdentifier) else {
                    return nil
                }

                return TaskbarItem(
                    application: application,
                    title: application.localizedName ?? "Unknown"
                )
            }

            taskItems.forEach { item in
                let button = TaskbarAppButton(
                    application: item.application,
                    title: item.title,
                    isActive: item.application.processIdentifier == frontmostPID
                )
                button.target = self
                button.action = #selector(activateApplication(_:))
                button.menu = quitMenu(for: item.application)
                taskZoneStackView.addArrangedSubview(button)
            }
        }

        runningApplications
            .filter { application in
                !visibleApplicationPIDs.contains(application.processIdentifier) &&
                    !pinnedBundleIdentifiers.contains(application.bundleIdentifier ?? "")
            }
            .forEach { application in
                let button = TrayAppButton(application: application)
                button.target = self
                button.action = #selector(activateApplication(_:))
                trayZoneStackView.addArrangedSubview(button)
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

    private func regularRunningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }

    private func onScreenApplicationPIDs() -> Set<pid_t> {
        guard
            let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first,
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return []
        }

        return Set(windowList.compactMap { entry in
            guard
                let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width * bounds.height >= 100,
                screen.frame.intersects(bounds)
            else {
                return nil
            }

            return ownerPID
        })
    }

    private func makeZoneContainer(for contentView: NSView, width: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentView)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: container.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])

        return container
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 28)
        ])
        return divider
    }

    private func quitMenu(for application: NSRunningApplication) -> NSMenu {
        let menu = NSMenu()
        let menuItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApplication(_:)),
            keyEquivalent: ""
        )
        menuItem.representedObject = application
        menuItem.target = self
        menu.addItem(menuItem)
        return menu
    }

    @objc
    private func openAccessibilitySettings() {
        permissionsManager.openAccessibilitySettings()
    }

    @objc
    private func activateApplication(_ sender: NSButton) {
        (sender as? ApplicationRepresentable)?.application?
            .activate(options: .activateAllWindows)
    }

    @objc
    private func quitApplication(_ sender: NSMenuItem) {
        (sender.representedObject as? NSRunningApplication)?.terminate()
    }
}

private struct TaskbarItem {
    let application: NSRunningApplication
    let title: String
}

private protocol ApplicationRepresentable where Self: NSView {
    var application: NSRunningApplication? { get }
}

private final class TaskbarAppButton: NSButton, ApplicationRepresentable {
    let application: NSRunningApplication?

    init(application: NSRunningApplication, title: String, isActive: Bool) {
        self.application = application
        super.init(frame: .zero)

        self.title = title
        image = application.icon
        toolTip = title
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyUpOrDown
        font = NSFont.systemFont(ofSize: 13, weight: .medium)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = (
            isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.28)
                : NSColor.windowBackgroundColor.withAlphaComponent(0.24)
        ).cgColor
        contentTintColor = NSColor.labelColor
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            heightAnchor.constraint(equalToConstant: 30)
        ])

        if let buttonCell = cell as? NSButtonCell {
            buttonCell.lineBreakMode = .byTruncatingTail
            buttonCell.imageScaling = .scaleProportionallyDown
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class TrayAppButton: NSButton, ApplicationRepresentable {
    let application: NSRunningApplication?

    init(application: NSRunningApplication) {
        self.application = application
        super.init(frame: .zero)

        image = application.icon
        title = ""
        toolTip = application.localizedName
        imageScaling = .scaleProportionallyUpOrDown
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.2).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
