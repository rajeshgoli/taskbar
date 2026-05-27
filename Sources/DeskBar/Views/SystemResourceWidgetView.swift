import AppKit
import Combine

final class SystemResourceWidgetView: NSView {
    private static let separatorWidth: CGFloat = 1
    private static let separatorHeight: CGFloat = 24
    private static let memoryWidth: CGFloat = 170
    private static let metricWidth: CGFloat = 125
    private static let collapseWidth: CGFloat = 28
    private static let widgetHeight: CGFloat = 32
    private static let stackSpacing: CGFloat = 8
    private static let leadingInset: CGFloat = 4

    private let settings: TaskbarSettings
    private let monitor: SystemResourceMonitor
    private let displayID: CGDirectDisplayID
    private let stackView = NSStackView()
    private let separatorView = NSView()
    private let memoryControl = SystemResourceMetricControl(metric: .memory)
    private let cpuControl = SystemResourceMetricControl(metric: .cpu)
    private let gpuControl = SystemResourceMetricControl(metric: .gpu)
    private let collapseButton = NSButton()
    private var widthConstraint: NSLayoutConstraint?
    private var cancellables = Set<AnyCancellable>()

    var preferredWidthDidChange: (() -> Void)?

    init(
        settings: TaskbarSettings,
        monitor: SystemResourceMonitor,
        displayID: CGDirectDisplayID
    ) {
        self.settings = settings
        self.monitor = monitor
        self.displayID = displayID
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        configureSubviews()
        configureActions()
        bindState()
        update(with: monitor.snapshot)
        updateMetricVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        isHidden ? .zero : NSSize(width: expandedContentWidth(), height: Self.widgetHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    func preferredContentWidth() -> CGFloat {
        isHidden ? 0 : expandedContentWidth()
    }

    private func configureSubviews() {
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = Self.stackSpacing
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: Self.leadingInset, bottom: 0, right: 0)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separatorView)
        stackView.addArrangedSubview(memoryControl)
        stackView.addArrangedSubview(cpuControl)
        stackView.addArrangedSubview(gpuControl)
        NSLayoutConstraint.activate([
            separatorView.widthAnchor.constraint(equalToConstant: Self.separatorWidth),
            separatorView.heightAnchor.constraint(equalToConstant: Self.separatorHeight),
            memoryControl.widthAnchor.constraint(equalToConstant: Self.memoryWidth),
            cpuControl.widthAnchor.constraint(equalToConstant: Self.metricWidth),
            gpuControl.widthAnchor.constraint(equalToConstant: Self.metricWidth),
            memoryControl.heightAnchor.constraint(equalToConstant: Self.widgetHeight),
            cpuControl.heightAnchor.constraint(equalToConstant: Self.widgetHeight),
            gpuControl.heightAnchor.constraint(equalToConstant: Self.widgetHeight)
        ])

        configureIconButton(
            collapseButton,
            symbolName: "chevron.right",
            fallbackTitle: ">",
            tooltip: "Collapse system resource widget"
        )
        stackView.addArrangedSubview(collapseButton)
        let widthConstraint = widthAnchor.constraint(equalToConstant: expandedContentWidth())
        self.widthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            collapseButton.widthAnchor.constraint(equalToConstant: Self.collapseWidth),
            collapseButton.heightAnchor.constraint(equalToConstant: Self.collapseWidth),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Self.widgetHeight)
        ])
    }

    private func configureIconButton(
        _ button: NSButton,
        symbolName: String,
        fallbackTitle: String,
        tooltip: String
    ) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.title = fallbackTitle
            button.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        }
    }

    private func configureActions() {
        memoryControl.target = self
        memoryControl.action = #selector(openMemoryMonitor(_:))

        cpuControl.target = self
        cpuControl.action = #selector(openCPUMonitor(_:))

        gpuControl.target = self
        gpuControl.action = #selector(openGPUMonitor(_:))

        collapseButton.target = self
        collapseButton.action = #selector(collapseWidget(_:))
    }

    private func bindState() {
        monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.update(with: snapshot)
            }
            .store(in: &cancellables)

        settings.$showSystemResourceWidget
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMetricVisibility()
            }
            .store(in: &cancellables)

        settings.$systemResourceWidgetCollapsed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMetricVisibility()
            }
            .store(in: &cancellables)

        settings.$systemResourceWidgetPinnedDisplayID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMetricVisibility()
            }
            .store(in: &cancellables)

        settings.$showSystemResourceMemoryMetric
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMetricVisibility()
            }
            .store(in: &cancellables)

        settings.$showSystemResourceCPUMetric
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMetricVisibility()
            }
            .store(in: &cancellables)

        settings.$showSystemResourceGPUMetric
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMetricVisibility()
            }
            .store(in: &cancellables)
    }

    private func update(with snapshot: SystemResourceSnapshot) {
        memoryControl.update(
            value: memoryValueString(for: snapshot),
            fraction: snapshot.memoryUsedPercent.map { $0 / 100 },
            detail: memoryTooltip(for: snapshot),
            severity: metricSeverity(
                percent: snapshot.memoryUsedPercent,
                pressureLevel: snapshot.memoryPressureLevel
            )
        )
        cpuControl.update(
            value: percentString(snapshot.cpuPercent),
            fraction: snapshot.cpuPercent.map { $0 / 100 },
            detail: metricTooltip(name: "CPU usage", percent: snapshot.cpuPercent, destination: "Activity Monitor CPU History"),
            severity: metricSeverity(percent: snapshot.cpuPercent)
        )
        gpuControl.update(
            value: percentString(snapshot.gpuPercent),
            fraction: snapshot.gpuPercent.map { $0 / 100 },
            detail: metricTooltip(name: "GPU usage", percent: snapshot.gpuPercent, destination: "Activity Monitor GPU History"),
            severity: metricSeverity(percent: snapshot.gpuPercent)
        )
    }

    private func updateMetricVisibility() {
        memoryControl.isHidden = !settings.showSystemResourceMemoryMetric
        cpuControl.isHidden = !settings.showSystemResourceCPUMetric
        gpuControl.isHidden = !settings.showSystemResourceGPUMetric

        let shouldShow = settings.showSystemResourceWidget &&
            !settings.systemResourceWidgetCollapsed &&
            displayMatchesPin &&
            enabledMetricCount > 0
        isHidden = !shouldShow
        widthConstraint?.constant = expandedContentWidth()
        invalidateIntrinsicContentSize()
        preferredWidthDidChange?()
    }

    private var displayMatchesPin: Bool {
        guard let pinnedDisplayID = settings.systemResourceWidgetPinnedDisplayID else {
            return true
        }

        return pinnedDisplayID == displayID
    }

    private var enabledMetricCount: Int {
        [
            settings.showSystemResourceMemoryMetric,
            settings.showSystemResourceCPUMetric,
            settings.showSystemResourceGPUMetric
        ].filter { $0 }.count
    }

    private func expandedContentWidth() -> CGFloat {
        guard enabledMetricCount > 0 else {
            return 0
        }

        var widths: [CGFloat] = [Self.separatorWidth]
        if settings.showSystemResourceMemoryMetric {
            widths.append(Self.memoryWidth)
        }
        if settings.showSystemResourceCPUMetric {
            widths.append(Self.metricWidth)
        }
        if settings.showSystemResourceGPUMetric {
            widths.append(Self.metricWidth)
        }
        widths.append(Self.collapseWidth)

        let spacing = CGFloat(max(widths.count - 1, 0)) * Self.stackSpacing
        return Self.leadingInset + widths.reduce(0, +) + spacing
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let collapseItem = NSMenuItem(title: "Collapse Widget", action: #selector(collapseWidget(_:)), keyEquivalent: "")
        collapseItem.target = self
        menu.addItem(collapseItem)

        menu.addItem(.separator())

        let pinItem = NSMenuItem(
            title: "Pin to \(displayName)",
            action: #selector(pinWidgetToThisDisplay(_:)),
            keyEquivalent: ""
        )
        pinItem.target = self
        pinItem.isEnabled = settings.systemResourceWidgetPinnedDisplayID != displayID
        menu.addItem(pinItem)

        let allDisplaysItem = NSMenuItem(
            title: "Show on All Displays",
            action: #selector(showWidgetOnAllDisplays(_:)),
            keyEquivalent: ""
        )
        allDisplaysItem.target = self
        allDisplaysItem.isEnabled = settings.systemResourceWidgetPinnedDisplayID != nil
        menu.addItem(allDisplaysItem)

        menu.addItem(.separator())

        let hideItem = NSMenuItem(title: "Hide System Resource Widget", action: #selector(hideWidget(_:)), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        return menu
    }

    private var displayName: String {
        ScreenGeometry.screen(for: displayID)?.localizedName ?? "This Display"
    }

    private func percentString(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        return "\(Int(value.rounded()))%"
    }

    private func memoryValueString(for snapshot: SystemResourceSnapshot) -> String {
        guard let usedBytes = snapshot.memoryUsedBytes,
              let totalBytes = snapshot.memoryTotalBytes else {
            return percentString(snapshot.memoryUsedPercent)
        }

        return "\(Self.memoryAmountString(usedBytes, includesUnit: false))/\(Self.memoryAmountString(totalBytes, includesUnit: true))"
    }

    private func memoryTooltip(for snapshot: SystemResourceSnapshot) -> String {
        let used = memoryValueString(for: snapshot)
        let pressure = percentString(snapshot.memoryPressurePercent)
        let free = snapshot.memoryFreePercent.map { "\(Int($0.rounded()))% free" } ?? "free memory unavailable"
        return "Memory: \(used). Pressure: \(snapshot.memoryPressureLevel.displayName), \(pressure) pressure, \(free). Click to open Activity Monitor Memory."
    }

    private func metricTooltip(name: String, percent: Double?, destination: String) -> String {
        "\(name): \(percentString(percent)). Click to open \(destination)."
    }

    private func metricSeverity(
        percent: Double?,
        pressureLevel: MemoryPressureLevel? = nil
    ) -> SystemResourceMetricSeverity {
        if pressureLevel == .critical {
            return .critical
        }

        if pressureLevel == .warning {
            return .warning
        }

        guard let percent else {
            return .unknown
        }

        if percent >= 90 {
            return .critical
        }

        if percent >= 75 {
            return .warning
        }

        return .normal
    }

    private static func memoryAmountString(_ bytes: UInt64, includesUnit: Bool) -> String {
        let gibibytes = Double(bytes) / 1_073_741_824
        let suffix = includesUnit ? "G" : ""
        if gibibytes >= 10 {
            return "\(Int(gibibytes.rounded()))\(suffix)"
        }

        return String(format: "%.1f%@", gibibytes, suffix)
    }

    @objc
    private func collapseWidget(_ sender: Any?) {
        settings.systemResourceWidgetCollapsed = true
    }

    @objc
    private func pinWidgetToThisDisplay(_ sender: Any?) {
        settings.systemResourceWidgetPinnedDisplayID = displayID
    }

    @objc
    private func showWidgetOnAllDisplays(_ sender: Any?) {
        settings.systemResourceWidgetPinnedDisplayID = nil
    }

    @objc
    private func hideWidget(_ sender: Any?) {
        settings.showSystemResourceWidget = false
    }

    @objc
    private func openMemoryMonitor(_ sender: Any?) {
        ActivityMonitorLauncher.open(.memory)
    }

    @objc
    private func openCPUMonitor(_ sender: Any?) {
        ActivityMonitorLauncher.open(.cpu)
    }

    @objc
    private func openGPUMonitor(_ sender: Any?) {
        ActivityMonitorLauncher.open(.gpu)
    }
}

final class CollapsedSystemResourceWidgetView: NSView {
    private let settings: TaskbarSettings
    private let monitor: SystemResourceMonitor
    private let displayID: CGDirectDisplayID
    private let button = NSButton()
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: TaskbarSettings,
        monitor: SystemResourceMonitor,
        displayID: CGDirectDisplayID
    ) {
        self.settings = settings
        self.monitor = monitor
        self.displayID = displayID
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        configureButton()
        bindState()
        updateTooltip(with: monitor.snapshot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: 24)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    private func configureButton() {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(expandWidget(_:))

        if let image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "System resource widget") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = "SYS"
            button.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        }

        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func bindState() {
        monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateTooltip(with: snapshot)
            }
            .store(in: &cancellables)
    }

    private func updateTooltip(with snapshot: SystemResourceSnapshot) {
        var parts: [String] = []
        if settings.showSystemResourceMemoryMetric {
            parts.append("MEM \(percentString(snapshot.memoryUsedPercent))")
        }
        if settings.showSystemResourceCPUMetric {
            parts.append("CPU \(percentString(snapshot.cpuPercent))")
        }
        if settings.showSystemResourceGPUMetric {
            parts.append("GPU \(percentString(snapshot.gpuPercent))")
        }

        button.toolTip = "System resources: \(parts.joined(separator: "  "))"
        toolTip = button.toolTip
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let expandItem = NSMenuItem(title: "Expand Widget", action: #selector(expandWidget(_:)), keyEquivalent: "")
        expandItem.target = self
        menu.addItem(expandItem)

        menu.addItem(.separator())

        let pinItem = NSMenuItem(
            title: "Pin to \(displayName)",
            action: #selector(pinWidgetToThisDisplay(_:)),
            keyEquivalent: ""
        )
        pinItem.target = self
        pinItem.isEnabled = settings.systemResourceWidgetPinnedDisplayID != displayID
        menu.addItem(pinItem)

        let allDisplaysItem = NSMenuItem(
            title: "Show on All Displays",
            action: #selector(showWidgetOnAllDisplays(_:)),
            keyEquivalent: ""
        )
        allDisplaysItem.target = self
        allDisplaysItem.isEnabled = settings.systemResourceWidgetPinnedDisplayID != nil
        menu.addItem(allDisplaysItem)

        menu.addItem(.separator())

        let hideItem = NSMenuItem(title: "Hide System Resource Widget", action: #selector(hideWidget(_:)), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        return menu
    }

    private var displayName: String {
        ScreenGeometry.screen(for: displayID)?.localizedName ?? "This Display"
    }

    private func percentString(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        return "\(Int(value.rounded()))%"
    }

    @objc
    private func expandWidget(_ sender: Any?) {
        settings.systemResourceWidgetCollapsed = false
    }

    @objc
    private func pinWidgetToThisDisplay(_ sender: Any?) {
        settings.systemResourceWidgetPinnedDisplayID = displayID
    }

    @objc
    private func showWidgetOnAllDisplays(_ sender: Any?) {
        settings.systemResourceWidgetPinnedDisplayID = nil
    }

    @objc
    private func hideWidget(_ sender: Any?) {
        settings.showSystemResourceWidget = false
    }
}

private enum SystemResourceMetricSeverity {
    case normal
    case warning
    case critical
    case unknown
}

private final class SystemResourceMetricControl: NSControl {
    private let metric: SystemResourceMetric
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let trackView = NSView()
    private let fillView = NSView()
    private var fillWidthConstraint: NSLayoutConstraint?
    private var fraction: Double?
    private var fillColor = NSColor.controlAccentColor

    init(metric: SystemResourceMetric) {
        self.metric = metric
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: metric == .memory ? 170 : 125, height: 32)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        updateFillWidth()
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    func update(value: String, fraction: Double?, detail: String, severity: SystemResourceMetricSeverity) {
        valueLabel.stringValue = value
        self.fraction = fraction.map { min(max($0, 0), 1) }
        toolTip = detail
        updateColors(severity: severity)
        updateFillWidth()
    }

    private func configureSubviews() {
        titleLabel.stringValue = metric.shortTitle
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        trackView.wantsLayer = true
        trackView.layer?.cornerRadius = 4
        trackView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        trackView.translatesAutoresizingMaskIntoConstraints = false

        fillView.wantsLayer = true
        fillView.layer?.cornerRadius = 4
        fillView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(trackView)
        trackView.addSubview(fillView)

        let fillWidthConstraint = fillView.widthAnchor.constraint(equalToConstant: 0)
        self.fillWidthConstraint = fillWidthConstraint

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 28),

            trackView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            trackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            trackView.widthAnchor.constraint(equalToConstant: metric == .memory ? 76 : 54),
            trackView.heightAnchor.constraint(equalToConstant: 10),

            valueLabel.leadingAnchor.constraint(equalTo: trackView.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            fillView.leadingAnchor.constraint(equalTo: trackView.leadingAnchor),
            fillView.topAnchor.constraint(equalTo: trackView.topAnchor),
            fillView.bottomAnchor.constraint(equalTo: trackView.bottomAnchor),
            fillWidthConstraint
        ])
    }

    private func updateColors(severity: SystemResourceMetricSeverity) {
        switch severity {
        case .normal:
            fillColor = metric == .memory ? .systemGreen : .controlAccentColor
        case .warning:
            fillColor = .systemYellow
        case .critical:
            fillColor = .systemRed
        case .unknown:
            fillColor = .separatorColor
        }

        fillView.layer?.backgroundColor = fillColor.cgColor
        layer?.shadowColor = fillColor.cgColor
        layer?.shadowOpacity = severity == .critical ? 0.35 : 0
        layer?.shadowRadius = severity == .critical ? 5 : 0
        layer?.shadowOffset = .zero
    }

    private func updateFillWidth() {
        guard let fillWidthConstraint else {
            return
        }

        let nextWidth = trackView.bounds.width * CGFloat(fraction ?? 0)
        if abs(fillWidthConstraint.constant - nextWidth) > 0.5 {
            fillWidthConstraint.constant = nextWidth
        }
    }
}

private extension SystemResourceMetric {
    var shortTitle: String {
        switch self {
        case .memory:
            return "MEM"
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        }
    }
}
