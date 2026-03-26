import AppKit
import Combine

final class SettingsView: NSView {
    private let settings: TaskbarSettings
    private let tabView = NSTabView()

    private let startAtLoginCheckbox = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let showLaunchpadButtonCheckbox = NSButton(checkboxWithTitle: "Show Launchpad button", target: nil, action: nil)
    private let dockModePopupButton = NSPopUpButton()

    private let taskbarHeightSlider = NSSlider(value: 40, minValue: 30, maxValue: 60, target: nil, action: nil)
    private let titleFontSizeSlider = NSSlider(value: 12, minValue: 8, maxValue: 18, target: nil, action: nil)
    private let maxTaskWidthSlider = NSSlider(value: 200, minValue: 100, maxValue: 400, target: nil, action: nil)
    private let showTitlesCheckbox = NSButton(checkboxWithTitle: "Show titles", target: nil, action: nil)
    private let thumbnailSizeSlider = NSSlider(value: 200, minValue: 100, maxValue: 400, target: nil, action: nil)

    private let hoverDelaySlider = NSSlider(value: 400, minValue: 100, maxValue: 1000, target: nil, action: nil)
    private let groupByAppCheckbox = NSButton(checkboxWithTitle: "Group by app", target: nil, action: nil)
    private let dragReorderCheckbox = NSButton(checkboxWithTitle: "Drag reorder", target: nil, action: nil)
    private let middleClickClosesCheckbox = NSButton(checkboxWithTitle: "Middle-click closes", target: nil, action: nil)
    private let showOverFullscreenAppsCheckbox = NSButton(checkboxWithTitle: "Show over full-screen apps", target: nil, action: nil)
    private let showOnAllMonitorsCheckbox = NSButton(checkboxWithTitle: "Show on all monitors", target: nil, action: nil)

    private var cancellables = Set<AnyCancellable>()

    init(settings: TaskbarSettings) {
        self.settings = settings
        super.init(frame: .zero)

        configureLayout()
        configureActions()
        bindSettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureLayout() {
        tabView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            tabView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])

        dockModePopupButton.addItems(withTitles: ["Independent", "Auto-Hide Dock", "Hide Dock"])

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = makeFormView(rows: [
            makeCheckboxRow(startAtLoginCheckbox),
            makeCheckboxRow(showLaunchpadButtonCheckbox),
            makeLabeledControlRow(label: "Dock mode", control: dockModePopupButton)
        ])

        let appearanceTab = NSTabViewItem(identifier: "appearance")
        appearanceTab.label = "Appearance"
        appearanceTab.view = makeFormView(rows: [
            makeLabeledControlRow(label: "Taskbar height", control: taskbarHeightSlider),
            makeLabeledControlRow(label: "Title font size", control: titleFontSizeSlider),
            makeLabeledControlRow(label: "Max task width", control: maxTaskWidthSlider),
            makeCheckboxRow(showTitlesCheckbox),
            makeLabeledControlRow(label: "Thumbnail size", control: thumbnailSizeSlider)
        ])

        let behaviorTab = NSTabViewItem(identifier: "behavior")
        behaviorTab.label = "Behavior"
        behaviorTab.view = makeFormView(rows: [
            makeLabeledControlRow(label: "Hover delay", control: hoverDelaySlider),
            makeCheckboxRow(groupByAppCheckbox),
            makeCheckboxRow(dragReorderCheckbox),
            makeCheckboxRow(middleClickClosesCheckbox),
            makeCheckboxRow(showOverFullscreenAppsCheckbox),
            makeCheckboxRow(showOnAllMonitorsCheckbox)
        ])

        let launcherTab = NSTabViewItem(identifier: "launcher")
        launcherTab.label = "Launcher"
        launcherTab.view = makePlaceholderView(text: "Launcher configuration will appear here")

        let blacklistTab = NSTabViewItem(identifier: "blacklist")
        blacklistTab.label = "Blacklist"
        blacklistTab.view = makePlaceholderView(text: "Blacklist configuration will appear here")

        [generalTab, appearanceTab, behaviorTab, launcherTab, blacklistTab].forEach(tabView.addTabViewItem)
    }

    private func configureActions() {
        startAtLoginCheckbox.target = self
        startAtLoginCheckbox.action = #selector(startAtLoginChanged(_:))

        showLaunchpadButtonCheckbox.target = self
        showLaunchpadButtonCheckbox.action = #selector(showLaunchpadButtonChanged(_:))

        dockModePopupButton.target = self
        dockModePopupButton.action = #selector(dockModeChanged(_:))

        taskbarHeightSlider.target = self
        taskbarHeightSlider.action = #selector(taskbarHeightChanged(_:))

        titleFontSizeSlider.target = self
        titleFontSizeSlider.action = #selector(titleFontSizeChanged(_:))

        maxTaskWidthSlider.target = self
        maxTaskWidthSlider.action = #selector(maxTaskWidthChanged(_:))

        showTitlesCheckbox.target = self
        showTitlesCheckbox.action = #selector(showTitlesChanged(_:))

        thumbnailSizeSlider.target = self
        thumbnailSizeSlider.action = #selector(thumbnailSizeChanged(_:))

        hoverDelaySlider.target = self
        hoverDelaySlider.action = #selector(hoverDelayChanged(_:))

        groupByAppCheckbox.target = self
        groupByAppCheckbox.action = #selector(groupByAppChanged(_:))

        dragReorderCheckbox.target = self
        dragReorderCheckbox.action = #selector(dragReorderChanged(_:))

        middleClickClosesCheckbox.target = self
        middleClickClosesCheckbox.action = #selector(middleClickClosesChanged(_:))

        showOverFullscreenAppsCheckbox.target = self
        showOverFullscreenAppsCheckbox.action = #selector(showOverFullscreenAppsChanged(_:))

        showOnAllMonitorsCheckbox.target = self
        showOnAllMonitorsCheckbox.action = #selector(showOnAllMonitorsChanged(_:))
    }

    private func bindSettings() {
        settings.$startAtLogin
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.startAtLoginCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)

        settings.$showLaunchpadButton
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.showLaunchpadButtonCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)

        settings.$dockMode
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                let index: Int
                switch value {
                case .independent:
                    index = 0
                case .autoHide:
                    index = 1
                case .hidden:
                    index = 2
                }

                self?.dockModePopupButton.selectItem(at: index)
            }
            .store(in: &cancellables)

        settings.$taskbarHeight
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.taskbarHeightSlider.doubleValue = value
            }
            .store(in: &cancellables)

        settings.$titleFontSize
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.titleFontSizeSlider.doubleValue = value
            }
            .store(in: &cancellables)

        settings.$maxTaskWidth
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.maxTaskWidthSlider.doubleValue = value
            }
            .store(in: &cancellables)

        settings.$showTitles
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.showTitlesCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)

        settings.$thumbnailSize
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.thumbnailSizeSlider.doubleValue = value
            }
            .store(in: &cancellables)

        settings.$hoverDelay
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.hoverDelaySlider.doubleValue = value * 1000
            }
            .store(in: &cancellables)

        settings.$groupByApp
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.groupByAppCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)

        settings.$dragReorder
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.dragReorderCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)

        settings.$middleClickCloses
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.middleClickClosesCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)

        settings.$showOverFullScreenApps
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.showOverFullscreenAppsCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)

        settings.$showOnAllMonitors
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.showOnAllMonitorsCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)
    }

    private func makeFormView(rows: [NSView]) -> NSView {
        let container = NSView()
        let stackView = NSStackView(views: rows)
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20)
        ])

        return container
    }

    private func makeCheckboxRow(_ checkbox: NSButton) -> NSView {
        checkbox.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [checkbox])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    private func makeLabeledControlRow(label: String, control: NSControl) -> NSView {
        let textLabel = NSTextField(labelWithString: label)
        textLabel.alignment = .left

        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let row = NSStackView(views: [textLabel, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        textLabel.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return row
    }

    private func makePlaceholderView(text: String) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    @objc
    private func startAtLoginChanged(_ sender: NSButton) {
        settings.startAtLogin = sender.state == .on
    }

    @objc
    private func showLaunchpadButtonChanged(_ sender: NSButton) {
        settings.showLaunchpadButton = sender.state == .on
    }

    @objc
    private func dockModeChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1:
            settings.dockMode = .autoHide
        case 2:
            settings.dockMode = .hidden
        default:
            settings.dockMode = .independent
        }
    }

    @objc
    private func taskbarHeightChanged(_ sender: NSSlider) {
        settings.taskbarHeight = sender.doubleValue
    }

    @objc
    private func titleFontSizeChanged(_ sender: NSSlider) {
        settings.titleFontSize = sender.doubleValue
    }

    @objc
    private func maxTaskWidthChanged(_ sender: NSSlider) {
        settings.maxTaskWidth = sender.doubleValue
    }

    @objc
    private func showTitlesChanged(_ sender: NSButton) {
        settings.showTitles = sender.state == .on
    }

    @objc
    private func thumbnailSizeChanged(_ sender: NSSlider) {
        settings.thumbnailSize = sender.doubleValue
    }

    @objc
    private func hoverDelayChanged(_ sender: NSSlider) {
        settings.hoverDelay = sender.doubleValue / 1000
    }

    @objc
    private func groupByAppChanged(_ sender: NSButton) {
        settings.groupByApp = sender.state == .on
    }

    @objc
    private func dragReorderChanged(_ sender: NSButton) {
        settings.dragReorder = sender.state == .on
    }

    @objc
    private func middleClickClosesChanged(_ sender: NSButton) {
        settings.middleClickCloses = sender.state == .on
    }

    @objc
    private func showOverFullscreenAppsChanged(_ sender: NSButton) {
        settings.showOverFullScreenApps = sender.state == .on
    }

    @objc
    private func showOnAllMonitorsChanged(_ sender: NSButton) {
        settings.showOnAllMonitors = sender.state == .on
    }
}
