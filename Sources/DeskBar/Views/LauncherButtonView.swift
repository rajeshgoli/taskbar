import AppKit
import ApplicationServices

final class LauncherButtonView: NSView {
    private enum State {
        case notRunning
        case runningWithVisibleWindows
        case runningWithoutVisibleWindows
    }

    private let pinnedApp: PinnedApp
    private let visibleLocalWindows: [WindowInfo]
    private let runningApplication: NSRunningApplication?
    private let unpinHandler: () -> Void
    private let accessibilityService: AccessibilityService

    private let iconView = NSImageView()
    private let underlineView = NSView()
    private let dotView = NSView()

    private var state: State {
        if !isRunning {
            return .notRunning
        }

        return visibleLocalWindows.isEmpty ? .runningWithoutVisibleWindows : .runningWithVisibleWindows
    }

    private var isRunning: Bool {
        runningApplication != nil
    }

    init(
        pinnedApp: PinnedApp,
        visibleLocalWindows: [WindowInfo],
        runningApplication: NSRunningApplication?,
        accessibilityService: AccessibilityService = AccessibilityService(),
        unpinHandler: @escaping () -> Void
    ) {
        self.pinnedApp = pinnedApp
        self.visibleLocalWindows = visibleLocalWindows
        self.runningApplication = runningApplication
        self.accessibilityService = accessibilityService
        self.unpinHandler = unpinHandler
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        configureSubviews()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 36, height: 42)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }

        switch state {
        case .notRunning:
            launchApplication()
        case .runningWithVisibleWindows:
            activateMostRecentWindow()
        case .runningWithoutVisibleWindows:
            _ = runningApplication?.activate(options: .activateAllWindows)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func configureSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        underlineView.wantsLayer = true
        underlineView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        underlineView.layer?.cornerRadius = 1.5
        underlineView.translatesAutoresizingMaskIntoConstraints = false

        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dotView.layer?.cornerRadius = 2
        dotView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(underlineView)
        addSubview(dotView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 42),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            underlineView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            underlineView.centerXAnchor.constraint(equalTo: centerXAnchor),
            underlineView.widthAnchor.constraint(equalToConstant: 20),
            underlineView.heightAnchor.constraint(equalToConstant: 3),

            dotView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            dotView.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 4),
            dotView.heightAnchor.constraint(equalToConstant: 4)
        ])
    }

    private func updateAppearance() {
        toolTip = pinnedApp.name
        iconView.image = displayIcon()
        underlineView.isHidden = state != .runningWithVisibleWindows
        dotView.isHidden = state != .runningWithoutVisibleWindows
    }

    private func displayIcon() -> NSImage? {
        let icon = resolvedIcon()

        guard state == .notRunning else {
            return icon
        }

        return icon?.desaturated().withAlpha(0.7)
    }

    private func resolvedIcon() -> NSImage? {
        if let icon = pinnedApp.icon {
            return icon.scaled(to: NSSize(width: 32, height: 32))
        }

        if let icon = runningApplication?.icon {
            return icon.scaled(to: NSSize(width: 32, height: 32))
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pinnedApp.bundleIdentifier) else {
            return nil
        }

        return NSWorkspace.shared.icon(forFile: applicationURL.path).scaled(to: NSSize(width: 32, height: 32))
    }

    private func launchApplication() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pinnedApp.bundleIdentifier) else {
            return
        }

        NSWorkspace.shared.open(applicationURL)
    }

    private func activateMostRecentWindow() {
        guard let runningApplication else {
            return
        }

        let windows = accessibilityService.enumerateWindows(for: runningApplication)
        if let element = preferredWindowElement(
            from: windows,
            application: runningApplication
        ) {
            accessibilityService.raiseAndActivate(element: element, app: runningApplication)
            return
        }

        _ = runningApplication.activate(options: .activateAllWindows)
    }

    private func preferredWindowElement(
        from windows: [AXUIElement],
        application: NSRunningApplication
    ) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let prioritizedAttributes: [CFString] = [
            kAXFocusedWindowAttribute as CFString,
            kAXMainWindowAttribute as CFString
        ]

        for attribute in prioritizedAttributes {
            if let candidate = copyWindowAttribute(from: applicationElement, attribute: attribute),
               matchesVisibleWindow(candidate) {
                return candidate
            }
        }

        for windowInfo in visibleLocalWindows {
            if let element = resolveWindowElement(for: windowInfo, in: windows) {
                return element
            }
        }

        return nil
    }

    private func matchesVisibleWindow(_ element: AXUIElement) -> Bool {
        visibleLocalWindows.contains { windowInfo in
            windowMatches(windowInfo, element: element)
        }
    }

    private func resolveWindowElement(
        for windowInfo: WindowInfo,
        in windows: [AXUIElement]
    ) -> AXUIElement? {
        windows.first { element in
            windowMatches(windowInfo, element: element)
        }
    }

    private func windowMatches(_ windowInfo: WindowInfo, element: AXUIElement) -> Bool {
        if let cgWindowID = windowInfo.cgWindowID,
           accessibilityService.getWindowID(for: element) == cgWindowID {
            return true
        }

        let title = normalizedWindowTitle(windowInfo)
        if !title.isEmpty,
           title == normalizedTitle(for: element) {
            return true
        }

        return false
    }

    private func normalizedWindowTitle(_ windowInfo: WindowInfo) -> String {
        let title = windowInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? windowInfo.appName : title
    }

    private func normalizedTitle(for element: AXUIElement) -> String {
        var value: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
            let title = value as? String
        else {
            return ""
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyWindowAttribute(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if isRunning && !visibleLocalWindows.isEmpty {
            visibleLocalWindows.forEach { windowInfo in
                let item = NSMenuItem(
                    title: normalizedWindowTitle(windowInfo),
                    action: #selector(activateWindowFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = windowInfo
                menu.addItem(item)
            }

            menu.addItem(.separator())
        }

        let unpinItem = NSMenuItem(
            title: "Unpin",
            action: #selector(unpin(_:)),
            keyEquivalent: ""
        )
        unpinItem.target = self
        menu.addItem(unpinItem)

        return menu
    }

    private func showContextMenu(with event: NSEvent) {
        let menu = makeContextMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc
    private func activateWindowFromMenu(_ sender: NSMenuItem) {
        guard
            let runningApplication,
            let windowInfo = sender.representedObject as? WindowInfo
        else {
            return
        }

        let windows = accessibilityService.enumerateWindows(for: runningApplication)
        if let element = resolveWindowElement(for: windowInfo, in: windows) {
            accessibilityService.raiseAndActivate(element: element, app: runningApplication)
            return
        }

        _ = runningApplication.activate(options: .activateAllWindows)
    }

    @objc
    private func unpin(_ sender: Any?) {
        unpinHandler()
    }
}
