import AppKit
import ApplicationServices
import Combine

final class LauncherZoneView: NSStackView {
    private let settings: TaskbarSettings
    private let pinnedAppManager: PinnedAppManager
    private let windowManager: WindowManager
    private let displayID: CGDirectDisplayID
    private let buttonsStackView = NSStackView()
    private let dividerView = NSView()
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: TaskbarSettings,
        pinnedAppManager: PinnedAppManager,
        windowManager: WindowManager,
        displayID: CGDirectDisplayID
    ) {
        self.settings = settings
        self.pinnedAppManager = pinnedAppManager
        self.windowManager = windowManager
        self.displayID = displayID
        super.init(frame: .zero)

        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 10
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false

        configureButtonsStackView()
        configureDividerView()
        bindState()
        rebuildButtons()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        rebuildButtons()
    }

    private func configureButtonsStackView() {
        buttonsStackView.orientation = .horizontal
        buttonsStackView.alignment = .centerY
        buttonsStackView.distribution = .fill
        buttonsStackView.spacing = 8
        buttonsStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        addArrangedSubview(buttonsStackView)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    }

    private func configureDividerView() {
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = NSColor.separatorColor.cgColor
        dividerView.translatesAutoresizingMaskIntoConstraints = false

        addArrangedSubview(dividerView)
        NSLayoutConstraint.activate([
            dividerView.widthAnchor.constraint(equalToConstant: 1),
            dividerView.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func bindState() {
        settings.$showLaunchpadButton
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildButtons()
            }
            .store(in: &cancellables)

        settings.$dragReorder
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildButtons()
            }
            .store(in: &cancellables)

        pinnedAppManager.$pinnedApps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildButtons()
            }
            .store(in: &cancellables)

        windowManager.$windows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildButtons()
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
                    self?.rebuildButtons()
                }
                .store(in: &cancellables)
        }
    }

    private func rebuildButtons() {
        buttonsStackView.arrangedSubviews.forEach { view in
            buttonsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if settings.showLaunchpadButton {
            buttonsStackView.addArrangedSubview(LaunchpadButtonView())
        }

        let runningApplicationsByBundleIdentifier: [String: NSRunningApplication] =
            NSWorkspace.shared.runningApplications.reduce(into: [:]) { result, application in
                guard let bundleIdentifier = application.bundleIdentifier else {
                    return
                }

                result[bundleIdentifier] = application
            }

        for pinnedApp in pinnedAppManager.pinnedApps {
            let visibleLocalWindows = localWindows.filter {
                $0.bundleIdentifier == pinnedApp.bundleIdentifier &&
                    !$0.isMinimized &&
                    !$0.isHidden
            }

            let buttonView = LauncherZoneButtonView(
                pinnedApp: pinnedApp,
                visibleLocalWindows: visibleLocalWindows,
                runningApplication: runningApplicationsByBundleIdentifier[pinnedApp.bundleIdentifier],
                settings: settings,
                dragConfiguration: makeLauncherDragConfiguration(for: pinnedApp.bundleIdentifier)
            ) { [weak self] in
                self?.pinnedAppManager.unpin(bundleIdentifier: pinnedApp.bundleIdentifier)
            }

            buttonsStackView.addArrangedSubview(buttonView)
        }
    }

    private var localWindows: [WindowInfo] {
        guard let screen = ScreenGeometry.screen(for: displayID) else {
            return []
        }

        return windowManager.windows(on: screen)
    }

    private func makeLauncherDragConfiguration(for bundleIdentifier: String) -> TaskButtonDragConfiguration {
        TaskButtonDragConfiguration(
            payload: DeskBarDragPayload(zone: .launcher, itemID: bundleIdentifier),
            validateDrop: { [weak self] payload, edge in
                self?.validateLauncherDrop(payload: payload, targetBundleIdentifier: bundleIdentifier, edge: edge) ?? false
            },
            acceptDrop: { [weak self] payload, edge in
                self?.acceptLauncherDrop(payload: payload, targetBundleIdentifier: bundleIdentifier, edge: edge) ?? false
            }
        )
    }

    private func validateLauncherDrop(
        payload: DeskBarDragPayload,
        targetBundleIdentifier: String,
        edge: DeskBarDropEdge
    ) -> Bool {
        guard settings.dragReorder, payload.zone == .launcher else {
            return false
        }

        return reorderedLauncherBundleIdentifiers(
            movingBundleIdentifier: payload.itemID,
            targetBundleIdentifier: targetBundleIdentifier,
            edge: edge
        ) != nil
    }

    private func acceptLauncherDrop(
        payload: DeskBarDragPayload,
        targetBundleIdentifier: String,
        edge: DeskBarDropEdge
    ) -> Bool {
        let currentBundleIdentifiers = pinnedAppManager.pinnedApps.map(\.bundleIdentifier)

        guard
            let reorderedBundleIdentifiers = reorderedLauncherBundleIdentifiers(
                movingBundleIdentifier: payload.itemID,
                targetBundleIdentifier: targetBundleIdentifier,
                edge: edge
            ),
            let sourceIndex = currentBundleIdentifiers.firstIndex(of: payload.itemID),
            let destinationIndex = reorderedBundleIdentifiers.firstIndex(of: payload.itemID)
        else {
            return false
        }

        pinnedAppManager.reorder(from: sourceIndex, to: destinationIndex)
        return true
    }

    private func reorderedLauncherBundleIdentifiers(
        movingBundleIdentifier: String,
        targetBundleIdentifier: String,
        edge: DeskBarDropEdge
    ) -> [String]? {
        let bundleIdentifiers = pinnedAppManager.pinnedApps.map(\.bundleIdentifier)

        guard
            movingBundleIdentifier != targetBundleIdentifier,
            let sourceIndex = bundleIdentifiers.firstIndex(of: movingBundleIdentifier),
            let targetIndex = bundleIdentifiers.firstIndex(of: targetBundleIdentifier)
        else {
            return nil
        }

        var reorderedBundleIdentifiers = bundleIdentifiers
        reorderedBundleIdentifiers.remove(at: sourceIndex)

        let adjustedTargetIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        let insertionIndex = edge == .leading ? adjustedTargetIndex : adjustedTargetIndex + 1
        reorderedBundleIdentifiers.insert(
            movingBundleIdentifier,
            at: min(max(insertionIndex, 0), reorderedBundleIdentifiers.count)
        )

        return reorderedBundleIdentifiers == bundleIdentifiers ? nil : reorderedBundleIdentifiers
    }
}

private final class LauncherZoneButtonView: NSView, NSDraggingSource {
    private enum State {
        case notRunning
        case runningWithVisibleWindows
        case runningWithoutVisibleWindows
    }

    private let pinnedApp: PinnedApp
    private let visibleLocalWindows: [WindowInfo]
    private let runningApplication: NSRunningApplication?
    private let settings: TaskbarSettings
    private let unpinHandler: () -> Void
    private let accessibilityService: AccessibilityService
    private let dragConfiguration: TaskButtonDragConfiguration?

    private let iconView = NSImageView()
    private let underlineView = NSView()
    private let dotView = NSView()
    private let dropIndicatorView = NSView()

    private var dropIndicatorLeadingConstraint: NSLayoutConstraint?
    private var dropIndicatorTrailingConstraint: NSLayoutConstraint?
    private var mouseDownLocation: NSPoint?
    private var didBeginDraggingSession = false

    private var state: State {
        if !isRunning {
            return .notRunning
        }

        return visibleLocalWindows.isEmpty ? .runningWithoutVisibleWindows : .runningWithVisibleWindows
    }

    private var isRunning: Bool {
        runningApplication != nil
    }

    init(
        pinnedApp: PinnedApp,
        visibleLocalWindows: [WindowInfo],
        runningApplication: NSRunningApplication?,
        settings: TaskbarSettings,
        accessibilityService: AccessibilityService = AccessibilityService(),
        dragConfiguration: TaskButtonDragConfiguration?,
        unpinHandler: @escaping () -> Void
    ) {
        self.pinnedApp = pinnedApp
        self.visibleLocalWindows = visibleLocalWindows
        self.runningApplication = runningApplication
        self.settings = settings
        self.accessibilityService = accessibilityService
        self.dragConfiguration = dragConfiguration
        self.unpinHandler = unpinHandler
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

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
        NSSize(width: 36, height: 42)
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

        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }

        switch state {
        case .notRunning:
            launchApplication()
        case .runningWithVisibleWindows:
            activateMostRecentWindow()
        case .runningWithoutVisibleWindows:
            _ = runningApplication?.activate(options: .activateAllWindows)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func configureSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        underlineView.wantsLayer = true
        underlineView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        underlineView.layer?.cornerRadius = 1.5
        underlineView.translatesAutoresizingMaskIntoConstraints = false

        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dotView.layer?.cornerRadius = 2
        dotView.translatesAutoresizingMaskIntoConstraints = false

        dropIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        dropIndicatorView.wantsLayer = true
        dropIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicatorView.layer?.cornerRadius = 1
        dropIndicatorView.isHidden = true

        addSubview(iconView)
        addSubview(underlineView)
        addSubview(dotView)
        addSubview(dropIndicatorView)

        let dropIndicatorLeadingConstraint = dropIndicatorView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let dropIndicatorTrailingConstraint = dropIndicatorView.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.dropIndicatorLeadingConstraint = dropIndicatorLeadingConstraint
        self.dropIndicatorTrailingConstraint = dropIndicatorTrailingConstraint

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 42),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            underlineView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            underlineView.centerXAnchor.constraint(equalTo: centerXAnchor),
            underlineView.widthAnchor.constraint(equalToConstant: 20),
            underlineView.heightAnchor.constraint(equalToConstant: 3),

            dotView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            dotView.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 4),
            dotView.heightAnchor.constraint(equalToConstant: 4),

            dropIndicatorView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            dropIndicatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            dropIndicatorView.widthAnchor.constraint(equalToConstant: 3)
        ])
    }

    private func updateAppearance() {
        toolTip = pinnedApp.name
        iconView.image = displayIcon()
        underlineView.isHidden = state != .runningWithVisibleWindows
        dotView.isHidden = state != .runningWithoutVisibleWindows
    }

    private func displayIcon() -> NSImage? {
        let icon = resolvedIcon()

        guard state == .notRunning else {
            return icon
        }

        return icon?.desaturated().withAlpha(0.7)
    }

    private func resolvedIcon() -> NSImage? {
        if let icon = pinnedApp.icon {
            return icon.scaled(to: NSSize(width: 32, height: 32))
        }

        if let icon = runningApplication?.icon {
            return icon.scaled(to: NSSize(width: 32, height: 32))
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pinnedApp.bundleIdentifier) else {
            return nil
        }

        return NSWorkspace.shared.icon(forFile: applicationURL.path).scaled(to: NSSize(width: 32, height: 32))
    }

    private func launchApplication() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pinnedApp.bundleIdentifier) else {
            return
        }

        NSWorkspace.shared.open(applicationURL)
    }

    private func activateMostRecentWindow() {
        guard let runningApplication else {
            return
        }

        let windows = accessibilityService.enumerateWindows(for: runningApplication)
        if let element = preferredWindowElement(from: windows, application: runningApplication) {
            accessibilityService.raiseAndActivate(element: element, app: runningApplication)
            return
        }

        _ = runningApplication.activate(options: .activateAllWindows)
    }

    private func preferredWindowElement(
        from windows: [AXUIElement],
        application: NSRunningApplication
    ) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let prioritizedAttributes: [CFString] = [
            kAXFocusedWindowAttribute as CFString,
            kAXMainWindowAttribute as CFString
        ]

        for attribute in prioritizedAttributes {
            if let candidate = copyWindowAttribute(from: applicationElement, attribute: attribute),
               matchesVisibleWindow(candidate) {
                return candidate
            }
        }

        for windowInfo in visibleLocalWindows {
            if let element = resolveWindowElement(for: windowInfo, in: windows) {
                return element
            }
        }

        return nil
    }

    private func matchesVisibleWindow(_ element: AXUIElement) -> Bool {
        visibleLocalWindows.contains { windowInfo in
            windowMatches(windowInfo, element: element)
        }
    }

    private func resolveWindowElement(
        for windowInfo: WindowInfo,
        in windows: [AXUIElement]
    ) -> AXUIElement? {
        windows.first { element in
            windowMatches(windowInfo, element: element)
        }
    }

    private func windowMatches(_ windowInfo: WindowInfo, element: AXUIElement) -> Bool {
        if let cgWindowID = windowInfo.cgWindowID,
           accessibilityService.getWindowID(for: element) == cgWindowID {
            return true
        }

        let title = normalizedWindowTitle(windowInfo)
        if !title.isEmpty,
           title == normalizedTitle(for: element) {
            return true
        }

        return false
    }

    private func normalizedWindowTitle(_ windowInfo: WindowInfo) -> String {
        let title = windowInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? windowInfo.appName : title
    }

    private func normalizedTitle(for element: AXUIElement) -> String {
        var value: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
            let title = value as? String
        else {
            return ""
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func showContextMenu(with event: NSEvent) {
        let menu = NSMenu()
        let unpinItem = NSMenuItem(title: "Unpin from Launcher", action: #selector(unpinFromLauncher(_:)), keyEquivalent: "")
        unpinItem.target = self
        menu.addItem(unpinItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc
    private func unpinFromLauncher(_ sender: Any?) {
        unpinHandler()
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
