import AppKit

final class TaskButtonView: NSView {
    private static var activeHoverView: TaskButtonView?

    private let hoverDelay: TimeInterval = 0.4
    private let windowInfo: WindowInfo
    private let activationHandler: (WindowInfo) -> Void
    private let maxWidth: CGFloat
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let thumbnailPopover = ThumbnailPopover()
    private var trackingAreaRef: NSTrackingArea?
    private var hoverWorkItem: DispatchWorkItem?
    private var thumbnailRequestTask: Task<Void, Never>?
    private var isHovered = false {
        didSet {
            updateBackgroundColor()
        }
    }

    var thumbnailProvider: (@MainActor (CGWindowID) async -> NSImage?)?

    var isActive: Bool {
        didSet {
            updateBackgroundColor()
        }
    }

    init(
        windowInfo: WindowInfo,
        isActive: Bool,
        maxWidth: CGFloat = 200,
        activationHandler: @escaping (WindowInfo) -> Void
    ) {
        self.windowInfo = windowInfo
        self.isActive = isActive
        self.maxWidth = maxWidth
        self.activationHandler = activationHandler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        setupSubviews()
        updateBackgroundColor()
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
        let preferredWidth = min(maxWidth, horizontalPadding + titleLabel.intrinsicContentSize.width)
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

        if TaskButtonView.activeHoverView === self {
            TaskButtonView.activeHoverView = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        activationHandler(windowInfo)
    }

    private func setupSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = windowInfo.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.stringValue = resolvedTitle()
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = resolvedToolTip()

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func resolvedTitle() -> String {
        let windowTitle = windowInfo.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return windowTitle.isEmpty ? windowInfo.appName : windowTitle
    }

    private func resolvedToolTip() -> String {
        let title = resolvedTitle()

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

    private func updateBackgroundColor() {
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
