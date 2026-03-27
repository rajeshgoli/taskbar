import AppKit

final class GroupHeaderButton: NSView {
    private let appGroup: AppGroup
    private let hasBadge: Bool
    private let activationHandler: () -> Void
    private let iconView = NSImageView()
    private let badgeView = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
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
        activationHandler: @escaping () -> Void
    ) {
        self.appGroup = appGroup
        self.hasBadge = hasBadge
        self.isActive = isActive
        self.activationHandler = activationHandler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        configureSubviews()
        updateAppearance()
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
    }

    override func mouseDown(with event: NSEvent) {
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

        addSubview(iconView)
        addSubview(badgeView)
        badgeView.addSubview(badgeLabel)

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
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor)
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

    private func updateBackgroundColor() {
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
