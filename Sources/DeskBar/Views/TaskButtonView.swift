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
    private let windowInfo: WindowInfo
    private let hasBadge: Bool
    private let isAccessibilityAvailable: Bool
    private let blacklistManager: BlacklistManager
    private let activationHandler: (WindowInfo) -> Void
    private let dragConfiguration: TaskButtonDragConfiguration?
    private var hoverDelay: TimeInterval
    private var maxWidth: CGFloat
    private let accessibilityService: AccessibilityService
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
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

    init(
        windowInfo: WindowInfo,
        isActive: Bool,
        hasBadge: Bool,
        isAccessibilityAvailable: Bool,
        settings: TaskbarSettings,
        blacklistManager: BlacklistManager,
        accessibilityService: AccessibilityService = AccessibilityService(),
        dragConfiguration: TaskButtonDragConfiguration? = nil,
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
        self.blacklistManager = blacklistManager
        self.hoverDelay = settings.hoverDelay
        self.maxWidth = settings.maxTaskWidth
        self.accessibilityService = accessibilityService
        self.dragConfiguration = dragConfiguration
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
        let horizontalPadding: CGFloat = 50
        let titleWidth = titleLabel.isHidden ? 0 : titleLabel.intrinsicContentSize.width
        let preferredWidth = min(maxWidth, horizontalPadding + titleWidth)
        return NSSize(width: preferredWidth, height: 32)
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
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dropIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        dropIndicatorView.wantsLayer = true
        dropIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicatorView.layer?.cornerRadius = 1
        dropIndicatorView.isHidden = true

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(dropIndicatorView)

        let maxWidthConstraint = widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth)
        self.maxWidthConstraint = maxWidthConstraint
        let dropIndicatorLeadingConstraint = dropIndicatorView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let dropIndicatorTrailingConstraint = dropIndicatorView.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.dropIndicatorLeadingConstraint = dropIndicatorLeadingConstraint
        self.dropIndicatorTrailingConstraint = dropIndicatorTrailingConstraint

        NSLayoutConstraint.activate([
            maxWidthConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

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
                self?.invalidateIntrinsicContentSize()
            }
            .store(in: &cancellables)

        settings.$maxTaskWidth
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.maxWidth = value
                self?.maxWidthConstraint?.constant = value
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
    }

    private func resolvedTitle() -> String {
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
        let title = displayTitle()

        if windowInfo.isProvisional || windowInfo.cgWindowID == nil || windowInfo.cgWindowID == 0 {
            return "\(title) (syncing...)"
        }

        return title
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

        if isAccessibilityAvailable {
            menu.addItem(makeMenuItem(
                title: "Close",
                action: #selector(closeWindow(_:))
            ))
            menu.addItem(makeMenuItem(
                title: "Minimize",
                action: #selector(minimizeWindow(_:))
            ))
            menu.addItem(makeMenuItem(
                title: "Hide",
                action: #selector(hideApplication(_:))
            ))
        } else {
            menu.addItem(makeMenuItem(
                title: "Quit",
                action: #selector(quitApplication(_:))
            ))
        }

        menu.addItem(.separator())
        menu.addItem(makeBlacklistMenuItem())

        return menu
    }

    private func makeMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
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
        updateBackgroundColor()
        invalidateIntrinsicContentSize()
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
    private func quitApplication(_ sender: Any?) {
        owningApplication?.terminate()
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
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
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
