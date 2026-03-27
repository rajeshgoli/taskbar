import AppKit

final class TrayIconView: NSView {
    private let application: NSRunningApplication
    private let pinnedAppManager: PinnedAppManager
    private let iconView = NSImageView()

    init(
        application: NSRunningApplication,
        pinnedAppManager: PinnedAppManager
    ) {
        self.application = application
        self.pinnedAppManager = pinnedAppManager
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        toolTip = application.localizedName ?? application.bundleIdentifier ?? "Unknown"

        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: 24)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }

        application.activate(options: .activateAllWindows)
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func configureSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = application.icon?.scaled(to: NSSize(width: 24, height: 24))

        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApplication(_:)), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        let hideItem = NSMenuItem(title: "Hide", action: #selector(hideApplication(_:)), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        let pinItem = NSMenuItem(title: "Pin to Launcher", action: #selector(pinToLauncher(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.isEnabled = application.bundleIdentifier != nil
        menu.addItem(pinItem)

        return menu
    }

    private func showContextMenu(with event: NSEvent) {
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        application.terminate()
    }

    @objc
    private func hideApplication(_ sender: Any?) {
        application.hide()
    }

    @objc
    private func pinToLauncher(_ sender: Any?) {
        guard let bundleIdentifier = application.bundleIdentifier else {
            return
        }

        pinnedAppManager.pin(
            bundleIdentifier: bundleIdentifier,
            name: application.localizedName ?? bundleIdentifier
        )
    }
}
