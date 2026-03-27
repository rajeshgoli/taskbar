import AppKit
import Combine

final class RunningAppTrayView: NSStackView {
    private let windowManager: WindowManager
    private let pinnedAppManager: PinnedAppManager
    private let displayID: CGDirectDisplayID
    private let dividerView = NSView()
    private let iconsStackView = NSStackView()
    private var cancellables = Set<AnyCancellable>()

    init(
        windowManager: WindowManager,
        pinnedAppManager: PinnedAppManager,
        displayID: CGDirectDisplayID
    ) {
        self.windowManager = windowManager
        self.pinnedAppManager = pinnedAppManager
        self.displayID = displayID
        super.init(frame: .zero)

        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 8
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false

        configureDividerView()
        configureIconsStackView()
        bindState()
        rebuildIcons()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureDividerView() {
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        dividerView.translatesAutoresizingMaskIntoConstraints = false

        addArrangedSubview(dividerView)
        NSLayoutConstraint.activate([
            dividerView.widthAnchor.constraint(equalToConstant: 1),
            dividerView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func configureIconsStackView() {
        iconsStackView.orientation = .horizontal
        iconsStackView.alignment = .centerY
        iconsStackView.distribution = .fill
        iconsStackView.spacing = 4
        iconsStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        addArrangedSubview(iconsStackView)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    }

    private func bindState() {
        windowManager.$windows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildIcons()
            }
            .store(in: &cancellables)

        pinnedAppManager.$pinnedApps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildIcons()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        rebuildIcons()
    }

    private func rebuildIcons() {
        iconsStackView.arrangedSubviews.forEach { view in
            iconsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for application in localTrayApps {
            iconsStackView.addArrangedSubview(
                TrayIconView(
                    application: application,
                    pinnedAppManager: pinnedAppManager
                )
            )
        }
    }

    private var localTrayApps: [NSRunningApplication] {
        guard let screen = ScreenGeometry.screen(for: displayID) else {
            return []
        }

        return windowManager.trayApplications(on: screen)
    }
}
