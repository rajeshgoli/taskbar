import AppKit
import Combine

final class RunningAppTrayView: NSStackView {
    private let windowManager: WindowManager
    private let pinnedAppManager: PinnedAppManager
    private let settings: TaskbarSettings
    private let displayID: CGDirectDisplayID
    private let dividerView = NSView()
    private let iconsStackView = NSStackView()
    private let collapsedSystemResourceWidgetView: CollapsedSystemResourceWidgetView
    private var cancellables = Set<AnyCancellable>()

    var preferredWidthDidChange: (() -> Void)?

    init(
        windowManager: WindowManager,
        pinnedAppManager: PinnedAppManager,
        settings: TaskbarSettings,
        systemResourceMonitor: SystemResourceMonitor,
        displayID: CGDirectDisplayID
    ) {
        self.windowManager = windowManager
        self.pinnedAppManager = pinnedAppManager
        self.settings = settings
        self.displayID = displayID
        self.collapsedSystemResourceWidgetView = CollapsedSystemResourceWidgetView(
            settings: settings,
            monitor: systemResourceMonitor,
            displayID: displayID
        )
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

        settings.$showSystemResourceWidget
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildIcons()
            }
            .store(in: &cancellables)

        settings.$systemResourceWidgetPinnedDisplayID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildIcons()
            }
            .store(in: &cancellables)

        settings.$systemResourceWidgetCollapsed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildIcons()
            }
            .store(in: &cancellables)

        settings.$showSystemResourceMemoryMetric
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildIcons()
            }
            .store(in: &cancellables)

        settings.$showSystemResourceCPUMetric
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildIcons()
            }
            .store(in: &cancellables)

        settings.$showSystemResourceGPUMetric
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildIcons()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        rebuildIcons()
    }

    func preferredContentWidth() -> CGFloat {
        let iconWidth = Self.preferredWidth(
            forArrangedSubviewsIn: iconsStackView,
            spacing: iconsStackView.spacing
        )
        let dividerWidth = dividerView.isHidden ? 0 : Self.preferredWidth(for: dividerView)
        let visibleComponentCount = [dividerWidth, iconWidth].filter { $0 > 0 }.count
        let spacingWidth = CGFloat(max(visibleComponentCount - 1, 0)) * spacing

        return ceil(dividerWidth + iconWidth + spacingWidth)
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

        if shouldShowCollapsedSystemResourceWidget {
            iconsStackView.insertArrangedSubview(collapsedSystemResourceWidgetView, at: 0)
        }

        dividerView.isHidden = iconsStackView.arrangedSubviews.isEmpty
        preferredWidthDidChange?()
    }

    private var localTrayApps: [NSRunningApplication] {
        guard let screen = ScreenGeometry.screen(for: displayID) else {
            return []
        }

        return windowManager.trayApplications(on: screen)
    }

    private var shouldShowCollapsedSystemResourceWidget: Bool {
        guard
            settings.showSystemResourceWidget,
            settings.systemResourceWidgetCollapsed,
            [
                settings.showSystemResourceMemoryMetric,
                settings.showSystemResourceCPUMetric,
                settings.showSystemResourceGPUMetric
            ].contains(true)
        else {
            return false
        }

        guard let pinnedDisplayID = settings.systemResourceWidgetPinnedDisplayID else {
            return true
        }

        return pinnedDisplayID == displayID
    }

    private static func preferredWidth(forArrangedSubviewsIn stackView: NSStackView, spacing: CGFloat) -> CGFloat {
        let visibleSubviews = stackView.arrangedSubviews.filter { !$0.isHidden }
        guard !visibleSubviews.isEmpty else {
            return 0
        }

        let contentWidth = visibleSubviews.map(preferredWidth(for:)).reduce(0, +)
        return contentWidth + CGFloat(visibleSubviews.count - 1) * spacing
    }

    private static func preferredWidth(for view: NSView) -> CGFloat {
        let intrinsicWidth = view.intrinsicContentSize.width
        if intrinsicWidth != NSView.noIntrinsicMetric, intrinsicWidth > 0 {
            return intrinsicWidth
        }

        return max(0, view.fittingSize.width)
    }
}
