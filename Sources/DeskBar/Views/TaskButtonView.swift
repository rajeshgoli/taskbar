import AppKit
import ApplicationServices
import Combine

enum DeskBarDragZone: String, Codable {
    case task
    case launcher
}

enum DeskBarDropEdge {
    case leading
    case trailing
}

struct DeskBarDragPayload: Codable {
    let zone: DeskBarDragZone
    let itemID: String
}

struct TaskButtonDragConfiguration {
    let payload: DeskBarDragPayload
    let validateDrop: (DeskBarDragPayload, DeskBarDropEdge) -> Bool
    let acceptDrop: (DeskBarDragPayload, DeskBarDropEdge) -> Bool
}

struct TaskButtonPluginMenuConfiguration {
    let buttonTitle: String
    let tintColor: NSColor
    let showsActionButton: Bool
    let menuProvider: () -> NSMenu
}

final class TaskButtonView: NSView, NSDraggingSource {
    private static var activeHoverView: TaskButtonView?
    static let dragPasteboardType = NSPasteboard.PasteboardType("com.deskbar.task")

    private enum WindowState {
        case active
        case normal
        case minimized
        case hidden
    }

    private let settings: TaskbarSettings
    private var windowInfo: WindowInfo
    private var hasBadge: Bool
    private var isAccessibilityAvailable: Bool
    private var runtimeState: AppRuntimeState
    private var showsActivityOverlay: Bool
    private var agentAnnotation: SMAgentWindowAnnotation?
    private let blacklistManager: BlacklistManager
    private let activationHandler: (WindowInfo) -> Void
    private var pluginMenuConfiguration: TaskButtonPluginMenuConfiguration?
    private let dragConfiguration: TaskButtonDragConfiguration?
    private var hoverDelay: TimeInterval
    private var maxWidth: CGFloat
    private let accessibilityService: AccessibilityService
    private let pluginActionButton = TaskButtonPluginActionButton()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusIndicatorView = NSView()
    private let activityBadgeView = NSVisualEffectView()
    private let activityLabel = NSTextField(labelWithString: "")
    private let progressTrackView = NSView()
    private let progressFillView = NSView()
    private let thumbnailPopover: ThumbnailPopover
    private let owningApplication: NSRunningApplication?
    private let dropIndicatorView = NSView()
    private lazy var windowElement: AXUIElement? = {
        Self.resolveWindowElement(
            for: windowInfo,
            application: owningApplication,
            accessibilityService: accessibilityService
        )
    }()
    private var trackingAreaRef: NSTrackingArea?
    private var hoverWorkItem: DispatchWorkItem?
    private var thumbnailRequestTask: Task<Void, Never>?
    private var maxWidthConstraint: NSLayoutConstraint?
    private var statusDefaultLeadingConstraint: NSLayoutConstraint?
    private var statusSMLeadingConstraint: NSLayoutConstraint?
    private var iconDefaultLeadingConstraint: NSLayoutConstraint?
    private var iconSMLeadingConstraint: NSLayoutConstraint?
    private var titleTrailingConstraint: NSLayoutConstraint?
    private var progressWidthConstraint: NSLayoutConstraint?
    private var dropIndicatorLeadingConstraint: NSLayoutConstraint?
    private var dropIndicatorTrailingConstraint: NSLayoutConstraint?
    private var cancellables = Set<AnyCancellable>()
    private var mouseDownLocation: NSPoint?
    private var didBeginDraggingSession = false
    private var isHovered = false {
        didSet {
            updateBackgroundColor()
        }
    }

    var thumbnailProvider: (@MainActor (CGWindowID) async -> NSImage?)?

    var isActive: Bool {
        didSet {
            updateAppearance()
        }
    }

    private var windowState: WindowState {
        if isActive {
            return .active
        }

        if windowInfo.isHidden {
            return .hidden
        }

        if windowInfo.isMinimized {
            return .minimized
        }

        return .normal
    }

    private var effectiveTaskWidth: CGFloat {
        guard agentAnnotation != nil else {
            return maxWidth
        }

        let friendlyName = resolvedTitle().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !friendlyName.isEmpty else {
            return maxWidth
        }

        let font = titleLabel.font ?? NSFont.systemFont(ofSize: settings.titleFontSize)
        let textWidth = (friendlyName as NSString).size(withAttributes: [.font: font]).width
        let extraWidth: CGFloat = showsPluginActionButton ? 106 : 76
        return min(max(maxWidth, ceil(textWidth + extraWidth)), 340)
    }

    private var showsPluginActionButton: Bool {
        pluginMenuConfiguration?.showsActionButton == true
    }

    private var hasPluginMenu: Bool {
        pluginMenuConfiguration != nil
    }

    init(
        windowInfo: WindowInfo,
        isActive: Bool,
        hasBadge: Bool,
        isAccessibilityAvailable: Bool,
        runtimeState: AppRuntimeState,
        showsActivityOverlay: Bool,
        agentAnnotation: SMAgentWindowAnnotation? = nil,
        settings: TaskbarSettings,
        blacklistManager: BlacklistManager,
        accessibilityService: AccessibilityService = AccessibilityService(),
        dragConfiguration: TaskButtonDragConfiguration? = nil,
        pluginMenuConfiguration: TaskButtonPluginMenuConfiguration? = nil,
        activationHandler: @escaping (WindowInfo) -> Void
    ) {
        let owningApplication = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == windowInfo.pid
        }

        self.settings = settings
        self.windowInfo = windowInfo
        self.hasBadge = hasBadge
        self.isActive = isActive
        self.isAccessibilityAvailable = isAccessibilityAvailable
        self.runtimeState = runtimeState
        self.showsActivityOverlay = showsActivityOverlay
        self.agentAnnotation = agentAnnotation
        self.blacklistManager = blacklistManager
        self.hoverDelay = settings.hoverDelay
        self.maxWidth = settings.maxTaskWidth
        self.accessibilityService = accessibilityService
        self.dragConfiguration = dragConfiguration
        self.pluginMenuConfiguration = pluginMenuConfiguration
        self.activationHandler = activationHandler
        self.thumbnailPopover = ThumbnailPopover(settings: settings)
        self.owningApplication = owningApplication
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        setupSubviews()
        bindSettings()
        updateAppearance()

        if dragConfiguration != nil {
            registerForDraggedTypes([Self.dragPasteboardType])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancelHoverPreview()

        if TaskButtonView.activeHoverView === self {
            TaskButtonView.activeHoverView = nil
        }
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: effectiveTaskWidth, height: 32)
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
        TaskButtonView.activeHoverView?.cancelHoverPreview()
        TaskButtonView.activeHoverView = nil

        guard shouldShowThumbnailPopover else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.requestThumbnailPreview()
        }

        hoverWorkItem?.cancel()
        hoverWorkItem = workItem
        TaskButtonView.activeHoverView = self
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: workItem)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        cancelHoverPreview()
        updateDropIndicator(nil)

        if TaskButtonView.activeHoverView === self {
            TaskButtonView.activeHoverView = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        didBeginDraggingSession = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard canStartDragSession else {
            return
        }

        guard let mouseDownLocation else {
            return
        }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let distance = hypot(currentLocation.x - mouseDownLocation.x, currentLocation.y - mouseDownLocation.y)

        guard distance >= 3 else {
            return
        }

        beginDragSession(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            didBeginDraggingSession = false
        }

        guard !didBeginDraggingSession else {
            return
        }

        activationHandler(windowInfo)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }

        guard settings.middleClickCloses else {
            return
        }

        closeWindow(nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = makeContextMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func setupSubviews() {
        pluginActionButton.translatesAutoresizingMaskIntoConstraints = false
        pluginActionButton.contentTintColor = .secondaryLabelColor
        pluginActionButton.toolTip = "Session Manager actions"
        pluginActionButton.target = self
        pluginActionButton.action = #selector(showPluginMenuFromButton(_:))
        pluginActionButton.isHidden = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        addSubview(pluginActionButton)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(activityBadgeView)
        activityBadgeView.addSubview(activityLabel)
        addSubview(progressTrackView)
        progressTrackView.addSubview(progressFillView)
        addSubview(dropIndicatorView)

        let maxWidthConstraint = widthAnchor.constraint(equalToConstant: effectiveTaskWidth)
        self.maxWidthConstraint = maxWidthConstraint
        let titleTrailingConstraint = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        self.titleTrailingConstraint = titleTrailingConstraint
        let progressWidthConstraint = progressFillView.widthAnchor.constraint(equalToConstant: 0)
        self.progressWidthConstraint = progressWidthConstraint
        let dropIndicatorLeadingConstraint = dropIndicatorView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let dropIndicatorTrailingConstraint = dropIndicatorView.trailingAnchor.constraint(equalTo: trailingAnchor)
        let statusDefaultLeadingConstraint = statusIndicatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3)
        let statusSMLeadingConstraint = statusIndicatorView.leadingAnchor.constraint(equalTo: pluginActionButton.trailingAnchor, constant: 3)
        let iconDefaultLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        let iconSMLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: statusIndicatorView.trailingAnchor, constant: 5)
        self.statusDefaultLeadingConstraint = statusDefaultLeadingConstraint
        self.statusSMLeadingConstraint = statusSMLeadingConstraint
        self.iconDefaultLeadingConstraint = iconDefaultLeadingConstraint
        self.iconSMLeadingConstraint = iconSMLeadingConstraint
        self.dropIndicatorLeadingConstraint = dropIndicatorLeadingConstraint
        self.dropIndicatorTrailingConstraint = dropIndicatorTrailingConstraint

        NSLayoutConstraint.activate([
            maxWidthConstraint,

            statusDefaultLeadingConstraint,
            statusIndicatorView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            statusIndicatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            statusIndicatorView.widthAnchor.constraint(equalToConstant: 3),

            pluginActionButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pluginActionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pluginActionButton.widthAnchor.constraint(equalToConstant: 20),
            pluginActionButton.heightAnchor.constraint(equalToConstant: 20),

            iconDefaultLeadingConstraint,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleTrailingConstraint,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            activityBadgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            activityBadgeView.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            activityLabel.leadingAnchor.constraint(equalTo: activityBadgeView.leadingAnchor, constant: 5),
            activityLabel.trailingAnchor.constraint(equalTo: activityBadgeView.trailingAnchor, constant: -5),
            activityLabel.topAnchor.constraint(equalTo: activityBadgeView.topAnchor, constant: 2),
            activityLabel.bottomAnchor.constraint(equalTo: activityBadgeView.bottomAnchor, constant: -2),

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

    private func bindSettings() {
        settings.$titleFontSize
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.titleLabel.font = NSFont.systemFont(ofSize: value)
                self?.maxWidthConstraint?.constant = self?.effectiveTaskWidth ?? value
                self?.invalidateIntrinsicContentSize()
            }
            .store(in: &cancellables)

        settings.$maxTaskWidth
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.maxWidth = value
                self?.maxWidthConstraint?.constant = self?.effectiveTaskWidth ?? value
                self?.invalidateIntrinsicContentSize()
            }
            .store(in: &cancellables)

        settings.$showTitles
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.titleLabel.isHidden = !value
                self?.invalidateIntrinsicContentSize()
            }
            .store(in: &cancellables)

        settings.$hoverDelay
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.hoverDelay = value
            }
            .store(in: &cancellables)

        let updateForSessionManagerSettings: () -> Void = { [weak self] in
            guard let self else {
                return
            }

            self.updateAppearance()
            self.maxWidthConstraint?.constant = self.effectiveTaskWidth
            self.invalidateIntrinsicContentSize()
        }

        settings.$enableSessionManagerPlugin
            .receive(on: RunLoop.main)
            .sink { _ in updateForSessionManagerSettings() }
            .store(in: &cancellables)

        settings.$showSessionManagerAgentTitles
            .receive(on: RunLoop.main)
            .sink { _ in updateForSessionManagerSettings() }
            .store(in: &cancellables)

        settings.$showSessionManagerActivityIndicators
            .receive(on: RunLoop.main)
            .sink { _ in updateForSessionManagerSettings() }
            .store(in: &cancellables)

        settings.$animateSessionManagerActivity
            .receive(on: RunLoop.main)
            .sink { _ in updateForSessionManagerSettings() }
            .store(in: &cancellables)

        settings.$enableSessionManagerTerminalActions
            .receive(on: RunLoop.main)
            .sink { _ in updateForSessionManagerSettings() }
            .store(in: &cancellables)

        settings.$showSessionManagerActionButton
            .receive(on: RunLoop.main)
            .sink { _ in updateForSessionManagerSettings() }
            .store(in: &cancellables)
    }

    private func resolvedTitle() -> String {
        if settings.enableSessionManagerPlugin,
           settings.showSessionManagerAgentTitles,
           let agentAnnotation {
            let friendlyName = agentAnnotation.friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !friendlyName.isEmpty {
                return friendlyName
            }
        }

        let windowTitle = windowInfo.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return windowTitle.isEmpty ? windowInfo.appName : windowTitle
    }

    private func displayTitle() -> String {
        switch windowState {
        case .minimized:
            return "[\(resolvedTitle())]"
        case .hidden:
            return "(\(resolvedTitle()))"
        case .active, .normal:
            return resolvedTitle()
        }
    }

    private func resolvedToolTip() -> String {
        var lines = [displayTitle()]

        if settings.enableSessionManagerPlugin, let agentAnnotation {
            lines.append("SM: \(agentAnnotation.activityState.displayName) - \(agentAnnotation.provider) - \(agentAnnotation.sessionStatus)")
            if let agentStatusText = trimmed(agentAnnotation.agentStatusText) {
                lines.append(agentStatusText)
            } else if let currentTask = trimmed(agentAnnotation.currentTask) {
                lines.append(currentTask)
            }
            if let lastActionSummary = trimmed(agentAnnotation.lastActionSummary) {
                lines.append("Last: \(lastActionSummary)")
            } else if let lastToolName = trimmed(agentAnnotation.lastToolName) {
                lines.append("Tool: \(lastToolName)")
            }
            if let tokensUsed = agentAnnotation.tokensUsed, tokensUsed > 0 {
                lines.append("Tokens: \(tokensUsed)")
            }
            lines.append(agentAnnotation.workingDirectory)
            lines.append("Session: \(agentAnnotation.sessionID)")

            let rawTitle = windowInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawTitle.isEmpty, rawTitle != agentAnnotation.friendlyName {
                lines.append("Terminal: \(rawTitle)")
            }
        }

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

    private func trimmed(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedValue, !trimmedValue.isEmpty else {
            return nil
        }

        return trimmedValue
    }

    private var shouldShowThumbnailPopover: Bool {
        guard let cgWindowID = windowInfo.cgWindowID else {
            return false
        }

        return cgWindowID != 0 && !windowInfo.isProvisional
    }

    private func requestThumbnailPreview() {
        hoverWorkItem = nil

        guard
            isHovered,
            TaskButtonView.activeHoverView === self,
            let cgWindowID = windowInfo.cgWindowID,
            cgWindowID != 0,
            let thumbnailProvider
        else {
            return
        }

        thumbnailRequestTask?.cancel()

        thumbnailRequestTask = Task { @MainActor [weak self] in
            let thumbnail = await thumbnailProvider(cgWindowID)

            guard !Task.isCancelled else {
                return
            }

            guard
                let self,
                self.isHovered,
                TaskButtonView.activeHoverView === self
            else {
                return
            }

            if let thumbnail {
                self.thumbnailPopover.show(thumbnail: thumbnail, relativeTo: self)
            }
        }
    }

    private func cancelHoverPreview() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        thumbnailRequestTask?.cancel()
        thumbnailRequestTask = nil
        thumbnailPopover.close()
    }

    private var canStartDragSession: Bool {
        settings.dragReorder && dragConfiguration != nil
    }

    private func beginDragSession(with event: NSEvent) {
        guard
            !didBeginDraggingSession,
            let dragConfiguration,
            let pasteboardItem = Self.makePasteboardItem(for: dragConfiguration.payload)
        else {
            return
        }

        didBeginDraggingSession = true
        cancelHoverPreview()

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: draggingPreviewImage())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
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

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addPluginMenuItems(to: menu, includeTrailingSeparator: true)

        // Window list section (Dock-style)
        if isAccessibilityAvailable, let app = owningApplication {
            let windows = accessibilityService.enumerateWindows(for: app)
            if !windows.isEmpty {
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                for axWindow in windows {
                    let title = accessibilityService.windowTitle(for: axWindow) ?? "Untitled"
                    let item = NSMenuItem(title: title, action: #selector(activateSpecificWindow(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = axWindow
                    item.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
                    item.image?.size = NSSize(width: 14, height: 14)
                    // Checkmark on active window
                    if app.processIdentifier == frontmostPID {
                        var isFocused = false
                        var focusedWindow: CFTypeRef?
                        let appElement = AXUIElementCreateApplication(app.processIdentifier)
                        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success {
                            isFocused = (axWindow == (focusedWindow as! AXUIElement))
                        }
                        item.state = isFocused ? .on : .off
                    }
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }
        }

        // App actions
        menu.addItem(makeMenuItem(title: "Show All Windows", action: #selector(showAllWindows(_:))))
        menu.addItem(makeMenuItem(title: "Hide", action: #selector(hideApplication(_:))))

        menu.addItem(.separator())
        menu.addItem(makePinToLauncherMenuItem())
        menu.addItem(makeBlacklistMenuItem())

        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Quit", action: #selector(quitApplication(_:))))

        return menu
    }

    private func makePluginMenu() -> NSMenu {
        pluginMenuConfiguration?.menuProvider() ?? NSMenu()
    }

    private func addPluginMenuItems(to menu: NSMenu, includeTrailingSeparator: Bool) {
        guard hasPluginMenu else {
            return
        }

        let pluginMenu = makePluginMenu()
        while pluginMenu.numberOfItems > 0 {
            guard let item = pluginMenu.item(at: 0) else {
                break
            }

            pluginMenu.removeItem(item)
            menu.addItem(item)
        }

        if includeTrailingSeparator {
            menu.addItem(.separator())
        }
    }

    private func makeMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makePinToLauncherMenuItem() -> NSMenuItem {
        let item = makeMenuItem(title: "Pin to Launcher", action: #selector(pinToLauncher(_:)))
        item.isEnabled = windowInfo.bundleIdentifier != nil
        return item
    }

    private func makeBlacklistMenuItem() -> NSMenuItem {
        let item = makeMenuItem(title: "Add to Blacklist", action: #selector(addToBlacklist(_:)))
        if let bundleIdentifier = windowInfo.bundleIdentifier {
            item.isEnabled = !blacklistManager.isBlacklisted(bundleIdentifier: bundleIdentifier)
        } else {
            item.isEnabled = false
        }
        return item
    }

    private func updateAppearance() {
        titleLabel.stringValue = displayTitle()
        titleLabel.textColor = textColor()
        toolTip = resolvedToolTip()
        iconView.image = displayIcon()
        iconView.alphaValue = iconAlpha()
        updateTaskButtonPluginActionButton()
        updateStatusIndicator()
        updateActivityBadge()
        updateProgressIndicator()
        updateBackgroundColor()
        invalidateIntrinsicContentSize()
    }

    private func updateTaskButtonPluginActionButton() {
        pluginActionButton.isHidden = !showsPluginActionButton
        statusDefaultLeadingConstraint?.isActive = !showsPluginActionButton
        statusSMLeadingConstraint?.isActive = showsPluginActionButton
        iconDefaultLeadingConstraint?.isActive = !showsPluginActionButton
        iconSMLeadingConstraint?.isActive = showsPluginActionButton
        pluginActionButton.title = pluginMenuConfiguration?.buttonTitle ?? ""
        pluginActionButton.contentTintColor = pluginMenuConfiguration?.tintColor ?? .secondaryLabelColor
        pluginActionButton.activityColor = pluginMenuConfiguration?.tintColor ?? .secondaryLabelColor
    }

    func update(
        windowInfo: WindowInfo,
        isActive: Bool,
        hasBadge: Bool,
        isAccessibilityAvailable: Bool,
        runtimeState: AppRuntimeState,
        showsActivityOverlay: Bool,
        agentAnnotation: SMAgentWindowAnnotation? = nil,
        pluginMenuConfiguration: TaskButtonPluginMenuConfiguration? = nil
    ) {
        let previousThumbnailEligibility = shouldShowThumbnailPopover
        let previousWindowID = self.windowInfo.cgWindowID

        self.windowInfo = windowInfo
        self.isActive = isActive
        self.hasBadge = hasBadge
        self.isAccessibilityAvailable = isAccessibilityAvailable
        self.runtimeState = runtimeState
        self.showsActivityOverlay = showsActivityOverlay
        self.agentAnnotation = agentAnnotation
        self.pluginMenuConfiguration = pluginMenuConfiguration
        maxWidthConstraint?.constant = effectiveTaskWidth

        if previousWindowID != windowInfo.cgWindowID {
            windowElement = Self.resolveWindowElement(
                for: windowInfo,
                application: owningApplication,
                accessibilityService: accessibilityService
            )
        }

        if previousThumbnailEligibility && !shouldShowThumbnailPopover {
            cancelHoverPreview()
        }

        updateAppearance()
    }

    @objc
    private func closeWindow(_ sender: Any?) {
        guard let windowElement else {
            return
        }

        accessibilityService.close(element: windowElement)
    }

    @objc
    private func minimizeWindow(_ sender: Any?) {
        guard let windowElement else {
            return
        }

        accessibilityService.minimize(element: windowElement)
    }

    @objc
    private func hideApplication(_ sender: Any?) {
        owningApplication?.hide()
    }

    @objc
    private func showAllWindows(_ sender: Any?) {
        owningApplication?.unhide()
        owningApplication?.activate(options: .activateAllWindows)
    }

    @objc
    private func showPluginMenuFromButton(_ sender: Any?) {
        guard hasPluginMenu else {
            return
        }

        let menu = makePluginMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pluginActionButton.bounds.maxY + 2), in: pluginActionButton)
    }

    @objc
    private func activateSpecificWindow(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let obj = menuItem.representedObject else { return }
        let axWindow = obj as! AXUIElement
        if let owningApplication {
            accessibilityService.raiseAndActivate(element: axWindow, app: owningApplication)
        }
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        owningApplication?.terminate()
    }

    @objc
    private func pinToLauncher(_ sender: Any?) {
        guard let bundleIdentifier = windowInfo.bundleIdentifier else { return }
        NotificationCenter.default.post(
            name: Notification.Name("DeskBar.pinToLauncher"),
            object: nil,
            userInfo: ["bundleIdentifier": bundleIdentifier, "appName": windowInfo.appName]
        )
    }

    @objc
    private func addToBlacklist(_ sender: Any?) {
        guard let bundleIdentifier = windowInfo.bundleIdentifier else {
            return
        }

        blacklistManager.add(bundleIdentifier: bundleIdentifier)
    }

    private func textColor() -> NSColor {
        switch windowState {
        case .minimized, .hidden:
            return .secondaryLabelColor
        case .active, .normal:
            return .labelColor
        }
    }

    private func displayIcon() -> NSImage? {
        let baseIcon: NSImage?

        switch windowState {
        case .minimized:
            baseIcon = desaturatedIcon()
        case .active, .normal, .hidden:
            baseIcon = windowInfo.icon
        }

        guard let baseIcon else {
            return nil
        }

        if hasBadge {
            return baseIcon.withBadgeDot()
        }

        return baseIcon
    }

    private func iconAlpha() -> CGFloat {
        switch windowState {
        case .minimized:
            return 0.65
        case .hidden:
            return 0.5
        case .active, .normal:
            return 1.0
        }
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

    private func updateStatusIndicator() {
        let hasRuntimeStatus = runtimeState.needsAttention || runtimeState.isLaunching
        let hasAgentStatus = settings.enableSessionManagerPlugin &&
            settings.showSessionManagerActivityIndicators &&
            agentAnnotation != nil
        let isVisible = hasRuntimeStatus || hasAgentStatus
        statusIndicatorView.isHidden = !isVisible

        guard isVisible else {
            statusIndicatorView.layer?.removeAnimation(forKey: "deskbar.attention")
            statusIndicatorView.layer?.removeAnimation(forKey: "deskbar.agentActivity")
            return
        }

        let color: NSColor
        if hasRuntimeStatus {
            color = runtimeState.needsAttention ? NSColor.systemOrange : NSColor.systemBlue
        } else {
            color = agentAnnotation?.activityState.color ?? .secondaryLabelColor
        }
        statusIndicatorView.layer?.backgroundColor = color.cgColor

        if runtimeState.needsAttention {
            statusIndicatorView.layer?.removeAnimation(forKey: "deskbar.agentActivity")
            if statusIndicatorView.layer?.animation(forKey: "deskbar.attention") == nil {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0.25
                animation.duration = 0.55
                animation.autoreverses = true
                animation.repeatCount = .infinity
                statusIndicatorView.layer?.add(animation, forKey: "deskbar.attention")
            }
        } else if settings.animateSessionManagerActivity,
                  agentAnnotation?.activityState == .working {
            if statusIndicatorView.layer?.animation(forKey: "deskbar.agentActivity") == nil {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 0.35
                animation.toValue = 1.0
                animation.duration = 1.35
                animation.autoreverses = true
                animation.repeatCount = .infinity
                statusIndicatorView.layer?.add(animation, forKey: "deskbar.agentActivity")
            }
            statusIndicatorView.layer?.removeAnimation(forKey: "deskbar.attention")
        } else {
            statusIndicatorView.layer?.removeAnimation(forKey: "deskbar.attention")
            statusIndicatorView.layer?.removeAnimation(forKey: "deskbar.agentActivity")
        }
    }

    private func updateActivityBadge() {
        if settings.enableSessionManagerPlugin, agentAnnotation != nil {
            activityBadgeView.isHidden = true
            titleTrailingConstraint?.constant = -10
            return
        }

        guard showsActivityOverlay, let activitySummary = runtimeState.activitySummary else {
            activityBadgeView.isHidden = true
            titleTrailingConstraint?.constant = -10
            return
        }

        activityLabel.stringValue = activitySummary
        activityLabel.textColor = .secondaryLabelColor
        activityBadgeView.isHidden = false
        titleTrailingConstraint?.constant = -10
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

    private func desaturatedIcon() -> NSImage? {
        guard let icon = windowInfo.icon else {
            return nil
        }

        let sourceRect = NSRect(origin: .zero, size: icon.size)
        let image = NSImage(size: icon.size)

        image.lockFocus()
        icon.draw(in: sourceRect)
        NSColor(calibratedWhite: 0.65, alpha: 0.45).set()
        sourceRect.fill(using: .sourceAtop)
        image.unlockFocus()

        return image
    }

    private static func resolveWindowElement(
        for windowInfo: WindowInfo,
        application: NSRunningApplication?,
        accessibilityService: AccessibilityService
    ) -> AXUIElement? {
        guard let application else {
            return nil
        }

        let windows = accessibilityService.enumerateWindows(for: application)

        if let cgWindowID = windowInfo.cgWindowID,
           let idMatch = windows.first(where: { accessibilityService.getWindowID(for: $0) == cgWindowID }) {
            return idMatch
        }

        let normalizedTitle = windowInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedTitle.isEmpty,
           let titleMatch = windows.first(where: { axTitle(for: $0) == normalizedTitle }) {
            return titleMatch
        }

        return windows.first
    }

    private static func axTitle(for element: AXUIElement) -> String? {
        var value: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }

        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makePasteboardItem(for payload: DeskBarDragPayload) -> NSPasteboardItem? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let item = NSPasteboardItem()
        item.setString(string, forType: dragPasteboardType)
        return item
    }

    static func decodeDragPayload(from pasteboard: NSPasteboard) -> DeskBarDragPayload? {
        guard let string = pasteboard.string(forType: dragPasteboardType),
              let data = string.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(DeskBarDragPayload.self, from: data)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        canStartDragSession ? .move : []
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
            let payload = Self.decodeDragPayload(from: sender.draggingPasteboard)
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
            let payload = Self.decodeDragPayload(from: sender.draggingPasteboard)
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

private final class TaskButtonPluginActionButton: NSButton {
    var activityColor: NSColor = .secondaryLabelColor {
        didSet {
            updateLayerStyle()
        }
    }

    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false {
        didSet {
            updateLayerStyle()
        }
    }

    init() {
        super.init(frame: .zero)
        title = "sm"
        isBordered = false
        bezelStyle = .regularSquare
        font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 4
        updateLayerStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    }

    private func updateLayerStyle() {
        layer?.backgroundColor = isHovered
            ? activityColor.withAlphaComponent(0.18).cgColor
            : NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = isHovered ? 1 : 0
        layer?.borderColor = activityColor.withAlphaComponent(0.45).cgColor
    }
}
