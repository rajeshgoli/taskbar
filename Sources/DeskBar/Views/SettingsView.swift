import AppKit
import Combine

final class SettingsView: NSView {
    private struct AppEntry {
        let displayName: String
        let bundleIdentifier: String
        let icon: NSImage?
    }

    private enum LauncherColumn {
        static let icon = NSUserInterfaceItemIdentifier("icon")
        static let name = NSUserInterfaceItemIdentifier("name")
        static let bundleIdentifier = NSUserInterfaceItemIdentifier("bundleIdentifier")
    }

    private enum BlacklistColumn {
        static let app = NSUserInterfaceItemIdentifier("blacklistApp")
        static let bundleIdentifier = NSUserInterfaceItemIdentifier("blacklistBundleIdentifier")
    }

    private static let launcherPasteboardType = NSPasteboard.PasteboardType("com.deskbar.pinned-app-row")

    private let settings: TaskbarSettings
    private let pinnedAppManager: PinnedAppManager
    private let blacklistManager: BlacklistManager
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
    private let groupingModePopupButton = NSPopUpButton()
    private let dragReorderCheckbox = NSButton(checkboxWithTitle: "Drag reorder", target: nil, action: nil)
    private let middleClickClosesCheckbox = NSButton(checkboxWithTitle: "Middle-click closes", target: nil, action: nil)
    private let showOverFullscreenAppsCheckbox = NSButton(checkboxWithTitle: "Show over full-screen apps", target: nil, action: nil)
    private let showOnAllMonitorsCheckbox = NSButton(checkboxWithTitle: "Show on all monitors", target: nil, action: nil)
    private let flashAttentionIndicatorsCheckbox = NSButton(checkboxWithTitle: "Flash apps that want attention", target: nil, action: nil)
    private let showProgressIndicatorsCheckbox = NSButton(checkboxWithTitle: "Show app progress indicators", target: nil, action: nil)
    private let enableActivityModeCheckbox = NSButton(checkboxWithTitle: "Activity mode (hold Control for CPU/RAM)", target: nil, action: nil)

    private let launcherTableView = NSTableView()
    private let launcherScrollView = NSScrollView()
    private let removePinnedAppButton = NSButton(title: "Remove", target: nil, action: nil)
    private let blacklistTableView = NSTableView()
    private let blacklistScrollView = NSScrollView()
    private let removeBlacklistButton = NSButton(title: "Remove", target: nil, action: nil)
    private let addBlacklistButton = NSButton(title: "Add...", target: nil, action: nil)

    private var blacklistEntries: [AppEntry] = []
    private var addSheetEntries: [AppEntry] = []
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: TaskbarSettings,
        pinnedAppManager: PinnedAppManager = PinnedAppManager(),
        blacklistManager: BlacklistManager
    ) {
        self.settings = settings
        self.pinnedAppManager = pinnedAppManager
        self.blacklistManager = blacklistManager
        super.init(frame: .zero)

        configureLayout()
        configureActions()
        bindSettings()
        bindPinnedApps()
        bindBlacklist()
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
        configureLauncherTableView()
        configureBlacklistTableView()

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

        groupingModePopupButton.addItems(withTitles: ["Never", "Automatic", "Always"])

        let behaviorTab = NSTabViewItem(identifier: "behavior")
        behaviorTab.label = "Behavior"
        behaviorTab.view = makeFormView(rows: [
            makeLabeledControlRow(label: "Hover delay", control: hoverDelaySlider),
            makeLabeledControlRow(label: "Window grouping", control: groupingModePopupButton),
            makeCheckboxRow(dragReorderCheckbox),
            makeCheckboxRow(middleClickClosesCheckbox),
            makeCheckboxRow(flashAttentionIndicatorsCheckbox),
            makeCheckboxRow(showProgressIndicatorsCheckbox),
            makeCheckboxRow(enableActivityModeCheckbox),
            makeCheckboxRow(showOverFullscreenAppsCheckbox),
            makeCheckboxRow(showOnAllMonitorsCheckbox)
        ])

        let launcherTab = NSTabViewItem(identifier: "launcher")
        launcherTab.label = "Launcher"
        launcherTab.view = makeLauncherView()

        let blacklistTab = NSTabViewItem(identifier: "blacklist")
        blacklistTab.label = "Blacklist"
        blacklistTab.view = makeBlacklistView()

        [generalTab, appearanceTab, behaviorTab, launcherTab, blacklistTab].forEach(tabView.addTabViewItem)
    }

    private func configureLauncherTableView() {
        let iconColumn = NSTableColumn(identifier: LauncherColumn.icon)
        iconColumn.title = ""
        iconColumn.width = 44
        iconColumn.minWidth = 44
        iconColumn.maxWidth = 44

        let nameColumn = NSTableColumn(identifier: LauncherColumn.name)
        nameColumn.title = "Name"
        nameColumn.width = 180

        let bundleIdentifierColumn = NSTableColumn(identifier: LauncherColumn.bundleIdentifier)
        bundleIdentifierColumn.title = "Bundle ID"
        bundleIdentifierColumn.width = 280

        launcherTableView.addTableColumn(iconColumn)
        launcherTableView.addTableColumn(nameColumn)
        launcherTableView.addTableColumn(bundleIdentifierColumn)
        launcherTableView.headerView = NSTableHeaderView()
        launcherTableView.usesAlternatingRowBackgroundColors = true
        launcherTableView.allowsMultipleSelection = false
        launcherTableView.allowsEmptySelection = true
        launcherTableView.rowHeight = 36
        launcherTableView.delegate = self
        launcherTableView.dataSource = self
        launcherTableView.registerForDraggedTypes([Self.launcherPasteboardType])
        launcherTableView.setDraggingSourceOperationMask(.move, forLocal: true)
        launcherTableView.draggingDestinationFeedbackStyle = .gap

        launcherScrollView.translatesAutoresizingMaskIntoConstraints = false
        launcherScrollView.borderType = .bezelBorder
        launcherScrollView.hasVerticalScroller = true
        launcherScrollView.documentView = launcherTableView
    }

    private func configureBlacklistTableView() {
        let appColumn = NSTableColumn(identifier: BlacklistColumn.app)
        appColumn.title = "App"
        appColumn.width = 240

        let bundleIdentifierColumn = NSTableColumn(identifier: BlacklistColumn.bundleIdentifier)
        bundleIdentifierColumn.title = "Bundle ID"
        bundleIdentifierColumn.width = 300

        blacklistTableView.addTableColumn(appColumn)
        blacklistTableView.addTableColumn(bundleIdentifierColumn)
        blacklistTableView.headerView = NSTableHeaderView()
        blacklistTableView.usesAlternatingRowBackgroundColors = true
        blacklistTableView.allowsMultipleSelection = false
        blacklistTableView.allowsEmptySelection = true
        blacklistTableView.rowHeight = 36
        blacklistTableView.delegate = self
        blacklistTableView.dataSource = self

        blacklistScrollView.translatesAutoresizingMaskIntoConstraints = false
        blacklistScrollView.borderType = .bezelBorder
        blacklistScrollView.hasVerticalScroller = true
        blacklistScrollView.documentView = blacklistTableView
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

        groupingModePopupButton.target = self
        groupingModePopupButton.action = #selector(groupingModeChanged(_:))

        dragReorderCheckbox.target = self
        dragReorderCheckbox.action = #selector(dragReorderChanged(_:))

        middleClickClosesCheckbox.target = self
        middleClickClosesCheckbox.action = #selector(middleClickClosesChanged(_:))

        showOverFullscreenAppsCheckbox.target = self
        showOverFullscreenAppsCheckbox.action = #selector(showOverFullscreenAppsChanged(_:))

        showOnAllMonitorsCheckbox.target = self
        showOnAllMonitorsCheckbox.action = #selector(showOnAllMonitorsChanged(_:))

        flashAttentionIndicatorsCheckbox.target = self
        flashAttentionIndicatorsCheckbox.action = #selector(flashAttentionIndicatorsChanged(_:))

        showProgressIndicatorsCheckbox.target = self
        showProgressIndicatorsCheckbox.action = #selector(showProgressIndicatorsChanged(_:))

        enableActivityModeCheckbox.target = self
        enableActivityModeCheckbox.action = #selector(enableActivityModeChanged(_:))

        removePinnedAppButton.target = self
        removePinnedAppButton.action = #selector(removePinnedApp(_:))

        removeBlacklistButton.target = self
        removeBlacklistButton.action = #selector(removeBlacklistEntry(_:))

        addBlacklistButton.target = self
        addBlacklistButton.action = #selector(showAddBlacklistSheet(_:))
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

        settings.$groupingMode
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                let index: Int
                switch value {
                case .never:
                    index = 0
                case .automatic:
                    index = 1
                case .always:
                    index = 2
                }

                self?.groupingModePopupButton.selectItem(at: index)
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

        settings.$flashAttentionIndicators
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.flashAttentionIndicatorsCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)

        settings.$showProgressIndicators
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.showProgressIndicatorsCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)

        settings.$enableActivityMode
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.enableActivityModeCheckbox.state = value ? .on : .off
            }
            .store(in: &cancellables)
    }

    private func bindPinnedApps() {
        pinnedAppManager.$pinnedApps
            .receive(on: RunLoop.main)
            .sink { [weak self] pinnedApps in
                guard let self else {
                    return
                }

                let selectedBundleIdentifier = selectedPinnedApp?.bundleIdentifier
                launcherTableView.reloadData()

                if let selectedBundleIdentifier,
                   let selectedRow = pinnedApps.firstIndex(where: { $0.bundleIdentifier == selectedBundleIdentifier }) {
                    launcherTableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                }

                updateRemoveButtonState()
            }
            .store(in: &cancellables)
    }

    private func bindBlacklist() {
        blacklistManager.$blacklistedBundleIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadBlacklistEntries()
            }
            .store(in: &cancellables)

        reloadBlacklistEntries()
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

    private func makeLauncherView() -> NSView {
        let container = NSView()
        let buttonRow = NSStackView(views: [removePinnedAppButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .gravityAreas
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        removePinnedAppButton.isEnabled = false

        container.addSubview(launcherScrollView)
        container.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            launcherScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            launcherScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            launcherScrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            launcherScrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            launcherScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),

            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20)
        ])

        return container
    }

    private func makeBlacklistView() -> NSView {
        let container = NSView()
        let descriptionLabel = NSTextField(labelWithString: "Hidden apps are excluded from the taskbar.")
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(removeBlacklistButton)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buttonRow.addArrangedSubview(addBlacklistButton)

        removeBlacklistButton.isEnabled = false

        container.addSubview(descriptionLabel)
        container.addSubview(blacklistScrollView)
        container.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            descriptionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            descriptionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            descriptionLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),

            blacklistScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            blacklistScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            blacklistScrollView.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 12),
            blacklistScrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            blacklistScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),

            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20)
        ])

        return container
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

    private func makeImageCell(identifier: NSUserInterfaceItemIdentifier, image: NSImage?) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = image
        imageView.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20),
            imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier, text: String) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: text)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func makeAppCell(identifier: NSUserInterfaceItemIdentifier, entry: AppEntry) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = entry.icon
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: entry.displayName)
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private var selectedPinnedApp: PinnedApp? {
        let selectedRow = launcherTableView.selectedRow
        guard pinnedAppManager.pinnedApps.indices.contains(selectedRow) else {
            return nil
        }

        return pinnedAppManager.pinnedApps[selectedRow]
    }

    private func updateRemoveButtonState() {
        removePinnedAppButton.isEnabled = selectedPinnedApp != nil
    }

    private func updateBlacklistButtonState() {
        let selectedRow = blacklistTableView.selectedRow
        removeBlacklistButton.isEnabled = blacklistEntries.indices.contains(selectedRow)
    }

    private func reloadBlacklistEntries() {
        blacklistEntries = blacklistManager.blacklistedBundleIDs
            .map(resolveAppEntry(bundleIdentifier:))
            .sorted { lhs, rhs in
                let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

                return lhs.bundleIdentifier.localizedCaseInsensitiveCompare(rhs.bundleIdentifier) == .orderedAscending
            }

        blacklistTableView.reloadData()

        if blacklistEntries.isEmpty {
            blacklistTableView.deselectAll(nil)
        } else if !blacklistEntries.indices.contains(blacklistTableView.selectedRow) {
            blacklistTableView.selectRowIndexes(IndexSet(integer: blacklistEntries.count - 1), byExtendingSelection: false)
        }

        updateBlacklistButtonState()
    }

    private func resolveAppEntry(bundleIdentifier: String) -> AppEntry {
        if let application = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return AppEntry(
                displayName: application.localizedName ?? bundleIdentifier,
                bundleIdentifier: bundleIdentifier,
                icon: application.icon
            )
        }

        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let bundle = Bundle(url: applicationURL)
            let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String)
                ?? FileManager.default.displayName(atPath: applicationURL.path)

            return AppEntry(
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                icon: NSWorkspace.shared.icon(forFile: applicationURL.path)
            )
        }

        return AppEntry(
            displayName: bundleIdentifier,
            bundleIdentifier: bundleIdentifier,
            icon: nil
        )
    }

    private func runningAppEntries() -> [AppEntry] {
        let applicationsByBundleIdentifier = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { application -> (String, NSRunningApplication)? in
                    guard let bundleIdentifier = application.bundleIdentifier else {
                        return nil
                    }

                    return (bundleIdentifier, application)
                },
            uniquingKeysWith: { existing, _ in existing }
        )

        return applicationsByBundleIdentifier.values
            .filter { application in
                guard let bundleIdentifier = application.bundleIdentifier else {
                    return false
                }

                return !blacklistManager.isBlacklisted(bundleIdentifier: bundleIdentifier)
            }
            .map { application in
                AppEntry(
                    displayName: application.localizedName ?? application.bundleIdentifier ?? "",
                    bundleIdentifier: application.bundleIdentifier ?? "",
                    icon: application.icon
                )
            }
            .sorted { lhs, rhs in
                let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

                return lhs.bundleIdentifier.localizedCaseInsensitiveCompare(rhs.bundleIdentifier) == .orderedAscending
            }
    }

    private func showRunningAppsSelection(entries: [AppEntry]) {
        let alert = NSAlert()
        alert.messageText = "Add App to Blacklist"
        alert.informativeText = "Select a currently running app to hide from the taskbar."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.identifier = NSUserInterfaceItemIdentifier("runningAppsTable")
        tableView.rowHeight = 36
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = false

        let appColumn = NSTableColumn(identifier: BlacklistColumn.app)
        appColumn.title = "App"
        appColumn.width = 220

        let bundleIdentifierColumn = NSTableColumn(identifier: BlacklistColumn.bundleIdentifier)
        bundleIdentifierColumn.title = "Bundle ID"
        bundleIdentifierColumn.width = 250

        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(bundleIdentifierColumn)

        addSheetEntries = entries

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 220))
        accessoryView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: accessoryView.bottomAnchor)
        ])

        alert.accessoryView = accessoryView
        tableView.reloadData()
        if !entries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        if alert.runModal() == .alertFirstButtonReturn, entries.indices.contains(tableView.selectedRow) {
            blacklistManager.add(bundleIdentifier: entries[tableView.selectedRow].bundleIdentifier)
        }
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
    private func groupingModeChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 2:
            settings.groupingMode = .always
        case 1:
            settings.groupingMode = .automatic
        default:
            settings.groupingMode = .never
        }
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

    @objc
    private func flashAttentionIndicatorsChanged(_ sender: NSButton) {
        settings.flashAttentionIndicators = sender.state == .on
    }

    @objc
    private func showProgressIndicatorsChanged(_ sender: NSButton) {
        settings.showProgressIndicators = sender.state == .on
    }

    @objc
    private func enableActivityModeChanged(_ sender: NSButton) {
        settings.enableActivityMode = sender.state == .on
    }

    @objc
    private func removePinnedApp(_ sender: NSButton) {
        guard let pinnedApp = selectedPinnedApp else {
            return
        }

        pinnedAppManager.unpin(bundleIdentifier: pinnedApp.bundleIdentifier)
    }

    @objc
    private func removeBlacklistEntry(_ sender: NSButton) {
        let selectedRow = blacklistTableView.selectedRow
        guard blacklistEntries.indices.contains(selectedRow) else {
            return
        }

        blacklistManager.remove(bundleIdentifier: blacklistEntries[selectedRow].bundleIdentifier)
    }

    @objc
    private func showAddBlacklistSheet(_ sender: NSButton) {
        let entries = runningAppEntries()
        guard !entries.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Running Apps"
            alert.informativeText = "There are no currently running apps available to blacklist."
            alert.runModal()
            return
        }

        showRunningAppsSelection(entries: entries)
    }
}

extension SettingsView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === launcherTableView {
            return pinnedAppManager.pinnedApps.count
        }

        if tableView === blacklistTableView || tableView.identifier?.rawValue == "runningAppsTable" {
            return tableView === blacklistTableView ? blacklistEntries.count : addSheetEntries.count
        }

        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else {
            return nil
        }

        if tableView === launcherTableView {
            guard pinnedAppManager.pinnedApps.indices.contains(row) else {
                return nil
            }

            let pinnedApp = pinnedAppManager.pinnedApps[row]

            switch tableColumn.identifier {
            case LauncherColumn.icon:
                return makeImageCell(identifier: LauncherColumn.icon, image: pinnedApp.icon)
            case LauncherColumn.name:
                return makeTextCell(identifier: LauncherColumn.name, text: pinnedApp.name)
            case LauncherColumn.bundleIdentifier:
                return makeTextCell(identifier: LauncherColumn.bundleIdentifier, text: pinnedApp.bundleIdentifier)
            default:
                return nil
            }
        }

        let entries = tableView === blacklistTableView ? blacklistEntries : addSheetEntries
        guard entries.indices.contains(row) else {
            return nil
        }

        let entry = entries[row]

        switch tableColumn.identifier {
        case BlacklistColumn.app:
            return makeAppCell(identifier: BlacklistColumn.app, entry: entry)
        case BlacklistColumn.bundleIdentifier:
            return makeTextCell(identifier: BlacklistColumn.bundleIdentifier, text: entry.bundleIdentifier)
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else {
            return
        }

        if tableView === launcherTableView {
            updateRemoveButtonState()
            return
        }

        if tableView === blacklistTableView {
            updateBlacklistButtonState()
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === launcherTableView else {
            return nil
        }

        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.launcherPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard tableView === launcherTableView else {
            return []
        }

        guard info.draggingSource as AnyObject? === tableView else {
            return []
        }

        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard tableView === launcherTableView else {
            return false
        }

        guard let pasteboardItem = info.draggingPasteboard.pasteboardItems?.first,
              let sourceRowString = pasteboardItem.string(forType: Self.launcherPasteboardType),
              let sourceRow = Int(sourceRowString) else {
            return false
        }

        let destinationRow = sourceRow < row ? row - 1 : row
        pinnedAppManager.reorder(from: sourceRow, to: destinationRow)

        let selectedRow = min(max(destinationRow, 0), max(pinnedAppManager.pinnedApps.count - 1, 0))
        if pinnedAppManager.pinnedApps.indices.contains(selectedRow) {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }

        return true
    }
}
