import AppKit
import ApplicationServices
import Combine
import Darwin

final class TaskbarContentView: NSView {
    private typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private let windowManager: WindowManager
    private let badgeMonitor: BadgeMonitor
    private let appStateMonitor: AppStateMonitor
    private let smPluginService: SMPluginService?
    private let permissionsManager: PermissionsManager
    private let settings: TaskbarSettings
    private let blacklistManager: BlacklistManager
    private let displayID: CGDirectDisplayID
    private let launcherZoneView: LauncherZoneView
    private let systemResourceWidgetView: SystemResourceWidgetView
    private let runningAppTrayView: RunningAppTrayView
    private let axGetWindow: AXUIElementGetWindowFunc?
    private let accessibilityService = AccessibilityService()

    private let rootStackView = NSStackView()
    private let bannerButton = NSButton()
    private let zonesStackView = NSStackView()
    private let taskZoneLayoutStackView = NSStackView()
    private let leftTaskZoneStackView = NSStackView()
    private let neutralTaskZoneStackView = NSStackView()
    private let rightTaskZoneStackView = NSStackView()
    private let leftTaskZoneSeparatorView = TaskZoneSeparatorView()
    private let rightTaskZoneSeparatorView = TaskZoneSeparatorView()
    private let clusterLeadingSpacerView = TaskZoneFlexibleSpacerView()
    private let clusterTrailingSpacerView = TaskZoneFlexibleSpacerView()
    private let minimumZoneContentHeight: CGFloat = 32
    private let taskZoneItemSpacing: CGFloat = 8
    private let taskZoneGroupSpacing: CGFloat = 12
    private let compactTaskZoneSpacerWidth: CGFloat = 8

    private let pinnedAppManager: PinnedAppManager
    private let thumbnailService: ThumbnailService?
    private let openSettingsHandler: () -> Void
    private let taskZoneContainer = NSView()
    private var cancellables = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var expandedGroupID: String?
    private weak var expandedGroupView: NSView?
    private var clusterSpacerEqualWidthConstraint: NSLayoutConstraint?
    private var groupedTaskOrderState = TaskZoneOrderingState()
    private var ungroupedTaskOrderState = TaskZoneOrderingState()
    private var taskItemViews: [String: NSView] = [:]
    private var preferredWidthNotificationScheduled = false
    private var lastNotifiedPreferredCompactWidth: CGFloat?
    private var isActivityModeActive = false
    private var previousBadgedBundleIdentifiers = Set<String>()

    var preferredWidthDidChange: (() -> Void)?

    init(
        windowManager: WindowManager,
        badgeMonitor: BadgeMonitor,
        appStateMonitor: AppStateMonitor,
        smPluginService: SMPluginService? = nil,
        permissionsManager: PermissionsManager,
        settings: TaskbarSettings,
        blacklistManager: BlacklistManager,
        pinnedAppManager: PinnedAppManager,
        systemResourceMonitor: SystemResourceMonitor,
        thumbnailService: ThumbnailService? = nil,
        displayID: CGDirectDisplayID,
        openSettingsHandler: @escaping () -> Void
    ) {
        self.windowManager = windowManager
        self.badgeMonitor = badgeMonitor
        self.appStateMonitor = appStateMonitor
        self.smPluginService = smPluginService
        self.permissionsManager = permissionsManager
        self.settings = settings
        self.blacklistManager = blacklistManager
        self.pinnedAppManager = pinnedAppManager
        self.thumbnailService = thumbnailService
        self.displayID = displayID
        self.openSettingsHandler = openSettingsHandler
        launcherZoneView = LauncherZoneView(
            settings: settings,
            pinnedAppManager: pinnedAppManager,
            windowManager: windowManager,
            displayID: displayID
        )
        systemResourceWidgetView = SystemResourceWidgetView(
            settings: settings,
            monitor: systemResourceMonitor,
            displayID: displayID
        )
        runningAppTrayView = RunningAppTrayView(
            windowManager: windowManager,
            pinnedAppManager: pinnedAppManager,
            settings: settings,
            systemResourceMonitor: systemResourceMonitor,
            displayID: displayID
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
        installModifierMonitors()
        observePinRequests()
        systemResourceWidgetView.preferredWidthDidChange = { [weak self] in
            self?.schedulePreferredWidthNotification()
        }
        runningAppTrayView.preferredWidthDidChange = { [weak self] in
            self?.schedulePreferredWidthNotification()
        }
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

        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
        }

        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
        }
    }

    func handleAccessibilityPermissionChange() {
        launcherZoneView.refresh()
        runningAppTrayView.refresh()
        rebuildTaskZone()
    }

    func preferredCompactWidth() -> CGFloat {
        layoutSubtreeIfNeeded()
        let contentWidth =
            launcherZoneView.preferredContentWidth() +
            preferredTaskZoneWidth() +
            systemResourceWidgetView.preferredContentWidth() +
            runningAppTrayView.preferredContentWidth() +
            zonesStackView.edgeInsets.left +
            zonesStackView.edgeInsets.right

        return ceil(max(contentWidth, 1))
    }

    private func preferredTaskZoneWidth() -> CGFloat {
        let leftWidth = preferredWidth(forArrangedSubviewsIn: leftTaskZoneStackView, spacing: taskZoneItemSpacing)
        let neutralWidth = preferredWidth(forArrangedSubviewsIn: neutralTaskZoneStackView, spacing: taskZoneItemSpacing)
        let rightWidth = preferredWidth(forArrangedSubviewsIn: rightTaskZoneStackView, spacing: taskZoneItemSpacing)
        let hasTaskContent = leftWidth > 0 || neutralWidth > 0 || rightWidth > 0

        guard hasTaskContent else {
            return 0
        }

        var componentWidths: [CGFloat] = [compactTaskZoneSpacerWidth]
        if leftWidth > 0 {
            componentWidths.append(leftWidth)
        }

        if !leftTaskZoneSeparatorView.isHidden {
            componentWidths.append(preferredWidth(for: leftTaskZoneSeparatorView))
        }

        if neutralWidth > 0 {
            componentWidths.append(neutralWidth)
        }

        if !rightTaskZoneSeparatorView.isHidden {
            componentWidths.append(preferredWidth(for: rightTaskZoneSeparatorView))
        }

        if rightWidth > 0 {
            componentWidths.append(rightWidth)
        }
        componentWidths.append(compactTaskZoneSpacerWidth)

        let spacing = CGFloat(max(componentWidths.count - 1, 0)) * taskZoneGroupSpacing
        return componentWidths.reduce(0, +) + spacing
    }

    private func preferredWidth(forArrangedSubviewsIn stackView: NSStackView, spacing: CGFloat) -> CGFloat {
        let visibleSubviews = stackView.arrangedSubviews.filter { !$0.isHidden }
        guard !visibleSubviews.isEmpty else {
            return 0
        }

        let contentWidth = visibleSubviews.map(preferredWidth(for:)).reduce(0, +)
        return contentWidth + CGFloat(visibleSubviews.count - 1) * spacing
    }

    private func preferredWidth(for view: NSView) -> CGFloat {
        let intrinsicWidth = view.intrinsicContentSize.width
        if intrinsicWidth != NSView.noIntrinsicMetric, intrinsicWidth > 0 {
            return intrinsicWidth
        }

        return max(0, view.fittingSize.width)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard shouldOpenSettingsMenu(for: event) else {
            super.rightMouseDown(with: event)
            return
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettingsFromContextMenu(_:)),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func shouldOpenSettingsMenu(for event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)

        guard bounds.contains(point), convertedBounds(of: zonesStackView).contains(point) else {
            return false
        }

        let occupiedViews: [NSView] = [
            bannerButton,
            launcherZoneView,
            runningAppTrayView,
            leftTaskZoneSeparatorView,
            rightTaskZoneSeparatorView
        ] + Array(taskItemViews.values)

        return !occupiedViews.contains { view in
            !view.isHidden &&
                view.window === window &&
                convertedBounds(of: view).contains(point)
        }
    }

    private func convertedBounds(of view: NSView) -> NSRect {
        view.convert(view.bounds, to: self)
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

        bannerButton.title = "Accessibility permission required — Click to grant (you may need to add DeskBar manually in System Settings > Privacy & Security > Accessibility)"
        bannerButton.toolTip = bannerButton.title
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

        taskZoneContainer.translatesAutoresizingMaskIntoConstraints = false
        taskZoneContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        taskZoneContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        taskZoneLayoutStackView.orientation = .horizontal
        taskZoneLayoutStackView.alignment = .centerY
        taskZoneLayoutStackView.distribution = .fill
        taskZoneLayoutStackView.spacing = taskZoneGroupSpacing
        taskZoneLayoutStackView.translatesAutoresizingMaskIntoConstraints = false
        taskZoneContainer.addSubview(taskZoneLayoutStackView)

        [leftTaskZoneStackView, neutralTaskZoneStackView, rightTaskZoneStackView].forEach { stackView in
            stackView.orientation = .horizontal
            stackView.alignment = .centerY
            stackView.distribution = .fill
            stackView.spacing = taskZoneItemSpacing
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            stackView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }

        taskZoneLayoutStackView.addArrangedSubview(clusterLeadingSpacerView)
        taskZoneLayoutStackView.addArrangedSubview(leftTaskZoneStackView)
        taskZoneLayoutStackView.addArrangedSubview(leftTaskZoneSeparatorView)
        taskZoneLayoutStackView.addArrangedSubview(neutralTaskZoneStackView)
        taskZoneLayoutStackView.addArrangedSubview(rightTaskZoneSeparatorView)
        taskZoneLayoutStackView.addArrangedSubview(rightTaskZoneStackView)
        taskZoneLayoutStackView.addArrangedSubview(clusterTrailingSpacerView)
        clusterSpacerEqualWidthConstraint = clusterLeadingSpacerView.widthAnchor.constraint(
            equalTo: clusterTrailingSpacerView.widthAnchor
        )
        clusterSpacerEqualWidthConstraint?.isActive = true

        NSLayoutConstraint.activate([
            taskZoneLayoutStackView.leadingAnchor.constraint(equalTo: taskZoneContainer.leadingAnchor),
            taskZoneLayoutStackView.trailingAnchor.constraint(equalTo: taskZoneContainer.trailingAnchor),
            taskZoneLayoutStackView.topAnchor.constraint(equalTo: taskZoneContainer.topAnchor),
            taskZoneLayoutStackView.bottomAnchor.constraint(equalTo: taskZoneContainer.bottomAnchor),
            taskZoneContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])

        zonesStackView.addArrangedSubview(launcherZoneView)
        zonesStackView.addArrangedSubview(taskZoneContainer)
        zonesStackView.addArrangedSubview(systemResourceWidgetView)
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
            .sink { [weak self] badges in
                self?.handleBadgeUpdates(badges)
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        appStateMonitor.$states
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        settings.$enableSessionManagerPlugin
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        settings.$showSessionManagerAgentTitles
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        settings.$enableSessionManagerTerminalActions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        settings.$showSessionManagerActionButton
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        smPluginService?.$agentTabs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
                self?.schedulePreferredWidthNotification()
            }
            .store(in: &cancellables)

        smPluginService?.$terminalTabCountByWindowID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
                self?.schedulePreferredWidthNotification()
            }
            .store(in: &cancellables)

        settings.$groupingMode
            .receive(on: RunLoop.main)
            .sink { [weak self] groupingMode in
                guard let self else {
                    return
                }

                if groupingMode == .never {
                    self.expandedGroupID = nil
                }

                self.rebuildTaskZone()
            }
            .store(in: &cancellables)

        windowManager.$windows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePreferredWidthNotification()
            }
            .store(in: &cancellables)

        pinnedAppManager.$pinnedApps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePreferredWidthNotification()
            }
            .store(in: &cancellables)

        settings.$dragReorder
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        settings.$flashAttentionIndicators
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        settings.$showProgressIndicators
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildTaskZone()
            }
            .store(in: &cancellables)

        settings.$enableActivityMode
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else {
                    return
                }

                if !isEnabled {
                    self.isActivityModeActive = false
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

        settings.$titleFontSize
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePreferredWidthNotification()
            }
            .store(in: &cancellables)

        settings.$maxTaskWidth
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePreferredWidthNotification()
            }
            .store(in: &cancellables)

        settings.$showTitles
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePreferredWidthNotification()
            }
            .store(in: &cancellables)

        settings.$showSystemResourceWidget
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePreferredWidthNotification()
            }
            .store(in: &cancellables)

        settings.$systemResourceWidgetCollapsed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePreferredWidthNotification()
            }
            .store(in: &cancellables)

        settings.$systemResourceWidgetPinnedDisplayID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePreferredWidthNotification()
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

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let baseScopedWindows = scopedVisibleWindows()
        let frontmostWindowID = currentFrontmostWindowID(in: baseScopedWindows)
        let scopedWindows = smScopedWindows(baseWindows: baseScopedWindows)
        let screen = ScreenGeometry.screen(for: displayID)
        let shouldGroupWindows = shouldGroupWindows(scopedWindows)

        if shouldGroupWindows {
            let items = orderedGroupedTaskItems(from: scopedWindows)
            var placedViews: [TaskZonePlacedView] = []
            var retainedItemIDs = Set<String>()

            for item in items {
                let itemID = groupedTaskItemID(for: item)
                let view = groupedTaskView(
                    for: item,
                    itemID: itemID,
                    frontmostPID: frontmostPID,
                    frontmostWindowID: frontmostWindowID
                )
                placedViews.append(
                    TaskZonePlacedView(
                        view: view,
                        zone: taskbarZone(for: item, on: screen)
                    )
                )
                retainedItemIDs.insert(itemID)

                switch item {
                case .group(let group):
                    if group.isExpanded {
                        expandedGroupView = view
                    }
                case .window:
                    break
                }
            }

            removeStaleTaskItemViews(retaining: retainedItemIDs)
            reconcileTaskZone(with: placedViews)
            schedulePreferredWidthNotification()
            return
        }

        if !shouldGroupWindows {
            expandedGroupID = nil
        }
        let orderedWindows = orderedUngroupedWindows(from: scopedWindows)
        let placedViews = orderedWindows.map { window in
            TaskZonePlacedView(
                view: taskButtonView(
                    for: window,
                    itemID: ungroupedTaskItemID(for: window),
                    frontmostPID: frontmostPID,
                    frontmostWindowID: frontmostWindowID,
                    dragItemID: ungroupedTaskItemID(for: window)
                ),
                zone: taskbarZone(for: window, on: screen)
            )
        }
        let retainedItemIDs = Set(orderedWindows.map(ungroupedTaskItemID(for:)))

        removeStaleTaskItemViews(retaining: retainedItemIDs)
        reconcileTaskZone(with: placedViews)
        schedulePreferredWidthNotification()
    }

    private func scopedVisibleWindows() -> [WindowInfo] {
        guard let screen = ScreenGeometry.screen(for: displayID) else {
            return []
        }

        // Include all windows (including minimized/hidden) so they stay in the taskbar
        // with dimmed appearance — Windows-style behavior
        return windowManager.windows(on: screen)
    }

    private func smScopedWindows(baseWindows: [WindowInfo]) -> [WindowInfo] {
        guard
            let smPluginService,
            settings.enableSessionManagerPlugin,
            let screen = ScreenGeometry.screen(for: displayID)
        else {
            return baseWindows
        }

        let displayBounds = ScreenGeometry.displayBounds(for: screen)
        let terminalWindows = baseWindows.filter {
            $0.bundleIdentifier == SMPluginService.terminalBundleIdentifier
        }
        let terminalWindowsByID = Dictionary(
            uniqueKeysWithValues: terminalWindows.compactMap { window -> (CGWindowID, WindowInfo)? in
                guard
                    let cgWindowID = window.cgWindowID
                else {
                    return nil
                }

                return (cgWindowID, window)
            }
        )
        let terminalApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: SMPluginService.terminalBundleIdentifier
        ).first

        let scopedAgentTabs = smPluginService.agentTabs.filter { annotation in
            if terminalWindowsByID[annotation.terminalWindowID] != nil {
                return true
            }

            guard let terminalFrame = annotation.terminalFrame else {
                return false
            }

            return ScreenGeometry.isWindow(bounds: terminalFrame, onDisplay: displayBounds)
        }
        guard !scopedAgentTabs.isEmpty else {
            return baseWindows
        }

        let agentTabCountByWindowID = Dictionary(grouping: scopedAgentTabs, by: \.terminalWindowID)
            .mapValues(\.count)
        let nonAgentWindows = baseWindows.filter { window in
            guard
                window.bundleIdentifier == SMPluginService.terminalBundleIdentifier
            else {
                return true
            }

            guard
                let cgWindowID = window.cgWindowID,
                agentTabCountByWindowID[cgWindowID] != nil
            else {
                return true
            }

            return terminalWindowHasNonAgentTabs(windowID: cgWindowID)
        }

        let virtualAgentWindows = scopedAgentTabs.compactMap { annotation -> WindowInfo? in
            let sourceWindow = terminalWindowsByID[annotation.terminalWindowID] ??
                terminalWindows.first { window in
                    guard
                        let annotationFrame = annotation.terminalFrame,
                        let windowFrame = windowManager.frame(for: window)
                    else {
                        return false
                    }

                    return smTerminalFrame(annotationFrame, matches: windowFrame)
                } ??
                terminalWindows.first

            guard sourceWindow != nil || terminalApplication != nil else {
                return nil
            }

            return WindowInfo(
                pid: sourceWindow?.pid ?? terminalApplication?.processIdentifier ?? 0,
                cgWindowID: nil,
                provisionalID: smVirtualWindowID(for: annotation),
                appName: sourceWindow?.appName ?? terminalApplication?.localizedName ?? "Terminal",
                title: settings.showSessionManagerAgentTitles
                    ? annotation.friendlyName
                    : sourceWindow?.title ?? "Terminal",
                icon: sourceWindow?.icon ?? terminalApplication?.icon,
                bundleIdentifier: sourceWindow?.bundleIdentifier ?? terminalApplication?.bundleIdentifier,
                isMinimized: sourceWindow?.isMinimized ?? false,
                isHidden: sourceWindow?.isHidden ?? terminalApplication?.isHidden ?? false,
                isProvisional: true
            )
        }

        return nonAgentWindows + virtualAgentWindows
    }

    private func smTerminalFrame(_ lhs: CGRect, matches rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 4
        return abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    private func terminalWindowHasNonAgentTabs(windowID: CGWindowID) -> Bool {
        guard let smPluginService else {
            return false
        }

        let agentTabCount = smPluginService.agentTabs.filter {
            $0.terminalWindowID == windowID
        }.count
        guard agentTabCount > 0 else {
            return false
        }

        guard let terminalTabCount = smPluginService.terminalTabCountByWindowID[windowID] else {
            return true
        }

        return terminalTabCount > agentTabCount
    }

    private func terminalWindowHasSelectedAgentTab(windowID: CGWindowID) -> Bool {
        smPluginService?.windowAnnotations[windowID] != nil
    }

    private func updateTaskbarLayout() {
        let verticalInset = max(0, floor((settings.taskbarHeight - minimumZoneContentHeight) / 2))
        zonesStackView.edgeInsets = NSEdgeInsets(
            top: verticalInset,
            left: 10,
            bottom: verticalInset,
            right: 10
        )
        layoutSubtreeIfNeeded()
        schedulePreferredWidthNotification()
    }

    private func schedulePreferredWidthNotification() {
        guard !preferredWidthNotificationScheduled else {
            return
        }

        preferredWidthNotificationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.preferredWidthNotificationScheduled = false
            let width = self.preferredCompactWidth()
            if let lastNotifiedPreferredCompactWidth = self.lastNotifiedPreferredCompactWidth,
               abs(lastNotifiedPreferredCompactWidth - width) < 0.5 {
                return
            }

            self.lastNotifiedPreferredCompactWidth = width
            self.preferredWidthDidChange?()
        }
    }

    @objc
    private func openSettingsFromContextMenu(_ sender: Any?) {
        openSettingsHandler()
    }

    private func taskButtonView(
        for window: WindowInfo,
        itemID: String,
        frontmostPID: pid_t?,
        frontmostWindowID: String?,
        dragItemID: String?
    ) -> TaskButtonView {
        if let existingView = taskItemViews[itemID] as? TaskButtonView {
            existingView.update(
                windowInfo: window,
                isActive: isWindowActive(window, frontmostPID: frontmostPID, frontmostWindowID: frontmostWindowID),
                hasBadge: hasBadge(for: window.bundleIdentifier),
                isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
                runtimeState: runtimeState(for: window.pid),
                showsActivityOverlay: settings.enableActivityMode && isActivityModeActive,
                agentAnnotation: smAnnotation(for: window),
                pluginMenuConfiguration: smPluginMenuConfiguration(for: window)
            )
            return existingView
        }

        removeCachedTaskItemView(for: itemID)

        let buttonView = TaskButtonView(
            windowInfo: window,
            isActive: isWindowActive(window, frontmostPID: frontmostPID, frontmostWindowID: frontmostWindowID),
            hasBadge: hasBadge(for: window.bundleIdentifier),
            isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
            runtimeState: runtimeState(for: window.pid),
            showsActivityOverlay: settings.enableActivityMode && isActivityModeActive,
            agentAnnotation: smAnnotation(for: window),
            settings: settings,
            blacklistManager: blacklistManager,
            dragConfiguration: dragItemID.flatMap { [self] in
                makeTaskDragConfiguration(for: $0)
            },
            pluginMenuConfiguration: smPluginMenuConfiguration(for: window)
        ) { [weak self] windowInfo in
            self?.activate(windowInfo: windowInfo)
        }
        if let thumbnailService {
            buttonView.thumbnailProvider = { [weak thumbnailService] cgWindowID in
                await thumbnailService?.captureThumbnail(windowID: cgWindowID)
            }
        }
        buttonView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        taskItemViews[itemID] = buttonView
        return buttonView
    }

    private func groupedTaskView(
        for item: TaskZoneItem,
        itemID: String,
        frontmostPID: pid_t?,
        frontmostWindowID: String?
    ) -> NSView {
        switch item {
        case .window(let window):
            return taskButtonView(
                for: window,
                itemID: itemID,
                frontmostPID: frontmostPID,
                frontmostWindowID: frontmostWindowID,
                dragItemID: groupedTaskItemID(for: window)
            )
        case .group(let group):
            if let existingView = taskItemViews[itemID] as? TaskZoneGroupContainerView {
                existingView.update(
                    group: group,
                    frontmostPID: frontmostPID,
                    frontmostWindowID: frontmostWindowID,
                    isActive: group.windows.contains {
                        isWindowActive($0, frontmostPID: frontmostPID, frontmostWindowID: frontmostWindowID)
                    },
                    hasBadge: hasBadge(for: group.id),
                    isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
                    groupRuntimeState: runtimeState(for: group),
                    showsActivityOverlay: settings.enableActivityMode && isActivityModeActive
                )
                return existingView
            }

            removeCachedTaskItemView(for: itemID)

            let groupView = TaskZoneGroupContainerView(
                group: group,
                frontmostPID: frontmostPID,
                frontmostWindowID: frontmostWindowID,
                isActive: group.windows.contains {
                    isWindowActive($0, frontmostPID: frontmostPID, frontmostWindowID: frontmostWindowID)
                },
                hasBadge: hasBadge(for: group.id),
                isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
                groupRuntimeState: runtimeState(for: group),
                showsActivityOverlay: settings.enableActivityMode && isActivityModeActive,
                settings: settings,
                blacklistManager: blacklistManager,
                dragConfiguration: makeTaskDragConfiguration(for: groupedTaskItemID(forGroupID: group.id)),
                badgeProvider: { [weak self] bundleIdentifier in
                    self?.hasBadge(for: bundleIdentifier) ?? false
                },
                runtimeStateProvider: { [weak self] pid in
                    self?.runtimeState(for: pid) ?? AppRuntimeState()
                },
                agentAnnotationProvider: { [weak self] window in
                    self?.smAnnotation(for: window)
                },
                pluginMenuConfigurationProvider: { [weak self] window in
                    self?.smPluginMenuConfiguration(for: window)
                },
                windowActiveProvider: { [weak self] window, frontmostPID, frontmostWindowID in
                    self?.isWindowActive(
                        window,
                        frontmostPID: frontmostPID,
                        frontmostWindowID: frontmostWindowID
                    ) ?? (window.pid == frontmostPID)
                },
                activationHandler: { [weak self] in
                    self?.toggleGroupExpansion(for: group.id)
                },
                windowActivationHandler: { [weak self] windowInfo in
                    self?.activate(windowInfo: windowInfo)
                }
            )
            taskItemViews[itemID] = groupView
            return groupView
        }
    }

    private func removeCachedTaskItemView(for itemID: String) {
        guard let view = taskItemViews.removeValue(forKey: itemID) else {
            return
        }

        if let stackView = view.superview as? NSStackView {
            stackView.removeArrangedSubview(view)
        }
        view.removeFromSuperview()
    }

    private func removeStaleTaskItemViews(retaining retainedItemIDs: Set<String>) {
        let staleItemIDs = Set(taskItemViews.keys).subtracting(retainedItemIDs)
        for itemID in staleItemIDs {
            removeCachedTaskItemView(for: itemID)
        }
    }

    private func orderedUngroupedWindows(from windows: [WindowInfo]) -> [WindowInfo] {
        let windows = uniqueWindowsByUngroupedTaskItemID(windows)
        let ids = windows.map(ungroupedTaskItemID(for:))
        ungroupedTaskOrderState.reconcile(currentIDs: ids)

        let orderedIDs = ungroupedTaskOrderState.arrangedIDs(for: ids)
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { (ungroupedTaskItemID(for: $0), $0) })
        return orderedIDs.compactMap { windowsByID[$0] }
    }

    private func uniqueWindowsByUngroupedTaskItemID(_ windows: [WindowInfo]) -> [WindowInfo] {
        var seenItemIDs = Set<String>()
        return windows.filter { window in
            seenItemIDs.insert(ungroupedTaskItemID(for: window)).inserted
        }
    }

    private func orderedGroupedTaskItems(from windows: [WindowInfo]) -> [TaskZoneItem] {
        let items = groupedTaskItems(from: windows)
        let ids = items.map(groupedTaskItemID(for:))
        groupedTaskOrderState.reconcile(currentIDs: ids)

        let orderedIDs = groupedTaskOrderState.arrangedIDs(for: ids)
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { (groupedTaskItemID(for: $0), $0) })
        return orderedIDs.compactMap { itemsByID[$0] }
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

    private func reconcileTaskZone(with placedViews: [TaskZonePlacedView]) {
        let leftViews = placedViews.filter { $0.zone == .left }.map(\.view)
        let neutralViews = placedViews.filter { $0.zone == .neutral }.map(\.view)
        let rightViews = placedViews.filter { $0.zone == .right }.map(\.view)
        let hasLeftViews = !leftViews.isEmpty
        let hasNeutralViews = !neutralViews.isEmpty
        let hasRightViews = !rightViews.isEmpty

        reconcileArrangedSubviews(leftViews, in: leftTaskZoneStackView)
        reconcileArrangedSubviews(neutralViews, in: neutralTaskZoneStackView)
        reconcileArrangedSubviews(rightViews, in: rightTaskZoneStackView)

        leftTaskZoneStackView.isHidden = !hasLeftViews
        neutralTaskZoneStackView.isHidden = !hasNeutralViews
        rightTaskZoneStackView.isHidden = !hasRightViews

        let separatesLeftAndNeutral = hasLeftViews && hasNeutralViews
        let separatesNeutralAndRight = hasNeutralViews && hasRightViews
        let separatesLeftAndRight = hasLeftViews && hasRightViews && !hasNeutralViews
        leftTaskZoneSeparatorView.isHidden = !(separatesLeftAndNeutral || separatesLeftAndRight)
        rightTaskZoneSeparatorView.isHidden = !separatesNeutralAndRight
    }

    private func taskbarZone(for item: TaskZoneItem, on screen: NSScreen?) -> TaskbarWindowZone {
        switch item {
        case .window(let window):
            return taskbarZone(for: window, on: screen)
        case .group(let group):
            let zones = group.windows.map { taskbarZone(for: $0, on: screen) }
            guard let firstZone = zones.first,
                  zones.allSatisfy({ $0 == firstZone })
            else {
                return .neutral
            }

            return firstZone
        }
    }

    private func taskbarZone(for window: WindowInfo, on screen: NSScreen?) -> TaskbarWindowZone {
        guard let screen else {
            return .neutral
        }

        if let annotation = smAnnotation(for: window),
           let sourceWindow = scopedVisibleWindows().first(where: { $0.cgWindowID == annotation.terminalWindowID }) {
            return windowManager.taskbarZone(for: sourceWindow, on: screen)
        }

        if let annotation = smAnnotation(for: window),
           let terminalFrame = annotation.terminalFrame {
            return ScreenGeometry.taskbarZone(
                for: terminalFrame,
                onDisplay: ScreenGeometry.displayBounds(for: screen),
                topInset: ScreenGeometry.topInset(for: screen),
                taskbarHeight: settings.taskbarHeight
            )
        }

        return windowManager.taskbarZone(for: window, on: screen)
    }

    private func currentFrontmostWindowID(in visibleWindows: [WindowInfo]) -> String? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let matchingVisibleWindows = visibleWindows.filter { $0.pid == application.processIdentifier }
        guard !matchingVisibleWindows.isEmpty else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let prioritizedAttributes: [CFString] = [
            kAXFocusedWindowAttribute as CFString,
            kAXMainWindowAttribute as CFString
        ]

        for attribute in prioritizedAttributes {
            if let element = copyWindowAttribute(from: applicationElement, attribute: attribute),
               let windowID = matchingVisibleWindowID(for: element, in: matchingVisibleWindows) {
                return windowID
            }
        }

        return matchingVisibleWindows.count == 1 ? matchingVisibleWindows.first?.id : nil
    }

    private func isWindowActive(
        _ window: WindowInfo,
        frontmostPID: pid_t?,
        frontmostWindowID: String?
    ) -> Bool {
        if let annotation = smAnnotation(for: window) {
            return window.pid == frontmostPID &&
                frontmostWindowID == "\(window.pid)-\(annotation.terminalWindowID)"
        }

        if window.bundleIdentifier == SMPluginService.terminalBundleIdentifier,
           let cgWindowID = window.cgWindowID,
           terminalWindowHasNonAgentTabs(windowID: cgWindowID),
           terminalWindowHasSelectedAgentTab(windowID: cgWindowID) {
            return false
        }

        if let frontmostWindowID {
            return window.id == frontmostWindowID
        }

        return window.pid == frontmostPID
    }

    private func matchingVisibleWindowID(for element: AXUIElement, in windows: [WindowInfo]) -> String? {
        if let cgWindowID = axWindowID(for: element),
           let matchedWindow = windows.first(where: { $0.cgWindowID == cgWindowID }) {
            return matchedWindow.id
        }

        let normalizedTitle = axTitle(for: element) ?? ""
        if !normalizedTitle.isEmpty,
           let matchedWindow = windows.first(where: {
               $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTitle
           }) {
            return matchedWindow.id
        }

        return windows.count == 1 ? windows.first?.id : nil
    }

    private func copyWindowAttribute(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value
        else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(cfValue, to: AXUIElement.self)
    }

    private func makeTaskDragConfiguration(for itemID: String) -> TaskButtonDragConfiguration {
        TaskButtonDragConfiguration(
            payload: DeskBarDragPayload(zone: .task, itemID: itemID),
            validateDrop: { [weak self] payload, edge in
                self?.validateTaskDrop(payload: payload, targetItemID: itemID, edge: edge) ?? false
            },
            acceptDrop: { [weak self] payload, edge in
                self?.acceptTaskDrop(payload: payload, targetItemID: itemID, edge: edge) ?? false
            }
        )
    }

    private func validateTaskDrop(
        payload: DeskBarDragPayload,
        targetItemID: String,
        edge: DeskBarDropEdge
    ) -> Bool {
        guard settings.dragReorder, payload.zone == .task else {
            return false
        }

        return reorderedItemIDs(
            currentIDs: currentTaskOrderIDs(),
            movingItemID: payload.itemID,
            targetItemID: targetItemID,
            edge: edge
        ) != nil
    }

    private func acceptTaskDrop(
        payload: DeskBarDragPayload,
        targetItemID: String,
        edge: DeskBarDropEdge
    ) -> Bool {
        guard let reorderedIDs = reorderedItemIDs(
            currentIDs: currentTaskOrderIDs(),
            movingItemID: payload.itemID,
            targetItemID: targetItemID,
            edge: edge
        ) else {
            return false
        }

        if shouldGroupWindows(scopedVisibleWindows()) {
            groupedTaskOrderState.applyManualOrder(reorderedIDs, userPositionedItemID: payload.itemID)
        } else {
            ungroupedTaskOrderState.applyManualOrder(reorderedIDs, userPositionedItemID: payload.itemID)
        }

        rebuildTaskZone()
        return true
    }

    private func currentTaskOrderIDs() -> [String] {
        let scopedWindows = smScopedWindows(baseWindows: scopedVisibleWindows())

        if shouldGroupWindows(scopedWindows) {
            let items = groupedTaskItems(from: scopedWindows)
            return groupedTaskOrderState.arrangedIDs(for: items.map(groupedTaskItemID(for:)))
        }

        return ungroupedTaskOrderState.arrangedIDs(for: scopedWindows.map(ungroupedTaskItemID(for:)))
    }

    private func reorderedItemIDs(
        currentIDs: [String],
        movingItemID: String,
        targetItemID: String,
        edge: DeskBarDropEdge
    ) -> [String]? {
        guard
            movingItemID != targetItemID,
            let sourceIndex = currentIDs.firstIndex(of: movingItemID),
            let targetIndex = currentIDs.firstIndex(of: targetItemID)
        else {
            return nil
        }

        var reorderedIDs = currentIDs
        reorderedIDs.remove(at: sourceIndex)

        let adjustedTargetIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        let insertionIndex = edge == .leading ? adjustedTargetIndex : adjustedTargetIndex + 1
        reorderedIDs.insert(movingItemID, at: min(max(insertionIndex, 0), reorderedIDs.count))

        return reorderedIDs == currentIDs ? nil : reorderedIDs
    }

    private func groupedTaskItemID(for item: TaskZoneItem) -> String {
        switch item {
        case .window(let window):
            return groupedTaskItemID(for: window)
        case .group(let group):
            return groupedTaskItemID(forGroupID: group.id)
        }
    }

    private func groupedTaskItemID(for window: WindowInfo) -> String {
        groupedTaskItemID(forGroupID: resolvedGroupID(for: window))
    }

    private func groupedTaskItemID(forGroupID groupID: String) -> String {
        "group:\(groupID)"
    }

    private func ungroupedTaskItemID(for window: WindowInfo) -> String {
        ungroupedTaskItemID(forWindowID: window.id)
    }

    private func ungroupedTaskItemID(forWindowID windowID: String) -> String {
        "window:\(windowID)"
    }

    private func resolvedGroupID(for window: WindowInfo) -> String {
        if let annotation = smAnnotation(for: window) {
            return "sm-agent-\(annotation.sessionID)"
        }

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

    private func runtimeState(for pid: pid_t) -> AppRuntimeState {
        var state = appStateMonitor.state(for: pid)

        if !settings.flashAttentionIndicators {
            state.needsAttention = false
        }

        if !settings.showProgressIndicators {
            state.progressFraction = nil
        }

        return state
    }

    private func runtimeState(for group: AppGroup) -> AppRuntimeState {
        let memberStates = group.windows.map { runtimeState(for: $0.pid) }
        let cpuSamples = memberStates.compactMap(\.cpuPercent)
        let memorySamples = memberStates.compactMap(\.memoryMB)

        return AppRuntimeState(
            isLaunching: memberStates.contains(where: \.isLaunching),
            needsAttention: memberStates.contains(where: \.needsAttention),
            cpuPercent: cpuSamples.isEmpty ? nil : cpuSamples.reduce(0, +),
            memoryMB: memorySamples.isEmpty ? nil : memorySamples.reduce(0, +),
            progressFraction: memberStates.compactMap(\.normalizedProgressFraction).max()
        )
    }

    private func smAnnotation(for window: WindowInfo) -> SMAgentWindowAnnotation? {
        guard settings.enableSessionManagerPlugin else {
            return nil
        }

        if let provisionalID = window.provisionalID,
           provisionalID.hasPrefix("sm-agent:") {
            let sessionID = String(provisionalID.dropFirst("sm-agent:".count))
            return smPluginService?.agentTabs.first { $0.sessionID == sessionID }
        }

        guard
            window.bundleIdentifier == SMPluginService.terminalBundleIdentifier,
            let cgWindowID = window.cgWindowID
        else {
            return nil
        }

        guard !terminalWindowHasNonAgentTabs(windowID: cgWindowID) else {
            return nil
        }

        return smPluginService?.windowAnnotations[cgWindowID]
    }

    private func smVirtualWindowID(for annotation: SMAgentWindowAnnotation) -> String {
        "sm-agent:\(annotation.sessionID)"
    }

    private func smPluginMenuConfiguration(for window: WindowInfo) -> TaskButtonPluginMenuConfiguration? {
        guard
            settings.enableSessionManagerPlugin,
            settings.enableSessionManagerTerminalActions,
            let annotation = smAnnotation(for: window)
        else {
            return nil
        }

        return TaskButtonPluginMenuConfiguration(
            buttonTitle: "sm",
            tintColor: annotation.activityState.color,
            showsActionButton: settings.showSessionManagerActionButton,
            menuProvider: { [weak self] in
                SMPluginAgentMenuFactory.makeMenu(
                    annotation: annotation,
                    target: self,
                    action: #selector(TaskbarContentView.handleSMPluginMenuCommand(_:))
                )
            }
        )
    }

    @objc
    private func handleSMPluginMenuCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? SMPluginAgentMenuCommand else {
            return
        }

        switch command.action {
        case .openTerminalLikeThis:
            smPluginService?.openTerminalLike(annotation: command.annotation, inWorkingDirectory: true)
        case .retire:
            smPluginService?.retire(annotation: command.annotation, closeTerminal: false)
        case .retireAndClose:
            smPluginService?.retire(annotation: command.annotation, closeTerminal: true)
        }
    }

    private func shouldGroupWindows(_ windows: [WindowInfo]) -> Bool {
        switch settings.groupingMode {
        case .never:
            return false
        case .always:
            return true
        case .automatic:
            let groupIDs = windows.map(resolvedGroupID(for:))
            guard Set(groupIDs).count < groupIDs.count else {
                return false
            }

            return estimatedUngroupedWidth(for: windows) > availableTaskZoneWidth
        }
    }

    private var availableTaskZoneWidth: CGFloat {
        let width = taskZoneLayoutStackView.bounds.width
        return max(width, 320)
    }

    private func estimatedUngroupedWidth(for windows: [WindowInfo]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: settings.titleFontSize)
        let titlePadding: CGFloat = settings.showTitles ? 56 : 40

        return windows.reduce(0) { partialResult, window in
            let resolvedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? window.appName : window.title
            let textWidth: CGFloat

            if settings.showTitles {
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                textWidth = min(
                    ceil((resolvedTitle as NSString).size(withAttributes: attributes).width) + titlePadding,
                    settings.maxTaskWidth
                )
            } else {
                textWidth = titlePadding
            }

            return partialResult + textWidth + taskZoneItemSpacing
        }
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

    private func observePinRequests() {
        NotificationCenter.default.publisher(for: Notification.Name("DeskBar.pinToLauncher"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let bundleID = notification.userInfo?["bundleIdentifier"] as? String,
                      let appName = notification.userInfo?["appName"] as? String else { return }
                self?.pinnedAppManager.pin(bundleIdentifier: bundleID, name: appName)
            }
            .store(in: &cancellables)
    }

    private func handleBadgeUpdates(_ badges: [String: Bool]) {
        let badgedBundleIdentifiers = Set(badges.compactMap { key, value in value ? key : nil })
        let newlyBadgedBundleIdentifiers = badgedBundleIdentifiers.subtracting(previousBadgedBundleIdentifiers)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for bundleIdentifier in newlyBadgedBundleIdentifiers {
            guard
                let application = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }),
                application.processIdentifier != frontmostPID
            else {
                continue
            }

            appStateMonitor.requestAttention(for: application.processIdentifier)
        }

        previousBadgedBundleIdentifiers = badgedBundleIdentifiers
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

    private func installModifierMonitors() {
        let eventMask: NSEvent.EventTypeMask = [.flagsChanged]

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleModifierFlags(event.modifierFlags)
            return event
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleModifierFlags(event.modifierFlags)
            }
        }
    }

    private func handleModifierFlags(_ modifierFlags: NSEvent.ModifierFlags) {
        let nextIsActive = settings.enableActivityMode && modifierFlags.contains(.control)
        guard nextIsActive != isActivityModeActive else {
            return
        }

        isActivityModeActive = nextIsActive
        rebuildTaskZone()
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
        if let annotation = smAnnotation(for: windowInfo) {
            smPluginService?.activate(annotation: annotation)
            return
        }

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

        if let windowElement = matchingWindowElement(for: windowInfo, application: application) {
            accessibilityService.raiseAndActivate(element: windowElement, app: application)
        } else {
            // Fallback: no AX element found, activate all windows
            application.activate(options: .activateAllWindows)
        }
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
        accessibilityService.raiseAndActivate(element: windowElement, app: application)
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
        permissionsManager.requestAccessibilityPermission()
    }
}

private enum TaskZoneItem {
    case window(WindowInfo)
    case group(AppGroup)
}

private struct TaskZonePlacedView {
    let view: NSView
    let zone: TaskbarWindowZone
}

private struct TaskZoneOrderingState {
    private(set) var nonPositionedItemIDs: [String] = []
    private(set) var userPositionedRanks: [String: Int] = [:]

    mutating func reconcile(currentIDs: [String]) {
        let currentIDSet = Set(currentIDs)
        userPositionedRanks = userPositionedRanks.filter { currentIDSet.contains($0.key) }
        nonPositionedItemIDs = nonPositionedItemIDs.filter {
            currentIDSet.contains($0) && userPositionedRanks[$0] == nil
        }

        let knownItemIDs = Set(nonPositionedItemIDs).union(userPositionedRanks.keys)
        let newItemIDs = currentIDs.filter { !knownItemIDs.contains($0) }
        for itemID in newItemIDs {
            nonPositionedItemIDs.append(itemID)
        }
    }

    mutating func applyManualOrder(_ orderedIDs: [String], userPositionedItemID: String) {
        var positionedItemIDs = Set(userPositionedRanks.keys)
        positionedItemIDs.insert(userPositionedItemID)

        userPositionedRanks = [:]
        nonPositionedItemIDs = []

        for (index, itemID) in orderedIDs.enumerated() {
            if positionedItemIDs.contains(itemID) {
                userPositionedRanks[itemID] = index
            } else {
                nonPositionedItemIDs.append(itemID)
            }
        }
    }

    func arrangedIDs(for currentIDs: [String]) -> [String] {
        guard !currentIDs.isEmpty else {
            return []
        }

        let currentIDSet = Set(currentIDs)
        var arrangedIDs = Array<String?>(repeating: nil, count: currentIDs.count)
        let positionedItems = userPositionedRanks
            .filter { currentIDSet.contains($0.key) }
            .sorted {
                if $0.value != $1.value {
                    return $0.value < $1.value
                }

                return $0.key < $1.key
            }

        for (itemID, desiredRank) in positionedItems {
            var targetIndex = min(max(desiredRank, 0), arrangedIDs.count - 1)

            while targetIndex < arrangedIDs.count, arrangedIDs[targetIndex] != nil {
                targetIndex += 1
            }

            if targetIndex >= arrangedIDs.count,
               let fallbackIndex = arrangedIDs.indices.last(where: { arrangedIDs[$0] == nil }) {
                targetIndex = fallbackIndex
            }

            arrangedIDs[targetIndex] = itemID
        }

        var seenNonPositioned = Set<String>()
        let fallbackNonPositionedIDs = currentIDs.filter {
            userPositionedRanks[$0] == nil && seenNonPositioned.insert($0).inserted
        }
        let orderedNonPositionedIDs = nonPositionedItemIDs.filter {
            currentIDSet.contains($0) && userPositionedRanks[$0] == nil
        } + fallbackNonPositionedIDs.filter {
            !nonPositionedItemIDs.contains($0)
        }

        var nonPositionedIterator = orderedNonPositionedIDs.makeIterator()

        for index in arrangedIDs.indices where arrangedIDs[index] == nil {
            arrangedIDs[index] = nonPositionedIterator.next()
        }

        return arrangedIDs.compactMap { $0 }
    }
}

private final class TaskZoneGroupButtonView: NSView, NSDraggingSource {
    private var appGroup: AppGroup
    private var hasBadge: Bool
    private var runtimeState: AppRuntimeState
    private var showsActivityOverlay: Bool
    private let settings: TaskbarSettings
    private let activationHandler: () -> Void
    private let dragConfiguration: TaskButtonDragConfiguration?
    private let iconView = NSImageView()
    private let statusIndicatorView = NSView()
    private let activityBadgeView = NSVisualEffectView()
    private let activityLabel = NSTextField(labelWithString: "")
    private let badgeView = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let progressTrackView = NSView()
    private let progressFillView = NSView()
    private let dropIndicatorView = NSView()
    private var trackingAreaRef: NSTrackingArea?
    private var progressWidthConstraint: NSLayoutConstraint?
    private var dropIndicatorLeadingConstraint: NSLayoutConstraint?
    private var dropIndicatorTrailingConstraint: NSLayoutConstraint?
    private var mouseDownLocation: NSPoint?
    private var didBeginDraggingSession = false
    private var isHovered = false {
        didSet {
            updateBackgroundColor()
        }
    }

    var isActive: Bool {
        didSet {
            updateBackgroundColor()
        }
    }

    init(
        appGroup: AppGroup,
        hasBadge: Bool,
        runtimeState: AppRuntimeState,
        showsActivityOverlay: Bool,
        isActive: Bool,
        settings: TaskbarSettings,
        dragConfiguration: TaskButtonDragConfiguration?,
        activationHandler: @escaping () -> Void
    ) {
        self.appGroup = appGroup
        self.hasBadge = hasBadge
        self.runtimeState = runtimeState
        self.showsActivityOverlay = showsActivityOverlay
        self.isActive = isActive
        self.settings = settings
        self.dragConfiguration = dragConfiguration
        self.activationHandler = activationHandler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        configureSubviews()
        updateAppearance()

        if dragConfiguration != nil {
            registerForDraggedTypes([TaskButtonView.dragPasteboardType])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        if showsActivityOverlay, runtimeState.activitySummary != nil {
            return NSSize(width: 140, height: 32)
        }

        return NSSize(width: 40, height: 32)
    }

    override func layout() {
        super.layout()
        updateProgressWidth()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingAreaRef = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaRef)
        self.trackingAreaRef = trackingAreaRef
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateDropIndicator(nil)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        didBeginDraggingSession = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard settings.dragReorder, let dragConfiguration, let mouseDownLocation else {
            return
        }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let distance = hypot(currentLocation.x - mouseDownLocation.x, currentLocation.y - mouseDownLocation.y)
        guard distance >= 3,
              let pasteboardItem = TaskButtonView.makePasteboardItem(for: dragConfiguration.payload) else {
            return
        }

        didBeginDraggingSession = true
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: draggingPreviewImage())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            didBeginDraggingSession = false
        }

        guard !didBeginDraggingSession else {
            return
        }

        activationHandler()
    }

    private func configureSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        statusIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        statusIndicatorView.wantsLayer = true
        statusIndicatorView.layer?.cornerRadius = 1.5
        statusIndicatorView.isHidden = true

        activityBadgeView.translatesAutoresizingMaskIntoConstraints = false
        activityBadgeView.material = .toolTip
        activityBadgeView.blendingMode = .withinWindow
        activityBadgeView.state = .active
        activityBadgeView.wantsLayer = true
        activityBadgeView.layer?.cornerRadius = 5
        activityBadgeView.layer?.masksToBounds = true
        activityBadgeView.isHidden = true

        activityLabel.translatesAutoresizingMaskIntoConstraints = false
        activityLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        activityLabel.textColor = .secondaryLabelColor

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.wantsLayer = true
        badgeView.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeView.layer?.cornerRadius = 8

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center

        progressTrackView.translatesAutoresizingMaskIntoConstraints = false
        progressTrackView.wantsLayer = true
        progressTrackView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        progressTrackView.layer?.cornerRadius = 1
        progressTrackView.isHidden = true

        progressFillView.translatesAutoresizingMaskIntoConstraints = false
        progressFillView.wantsLayer = true
        progressFillView.layer?.backgroundColor = NSColor.systemGreen.cgColor
        progressFillView.layer?.cornerRadius = 1

        dropIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        dropIndicatorView.wantsLayer = true
        dropIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicatorView.layer?.cornerRadius = 1
        dropIndicatorView.isHidden = true

        addSubview(statusIndicatorView)
        addSubview(iconView)
        addSubview(activityBadgeView)
        activityBadgeView.addSubview(activityLabel)
        addSubview(badgeView)
        badgeView.addSubview(badgeLabel)
        addSubview(progressTrackView)
        progressTrackView.addSubview(progressFillView)
        addSubview(dropIndicatorView)

        let progressWidthConstraint = progressFillView.widthAnchor.constraint(equalToConstant: 0)
        self.progressWidthConstraint = progressWidthConstraint
        let dropIndicatorLeadingConstraint = dropIndicatorView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let dropIndicatorTrailingConstraint = dropIndicatorView.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.dropIndicatorLeadingConstraint = dropIndicatorLeadingConstraint
        self.dropIndicatorTrailingConstraint = dropIndicatorTrailingConstraint

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            heightAnchor.constraint(equalToConstant: 32),

            statusIndicatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            statusIndicatorView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            statusIndicatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            statusIndicatorView.widthAnchor.constraint(equalToConstant: 3),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            activityBadgeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            activityBadgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            activityBadgeView.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            activityLabel.leadingAnchor.constraint(equalTo: activityBadgeView.leadingAnchor, constant: 5),
            activityLabel.trailingAnchor.constraint(equalTo: activityBadgeView.trailingAnchor, constant: -5),
            activityLabel.topAnchor.constraint(equalTo: activityBadgeView.topAnchor, constant: 2),
            activityLabel.bottomAnchor.constraint(equalTo: activityBadgeView.bottomAnchor, constant: -2),

            badgeView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            badgeView.heightAnchor.constraint(equalToConstant: 16),
            badgeView.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 4),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -4),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),

            progressTrackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            progressTrackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            progressTrackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            progressTrackView.heightAnchor.constraint(equalToConstant: 2),

            progressFillView.leadingAnchor.constraint(equalTo: progressTrackView.leadingAnchor),
            progressFillView.topAnchor.constraint(equalTo: progressTrackView.topAnchor),
            progressFillView.bottomAnchor.constraint(equalTo: progressTrackView.bottomAnchor),
            progressWidthConstraint,

            dropIndicatorView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            dropIndicatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            dropIndicatorView.widthAnchor.constraint(equalToConstant: 3)
        ])
    }

    private func updateAppearance() {
        if let icon = appGroup.icon {
            iconView.image = hasBadge ? icon.withBadgeDot() : icon
        } else {
            iconView.image = nil
        }
        badgeLabel.stringValue = "\(appGroup.windowCount)"
        toolTip = resolvedToolTip()
        updateStatusIndicator()
        updateActivityBadge()
        updateProgressIndicator()
        updateBackgroundColor()
    }

    func update(
        appGroup: AppGroup,
        hasBadge: Bool,
        runtimeState: AppRuntimeState,
        showsActivityOverlay: Bool,
        isActive: Bool
    ) {
        self.appGroup = appGroup
        self.hasBadge = hasBadge
        self.runtimeState = runtimeState
        self.showsActivityOverlay = showsActivityOverlay
        self.isActive = isActive
        updateAppearance()
        invalidateIntrinsicContentSize()
    }

    private func updateBackgroundColor() {
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        } else if runtimeState.needsAttention {
            layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func draggingPreviewImage() -> NSImage {
        let fallback = NSImage(size: bounds.size)

        guard
            bounds.width > 0,
            bounds.height > 0,
            let bitmap = bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return fallback
        }

        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func draggingEdge(for draggingInfo: NSDraggingInfo) -> DeskBarDropEdge {
        let location = convert(draggingInfo.draggingLocation, from: nil)
        return location.x < bounds.midX ? .leading : .trailing
    }

    private func updateDropIndicator(_ edge: DeskBarDropEdge?) {
        guard let edge else {
            dropIndicatorView.isHidden = true
            dropIndicatorLeadingConstraint?.isActive = false
            dropIndicatorTrailingConstraint?.isActive = false
            return
        }

        dropIndicatorLeadingConstraint?.isActive = edge == .leading
        dropIndicatorTrailingConstraint?.isActive = edge == .trailing
        dropIndicatorView.isHidden = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        settings.dragReorder && dragConfiguration != nil ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        mouseDownLocation = nil
        didBeginDraggingSession = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard
            settings.dragReorder,
            let dragConfiguration,
            let payload = TaskButtonView.decodeDragPayload(from: sender.draggingPasteboard)
        else {
            updateDropIndicator(nil)
            return []
        }

        let edge = draggingEdge(for: sender)
        guard dragConfiguration.validateDrop(payload, edge) else {
            updateDropIndicator(nil)
            return []
        }

        updateDropIndicator(edge)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        updateDropIndicator(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        settings.dragReorder && dragConfiguration != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            updateDropIndicator(nil)
        }

        guard
            settings.dragReorder,
            let dragConfiguration,
            let payload = TaskButtonView.decodeDragPayload(from: sender.draggingPasteboard)
        else {
            return false
        }

        let edge = draggingEdge(for: sender)
        guard dragConfiguration.validateDrop(payload, edge) else {
            return false
        }

        return dragConfiguration.acceptDrop(payload, edge)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        updateDropIndicator(nil)
    }

    private func resolvedToolTip() -> String {
        var lines = ["\(appGroup.appName) (\(appGroup.windowCount) windows)"]

        if runtimeState.isLaunching {
            lines.append("Launching")
        }

        if let progressFraction = runtimeState.normalizedProgressFraction {
            lines.append("Progress: \(Int((progressFraction * 100).rounded()))%")
        }

        if let activitySummary = runtimeState.activitySummary {
            lines.append(activitySummary)
        }

        return lines.joined(separator: "\n")
    }

    private func updateStatusIndicator() {
        let isVisible = runtimeState.needsAttention || runtimeState.isLaunching
        statusIndicatorView.isHidden = !isVisible

        guard isVisible else {
            statusIndicatorView.layer?.removeAnimation(forKey: "deskbar.attention")
            return
        }

        let color = runtimeState.needsAttention ? NSColor.systemOrange : NSColor.systemBlue
        statusIndicatorView.layer?.backgroundColor = color.cgColor

        if runtimeState.needsAttention {
            if statusIndicatorView.layer?.animation(forKey: "deskbar.attention") == nil {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0.25
                animation.duration = 0.55
                animation.autoreverses = true
                animation.repeatCount = .infinity
                statusIndicatorView.layer?.add(animation, forKey: "deskbar.attention")
            }
        } else {
            statusIndicatorView.layer?.removeAnimation(forKey: "deskbar.attention")
        }
    }

    private func updateActivityBadge() {
        guard showsActivityOverlay, let activitySummary = runtimeState.activitySummary else {
            activityBadgeView.isHidden = true
            return
        }

        activityLabel.stringValue = activitySummary
        activityBadgeView.isHidden = false
    }

    private func updateProgressIndicator() {
        guard let progressFraction = runtimeState.normalizedProgressFraction else {
            progressTrackView.isHidden = true
            return
        }

        progressTrackView.isHidden = false
        progressFillView.layer?.backgroundColor = progressFraction >= 1 ? NSColor.systemBlue.cgColor : NSColor.systemGreen.cgColor
        updateProgressWidth()
    }

    private func updateProgressWidth() {
        guard let progressFraction = runtimeState.normalizedProgressFraction else {
            progressWidthConstraint?.constant = 0
            return
        }

        let trackWidth = max(progressTrackView.bounds.width, bounds.width - 12)
        progressWidthConstraint?.constant = max(2, trackWidth * progressFraction)
    }
}

private final class TaskZoneGroupContainerView: NSView {
    private let settings: TaskbarSettings
    private let blacklistManager: BlacklistManager
    private let badgeProvider: (String?) -> Bool
    private let agentAnnotationProvider: (WindowInfo) -> SMAgentWindowAnnotation?
    private let pluginMenuConfigurationProvider: (WindowInfo) -> TaskButtonPluginMenuConfiguration?
    private let windowActiveProvider: (WindowInfo, pid_t?, String?) -> Bool
    private let windowActivationHandler: (WindowInfo) -> Void
    private let stackView = NSStackView()
    private let headerView: TaskZoneGroupButtonView
    private var childViews: [String: TaskButtonView] = [:]

    init(
        group: AppGroup,
        frontmostPID: pid_t?,
        frontmostWindowID: String?,
        isActive: Bool,
        hasBadge: Bool,
        isAccessibilityAvailable: Bool,
        groupRuntimeState: AppRuntimeState,
        showsActivityOverlay: Bool,
        settings: TaskbarSettings,
        blacklistManager: BlacklistManager,
        dragConfiguration: TaskButtonDragConfiguration,
        badgeProvider: @escaping (String?) -> Bool,
        runtimeStateProvider: @escaping (pid_t) -> AppRuntimeState,
        agentAnnotationProvider: @escaping (WindowInfo) -> SMAgentWindowAnnotation?,
        pluginMenuConfigurationProvider: @escaping (WindowInfo) -> TaskButtonPluginMenuConfiguration?,
        windowActiveProvider: @escaping (WindowInfo, pid_t?, String?) -> Bool,
        activationHandler: @escaping () -> Void,
        windowActivationHandler: @escaping (WindowInfo) -> Void
    ) {
        self.settings = settings
        self.blacklistManager = blacklistManager
        self.badgeProvider = badgeProvider
        self.agentAnnotationProvider = agentAnnotationProvider
        self.pluginMenuConfigurationProvider = pluginMenuConfigurationProvider
        self.windowActiveProvider = windowActiveProvider
        self.windowActivationHandler = windowActivationHandler
        headerView = TaskZoneGroupButtonView(
            appGroup: group,
            hasBadge: hasBadge,
            runtimeState: groupRuntimeState,
            showsActivityOverlay: showsActivityOverlay,
            isActive: isActive,
            settings: settings,
            dragConfiguration: dragConfiguration,
            activationHandler: activationHandler
        )
        self.runtimeStateProvider = runtimeStateProvider
        self.showsActivityOverlay = showsActivityOverlay
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsetsZero
        stackView.distribution = .fill
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        headerView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        update(
            group: group,
            frontmostPID: frontmostPID,
            frontmostWindowID: frontmostWindowID,
            isActive: isActive,
            hasBadge: hasBadge,
            isAccessibilityAvailable: isAccessibilityAvailable,
            groupRuntimeState: groupRuntimeState,
            showsActivityOverlay: showsActivityOverlay
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let runtimeStateProvider: (pid_t) -> AppRuntimeState
    private var showsActivityOverlay: Bool

    func update(
        group: AppGroup,
        frontmostPID: pid_t?,
        frontmostWindowID: String?,
        isActive: Bool,
        hasBadge: Bool,
        isAccessibilityAvailable: Bool,
        groupRuntimeState: AppRuntimeState,
        showsActivityOverlay: Bool
    ) {
        self.showsActivityOverlay = showsActivityOverlay
        headerView.update(
            appGroup: group,
            hasBadge: hasBadge,
            runtimeState: groupRuntimeState,
            showsActivityOverlay: showsActivityOverlay,
            isActive: isActive
        )

        var desiredViews: [NSView] = [headerView]
        var retainedChildIDs = Set<String>()

        if group.isExpanded {
            for window in group.windows {
                let windowID = window.id
                let buttonView: TaskButtonView

                if let existingView = childViews[windowID] {
                    existingView.update(
                        windowInfo: window,
                        isActive: windowActiveProvider(window, frontmostPID, frontmostWindowID),
                        hasBadge: badgeProvider(window.bundleIdentifier),
                        isAccessibilityAvailable: isAccessibilityAvailable,
                        runtimeState: runtimeStateProvider(window.pid),
                        showsActivityOverlay: showsActivityOverlay,
                        agentAnnotation: agentAnnotationProvider(window),
                        pluginMenuConfiguration: pluginMenuConfigurationProvider(window)
                    )
                    buttonView = existingView
                } else {
                    let newButtonView = TaskButtonView(
                        windowInfo: window,
                        isActive: windowActiveProvider(window, frontmostPID, frontmostWindowID),
                        hasBadge: badgeProvider(window.bundleIdentifier),
                        isAccessibilityAvailable: isAccessibilityAvailable,
                        runtimeState: runtimeStateProvider(window.pid),
                        showsActivityOverlay: showsActivityOverlay,
                        agentAnnotation: agentAnnotationProvider(window),
                        settings: settings,
                        blacklistManager: blacklistManager,
                        pluginMenuConfiguration: pluginMenuConfigurationProvider(window)
                    ) { [windowActivationHandler] windowInfo in
                        windowActivationHandler(windowInfo)
                    }
                    newButtonView.heightAnchor.constraint(equalToConstant: 32).isActive = true
                    childViews[windowID] = newButtonView
                    buttonView = newButtonView
                }

                desiredViews.append(buttonView)
                retainedChildIDs.insert(windowID)
            }
        }

        let staleChildIDs = Set(childViews.keys).subtracting(retainedChildIDs)
        for childID in staleChildIDs {
            guard let view = childViews.removeValue(forKey: childID) else {
                continue
            }

            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        reconcileArrangedSubviews(desiredViews, in: stackView)
    }
}

private final class TaskZoneSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 1, height: 22)
    }
}

private final class TaskZoneFlexibleSpacerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 8, height: 1)
    }
}

private func reconcileArrangedSubviews(_ desiredViews: [NSView], in stackView: NSStackView) {
    let desiredIdentifiers = Set(desiredViews.map(ObjectIdentifier.init))

    for view in stackView.arrangedSubviews where !desiredIdentifiers.contains(ObjectIdentifier(view)) {
        view.layer?.removeAllAnimations()
        view.alphaValue = 1
        stackView.removeArrangedSubview(view)
        view.removeFromSuperview()
    }

    for (index, view) in desiredViews.enumerated() {
        let currentSubviews = stackView.arrangedSubviews

        if currentSubviews.indices.contains(index), currentSubviews[index] === view {
            continue
        }

        if currentSubviews.contains(where: { $0 === view }) {
            stackView.removeArrangedSubview(view)
        }

        let isNew = !stackView.arrangedSubviews.contains(where: { $0 === view })
        if isNew {
            view.alphaValue = 0
        }
        stackView.insertArrangedSubview(view, at: index)
        if isNew {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                view.animator().alphaValue = 1
            }
        }
    }
}
