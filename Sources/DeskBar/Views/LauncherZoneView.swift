import AppKit
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

            let buttonView = LauncherButtonView(
                pinnedApp: pinnedApp,
                visibleLocalWindows: visibleLocalWindows,
                runningApplication: runningApplicationsByBundleIdentifier[pinnedApp.bundleIdentifier]
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
}
