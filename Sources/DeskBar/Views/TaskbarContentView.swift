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
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var expandedGroupID: String?
    private weak var expandedGroupView: NSView?

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
        installCollapseMonitors()
        updateTaskbarLayout()
        rebuildTaskZone()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }

        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
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

        settings.$groupByApp
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else {
                    return
                }

                if !isEnabled {
                    self.expandedGroupID = nil
                }

                self.rebuildTaskZone()
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
        expandedGroupView = nil

        taskZoneStackView.arrangedSubviews.forEach { view in
            taskZoneStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if settings.groupByApp {
            for item in groupedTaskItems(from: windowManager.visibleWindows) {
                switch item {
                case .window(let window):
                    addTaskButton(for: window, frontmostPID: frontmostPID)
                case .group(let group):
                    let groupView = makeGroupView(for: group, frontmostPID: frontmostPID)
                    taskZoneStackView.addArrangedSubview(groupView)
                    groupView.heightAnchor.constraint(equalToConstant: 32).isActive = true

                    if group.isExpanded {
                        expandedGroupView = groupView
                    }
                }
            }
            return
        }

        expandedGroupID = nil

        for window in windowManager.visibleWindows {
            addTaskButton(for: window, frontmostPID: frontmostPID)
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

    private func addTaskButton(for window: WindowInfo, frontmostPID: pid_t?) {
        let buttonView = TaskButtonView(
            windowInfo: window,
            isActive: window.pid == frontmostPID,
            hasBadge: hasBadge(for: window.bundleIdentifier),
            isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
            settings: settings,
            blacklistManager: blacklistManager
        ) { [weak self] windowInfo in
            self?.activate(windowInfo: windowInfo)
        }
        taskZoneStackView.addArrangedSubview(buttonView)
        buttonView.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    private func makeGroupView(for group: AppGroup, frontmostPID: pid_t?) -> NSView {
        let groupStackView = NSStackView()
        groupStackView.translatesAutoresizingMaskIntoConstraints = false
        groupStackView.orientation = .horizontal
        groupStackView.alignment = .centerY
        groupStackView.spacing = taskZoneStackView.spacing
        groupStackView.edgeInsets = NSEdgeInsetsZero
        groupStackView.distribution = .fill

        let headerView = GroupHeaderButton(
            appGroup: group,
            hasBadge: hasBadge(for: group.id),
            isActive: group.windows.contains { $0.pid == frontmostPID }
        ) { [weak self] in
            self?.toggleGroupExpansion(for: group.id)
        }
        groupStackView.addArrangedSubview(headerView)
        headerView.heightAnchor.constraint(equalToConstant: 32).isActive = true

        if group.isExpanded {
            for window in group.windows {
                let buttonView = TaskButtonView(
                    windowInfo: window,
                    isActive: window.pid == frontmostPID,
                    hasBadge: hasBadge(for: window.bundleIdentifier),
                    isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
                    settings: settings,
                    blacklistManager: blacklistManager
                ) { [weak self] windowInfo in
                    self?.activate(windowInfo: windowInfo)
                }
                groupStackView.addArrangedSubview(buttonView)
                buttonView.heightAnchor.constraint(equalToConstant: 32).isActive = true
            }
        }

        return groupStackView
    }

    private func groupedTaskItems(from windows: [WindowInfo]) -> [TaskZoneItem] {
        var groups: [AppGroup] = []
        var groupIndexes: [String: Int] = [:]

        for window in windows {
            let groupID = resolvedGroupID(for: window)

            if let index = groupIndexes[groupID] {
                groups[index].windows.append(window)
            } else {
                groupIndexes[groupID] = groups.count
                groups.append(
                    AppGroup(
                        id: groupID,
                        appName: window.appName,
                        icon: window.icon,
                        windows: [window]
                    )
                )
            }
        }

        let multiWindowGroupIDs = Set(
            groups
                .filter { $0.windowCount > 1 }
                .map(\.id)
        )

        if let expandedGroupID, !multiWindowGroupIDs.contains(expandedGroupID) {
            self.expandedGroupID = nil
        }

        return groups.map { group in
            if group.windowCount == 1, let window = group.windows.first {
                return .window(window)
            }

            var expandedGroup = group
            expandedGroup.isExpanded = expandedGroup.id == expandedGroupID
            return .group(expandedGroup)
        }
    }

    private func resolvedGroupID(for window: WindowInfo) -> String {
        if let bundleIdentifier = window.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return "pid-\(window.pid)-\(window.appName)"
    }

    private func hasBadge(for bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return badgeMonitor.appBadges[bundleIdentifier] ?? false
    }

    private func toggleGroupExpansion(for groupID: String) {
        expandedGroupID = expandedGroupID == groupID ? nil : groupID
        rebuildTaskZone()
    }

    private func collapseExpandedGroup() {
        guard expandedGroupID != nil else {
            return
        }

        expandedGroupID = nil
        rebuildTaskZone()
    }

    private func installCollapseMonitors() {
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleLocalClick(event)
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.collapseExpandedGroup()
            }
        }
    }

    private func handleLocalClick(_ event: NSEvent) {
        guard expandedGroupID != nil else {
            return
        }

        guard event.window === window else {
            collapseExpandedGroup()
            return
        }

        let pointInView = convert(event.locationInWindow, from: nil)
        guard let expandedGroupView else {
            collapseExpandedGroup()
            return
        }

        let expandedFrame = expandedGroupView.convert(expandedGroupView.bounds, to: self)
        if !expandedFrame.contains(pointInView) {
            collapseExpandedGroup()
        }
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

private enum TaskZoneItem {
    case window(WindowInfo)
    case group(AppGroup)
}
