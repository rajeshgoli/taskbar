import AppKit
import Combine

final class TaskbarContentView: NSView {
    private let windowManager: WindowManager
    private let permissionsManager: PermissionsManager

    private let rootStackView = NSStackView()
    private let bannerButton = NSButton()
    private let zonesStackView = NSStackView()
    private let launcherZoneView = NSView()
    private let launcherLabel = NSTextField(labelWithString: "Launcher")
    private let taskZoneScrollView = NSScrollView()
    private let taskZoneStackView = NSStackView()
    private let trayZoneStackView = NSStackView()

    private var cancellables = Set<AnyCancellable>()

    init(windowManager: WindowManager, permissionsManager: PermissionsManager) {
        self.windowManager = windowManager
        self.permissionsManager = permissionsManager
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        configureLayout()
        bindState()
        rebuildViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func handleAccessibilityPermissionChange() {
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

        let launcherContainer = makeZoneContainer(for: launcherZoneView, width: 120)
        configureLauncherZone()

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

        zonesStackView.addArrangedSubview(launcherContainer)
        zonesStackView.addArrangedSubview(makeDivider())
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

    private func configureLauncherZone() {
        launcherLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        launcherLabel.textColor = NSColor.secondaryLabelColor
        launcherLabel.alignment = .center
        launcherLabel.translatesAutoresizingMaskIntoConstraints = false
        launcherZoneView.addSubview(launcherLabel)

        NSLayoutConstraint.activate([
            launcherLabel.centerXAnchor.constraint(equalTo: launcherZoneView.centerXAnchor),
            launcherLabel.centerYAnchor.constraint(equalTo: launcherZoneView.centerYAnchor)
        ])
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
        let applicationsByPID = Dictionary(uniqueKeysWithValues: runningApplications.map { ($0.processIdentifier, $0) })
        let visibleApplicationPIDs = onScreenApplicationPIDs()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if permissionsManager.isAccessibilityGranted {
            for window in windowManager.windows {
                let buttonView = TaskButtonView(
                    windowInfo: window,
                    isActive: window.pid == frontmostPID
                ) { [weak self] windowInfo in
                    self?.activate(windowInfo: windowInfo)
                }
                taskZoneStackView.addArrangedSubview(buttonView)
                buttonView.heightAnchor.constraint(equalToConstant: 32).isActive = true
            }
        } else {
            let taskItems = runningApplications.compactMap { application in
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
            .filter { !visibleApplicationPIDs.contains($0.processIdentifier) }
            .forEach { application in
                let button = TrayAppButton(application: application)
                button.target = self
                button.action = #selector(activateApplication(_:))
                trayZoneStackView.addArrangedSubview(button)
            }
    }

    private func activate(windowInfo: WindowInfo) {
        guard let application = NSWorkspace.shared.runningApplications.first(
            where: { $0.processIdentifier == windowInfo.pid }
        ) else {
            return
        }

        application.activate(options: .activateAllWindows)
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
