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
    private let displayID: CGDirectDisplayID
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
    private var groupedTaskOrderState = TaskZoneOrderingState()
    private var ungroupedTaskOrderState = TaskZoneOrderingState()
    private var taskItemViews: [String: NSView] = [:]

    init(
        windowManager: WindowManager,
        badgeMonitor: BadgeMonitor,
        permissionsManager: PermissionsManager,
        settings: TaskbarSettings,
        blacklistManager: BlacklistManager,
        pinnedAppManager: PinnedAppManager,
        displayID: CGDirectDisplayID
    ) {
        self.windowManager = windowManager
        self.badgeMonitor = badgeMonitor
        self.permissionsManager = permissionsManager
        self.settings = settings
        self.blacklistManager = blacklistManager
        self.displayID = displayID
        launcherZoneView = LauncherZoneView(
            settings: settings,
            pinnedAppManager: pinnedAppManager,
            windowManager: windowManager,
            displayID: displayID
        )
        runningAppTrayView = RunningAppTrayView(
            windowManager: windowManager,
            pinnedAppManager: pinnedAppManager,
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
        runningAppTrayView.refresh()
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

        settings.$dragReorder
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
        expandedGroupView = nil

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let scopedWindows = scopedVisibleWindows()

        if settings.groupByApp {
            let items = orderedGroupedTaskItems(from: scopedWindows)
            var desiredViews: [NSView] = []
            var retainedItemIDs = Set<String>()

            for item in items {
                let itemID = groupedTaskItemID(for: item)
                let view = groupedTaskView(for: item, itemID: itemID, frontmostPID: frontmostPID)
                desiredViews.append(view)
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
            reconcileArrangedSubviews(desiredViews, in: taskZoneStackView)
            return
        }

        expandedGroupID = nil
        let orderedWindows = orderedUngroupedWindows(from: scopedWindows)
        let desiredViews = orderedWindows.map { window in
            taskButtonView(
                for: window,
                itemID: ungroupedTaskItemID(for: window),
                frontmostPID: frontmostPID,
                dragItemID: ungroupedTaskItemID(for: window)
            )
        }
        let retainedItemIDs = Set(orderedWindows.map(ungroupedTaskItemID(for:)))

        removeStaleTaskItemViews(retaining: retainedItemIDs)
        reconcileArrangedSubviews(desiredViews, in: taskZoneStackView)
    }

    private func scopedVisibleWindows() -> [WindowInfo] {
        guard let screen = ScreenGeometry.screen(for: displayID) else {
            return []
        }

        return windowManager.visibleWindows(on: screen)
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

    private func taskButtonView(
        for window: WindowInfo,
        itemID: String,
        frontmostPID: pid_t?,
        dragItemID: String?
    ) -> TaskButtonView {
        if let existingView = taskItemViews[itemID] as? TaskButtonView {
            existingView.update(
                windowInfo: window,
                isActive: window.pid == frontmostPID,
                hasBadge: hasBadge(for: window.bundleIdentifier),
                isAccessibilityAvailable: permissionsManager.isAccessibilityGranted
            )
            return existingView
        }

        removeCachedTaskItemView(for: itemID)

        let buttonView = TaskButtonView(
            windowInfo: window,
            isActive: window.pid == frontmostPID,
            hasBadge: hasBadge(for: window.bundleIdentifier),
            isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
            settings: settings,
            blacklistManager: blacklistManager,
            dragConfiguration: dragItemID.flatMap { [self] in
                makeTaskDragConfiguration(for: $0)
            }
        ) { [weak self] windowInfo in
            self?.activate(windowInfo: windowInfo)
        }
        buttonView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        taskItemViews[itemID] = buttonView
        return buttonView
    }

    private func groupedTaskView(for item: TaskZoneItem, itemID: String, frontmostPID: pid_t?) -> NSView {
        switch item {
        case .window(let window):
            return taskButtonView(
                for: window,
                itemID: itemID,
                frontmostPID: frontmostPID,
                dragItemID: groupedTaskItemID(for: window)
            )
        case .group(let group):
            if let existingView = taskItemViews[itemID] as? TaskZoneGroupContainerView {
                existingView.update(
                    group: group,
                    frontmostPID: frontmostPID,
                    isActive: group.windows.contains { $0.pid == frontmostPID },
                    hasBadge: hasBadge(for: group.id),
                    isAccessibilityAvailable: permissionsManager.isAccessibilityGranted
                )
                return existingView
            }

            removeCachedTaskItemView(for: itemID)

            let groupView = TaskZoneGroupContainerView(
                group: group,
                frontmostPID: frontmostPID,
                isActive: group.windows.contains { $0.pid == frontmostPID },
                hasBadge: hasBadge(for: group.id),
                isAccessibilityAvailable: permissionsManager.isAccessibilityGranted,
                settings: settings,
                blacklistManager: blacklistManager,
                dragConfiguration: makeTaskDragConfiguration(for: groupedTaskItemID(forGroupID: group.id)),
                badgeProvider: { [weak self] bundleIdentifier in
                    self?.hasBadge(for: bundleIdentifier) ?? false
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

        taskZoneStackView.removeArrangedSubview(view)
        view.removeFromSuperview()
    }

    private func removeStaleTaskItemViews(retaining retainedItemIDs: Set<String>) {
        let staleItemIDs = Set(taskItemViews.keys).subtracting(retainedItemIDs)
        for itemID in staleItemIDs {
            removeCachedTaskItemView(for: itemID)
        }
    }

    private func orderedUngroupedWindows(from windows: [WindowInfo]) -> [WindowInfo] {
        let ids = windows.map(ungroupedTaskItemID(for:))
        ungroupedTaskOrderState.reconcile(currentIDs: ids)

        let orderedIDs = ungroupedTaskOrderState.arrangedIDs(for: ids)
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { (ungroupedTaskItemID(for: $0), $0) })
        return orderedIDs.compactMap { windowsByID[$0] }
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

        if settings.groupByApp {
            groupedTaskOrderState.applyManualOrder(reorderedIDs, userPositionedItemID: payload.itemID)
        } else {
            ungroupedTaskOrderState.applyManualOrder(reorderedIDs, userPositionedItemID: payload.itemID)
        }

        rebuildTaskZone()
        return true
    }

    private func currentTaskOrderIDs() -> [String] {
        let scopedWindows = scopedVisibleWindows()

        if settings.groupByApp {
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

        // Raise the specific window via AX, then activate the app
        if let windowElement = matchingWindowElement(for: windowInfo, application: application) {
            // Set as the app's main/focused window first
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, windowElement)
            // Raise to front of app's window stack
            _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
            // Activate the app to bring it forward (the raised window is now on top)
            application.activate()
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
        permissionsManager.requestAccessibilityPermission()
    }
}

private enum TaskZoneItem {
    case window(WindowInfo)
    case group(AppGroup)
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
    private let settings: TaskbarSettings
    private let activationHandler: () -> Void
    private let dragConfiguration: TaskButtonDragConfiguration?
    private let iconView = NSImageView()
    private let badgeView = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let dropIndicatorView = NSView()
    private var trackingAreaRef: NSTrackingArea?
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
        isActive: Bool,
        settings: TaskbarSettings,
        dragConfiguration: TaskButtonDragConfiguration?,
        activationHandler: @escaping () -> Void
    ) {
        self.appGroup = appGroup
        self.hasBadge = hasBadge
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
        NSSize(width: 40, height: 32)
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

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.wantsLayer = true
        badgeView.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeView.layer?.cornerRadius = 8

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center

        dropIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        dropIndicatorView.wantsLayer = true
        dropIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicatorView.layer?.cornerRadius = 1
        dropIndicatorView.isHidden = true

        addSubview(iconView)
        addSubview(badgeView)
        badgeView.addSubview(badgeLabel)
        addSubview(dropIndicatorView)

        let dropIndicatorLeadingConstraint = dropIndicatorView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let dropIndicatorTrailingConstraint = dropIndicatorView.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.dropIndicatorLeadingConstraint = dropIndicatorLeadingConstraint
        self.dropIndicatorTrailingConstraint = dropIndicatorTrailingConstraint

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 40),
            heightAnchor.constraint(equalToConstant: 32),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            badgeView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            badgeView.heightAnchor.constraint(equalToConstant: 16),
            badgeView.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 4),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -4),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),

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
        toolTip = "\(appGroup.appName) (\(appGroup.windowCount) windows)"
        updateBackgroundColor()
    }

    func update(appGroup: AppGroup, hasBadge: Bool, isActive: Bool) {
        self.appGroup = appGroup
        self.hasBadge = hasBadge
        self.isActive = isActive
        updateAppearance()
    }

    private func updateBackgroundColor() {
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
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
}

private final class TaskZoneGroupContainerView: NSView {
    private let settings: TaskbarSettings
    private let blacklistManager: BlacklistManager
    private let badgeProvider: (String?) -> Bool
    private let windowActivationHandler: (WindowInfo) -> Void
    private let stackView = NSStackView()
    private let headerView: TaskZoneGroupButtonView
    private var childViews: [String: TaskButtonView] = [:]

    init(
        group: AppGroup,
        frontmostPID: pid_t?,
        isActive: Bool,
        hasBadge: Bool,
        isAccessibilityAvailable: Bool,
        settings: TaskbarSettings,
        blacklistManager: BlacklistManager,
        dragConfiguration: TaskButtonDragConfiguration,
        badgeProvider: @escaping (String?) -> Bool,
        activationHandler: @escaping () -> Void,
        windowActivationHandler: @escaping (WindowInfo) -> Void
    ) {
        self.settings = settings
        self.blacklistManager = blacklistManager
        self.badgeProvider = badgeProvider
        self.windowActivationHandler = windowActivationHandler
        headerView = TaskZoneGroupButtonView(
            appGroup: group,
            hasBadge: hasBadge,
            isActive: isActive,
            settings: settings,
            dragConfiguration: dragConfiguration,
            activationHandler: activationHandler
        )
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
            isActive: isActive,
            hasBadge: hasBadge,
            isAccessibilityAvailable: isAccessibilityAvailable
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        group: AppGroup,
        frontmostPID: pid_t?,
        isActive: Bool,
        hasBadge: Bool,
        isAccessibilityAvailable: Bool
    ) {
        headerView.update(appGroup: group, hasBadge: hasBadge, isActive: isActive)

        var desiredViews: [NSView] = [headerView]
        var retainedChildIDs = Set<String>()

        if group.isExpanded {
            for window in group.windows {
                let windowID = window.id
                let buttonView: TaskButtonView

                if let existingView = childViews[windowID] {
                    existingView.update(
                        windowInfo: window,
                        isActive: window.pid == frontmostPID,
                        hasBadge: badgeProvider(window.bundleIdentifier),
                        isAccessibilityAvailable: isAccessibilityAvailable
                    )
                    buttonView = existingView
                } else {
                    let newButtonView = TaskButtonView(
                        windowInfo: window,
                        isActive: window.pid == frontmostPID,
                        hasBadge: badgeProvider(window.bundleIdentifier),
                        isAccessibilityAvailable: isAccessibilityAvailable,
                        settings: settings,
                        blacklistManager: blacklistManager
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

private func reconcileArrangedSubviews(_ desiredViews: [NSView], in stackView: NSStackView) {
    let desiredIdentifiers = Set(desiredViews.map(ObjectIdentifier.init))

    for view in stackView.arrangedSubviews where !desiredIdentifiers.contains(ObjectIdentifier(view)) {
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

        stackView.insertArrangedSubview(view, at: index)
    }
}
