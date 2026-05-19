import AppKit
import ApplicationServices
import Combine

enum WindowSwitcherActivationAction: Equatable {
    case raiseAXWindow
    case activateApplication
    case none
}

final class WindowSwitcherService {
    private static let tabKeyCode: CGKeyCode = 48
    private static let spaceKeyCode: CGKeyCode = 49
    private static let escapeKeyCode: CGKeyCode = 53
    static let eventTypesOfInterest: [CGEventType] = [
        .keyDown,
        .keyUp,
        .flagsChanged,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .scrollWheel
    ]
    static let pointerInteractionEventTypes: Set<CGEventType> = [
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .scrollWheel
    ]
    private static var eventMask: CGEventMask {
        eventTypesOfInterest.reduce(CGEventMask(0)) { mask, eventType in
            mask | CGEventMask(1 << eventType.rawValue)
        }
    }

    private let windowManager: WindowManager
    private let settings: TaskbarSettings
    private let accessibilityService: AccessibilityService
    private let thumbnailService: ThumbnailService
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var overlayPanels: [CGDirectDisplayID: WindowSwitcherPanel] = [:]
    private var sessionWindows: [WindowInfo] = []
    private var selectedIndex: Int?
    private var thumbnailProvider: WindowSwitcherThumbnailProvider?
    private var bareCommandDetector = BareCommandShortcutDetector()
    private var isAccessibilityGranted = false
    private var cancellables = Set<AnyCancellable>()

    init(
        windowManager: WindowManager,
        settings: TaskbarSettings,
        thumbnailService: ThumbnailService,
        accessibilityService: AccessibilityService = AccessibilityService()
    ) {
        self.windowManager = windowManager
        self.settings = settings
        self.thumbnailService = thumbnailService
        self.accessibilityService = accessibilityService
        bindSettings()
        updateForAccessibilityPermissionChange(isGranted: AXIsProcessTrusted())
    }

    deinit {
        stop()
    }

    func updateForAccessibilityPermissionChange(isGranted: Bool) {
        isAccessibilityGranted = isGranted
        reconcileEventTap()
    }

    static func shouldInstallEventTap(
        isAccessibilityGranted: Bool,
        enableWindowSwitcher: Bool,
        enableBareCommandLauncher: Bool
    ) -> Bool {
        isAccessibilityGranted && (enableWindowSwitcher || enableBareCommandLauncher)
    }

    static func matchesAppsLauncherShortcut(
        shortcut: AppsLauncherShortcut,
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> Bool {
        guard type == .keyDown else {
            return false
        }

        switch shortcut {
        case .commandTap:
            return false
        case .controlOptionSpace:
            return keyCode == spaceKeyCode &&
                flags.contains(.maskControl) &&
                flags.contains(.maskAlternate) &&
                !flags.contains(.maskCommand) &&
                !flags.contains(.maskShift)
        case .optionSpace:
            return keyCode == spaceKeyCode &&
                flags.contains(.maskAlternate) &&
                !flags.contains(.maskCommand) &&
                !flags.contains(.maskControl) &&
                !flags.contains(.maskShift)
        }
    }

    static func switchableWindows(
        from windows: [WindowInfo],
        zOrderedWindowIDs: [CGWindowID]
    ) -> [WindowInfo] {
        let candidates = windows.filter {
            $0.cgWindowID != nil && !$0.isMinimized && !$0.isHidden
        }
        let windowsByCGID = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { window -> (CGWindowID, WindowInfo)? in
                guard let cgWindowID = window.cgWindowID else {
                    return nil
                }

                return (cgWindowID, window)
            }
        )
        var orderedWindows: [WindowInfo] = []
        var seenIDs = Set<String>()

        for windowID in zOrderedWindowIDs {
            guard let window = windowsByCGID[windowID],
                  seenIDs.insert(window.id).inserted else {
                continue
            }

            orderedWindows.append(window)
        }

        for window in candidates where seenIDs.insert(window.id).inserted {
            orderedWindows.append(window)
        }

        return orderedWindows
    }

    static func nextSelectionIndex(
        candidateIDs: [String],
        currentWindowID: String?,
        sessionIndex: Int?,
        reverse: Bool
    ) -> Int? {
        guard !candidateIDs.isEmpty else {
            return nil
        }

        let step = reverse ? -1 : 1

        if let sessionIndex,
           candidateIDs.indices.contains(sessionIndex) {
            return (sessionIndex + step + candidateIDs.count) % candidateIDs.count
        }

        guard let currentWindowID,
              let currentIndex = candidateIDs.firstIndex(of: currentWindowID) else {
            return reverse ? candidateIDs.count - 1 : 0
        }

        return (currentIndex + step + candidateIDs.count) % candidateIDs.count
    }

    static func activationAction(
        applicationIsRunning: Bool,
        hasMatchedAXWindow: Bool
    ) -> WindowSwitcherActivationAction {
        guard applicationIsRunning else {
            return .none
        }

        return hasMatchedAXWindow ? .raiseAXWindow : .activateApplication
    }

    private func start() {
        guard eventTap == nil else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: Self.eventTapCallback,
            userInfo: context
        ) else {
            print("DeskBar: unable to install Option-Tab window switcher event tap.")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func bindSettings() {
        settings.$enableWindowSwitcher
            .combineLatest(settings.$enableBareCommandLauncher)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enableWindowSwitcher, enableBareCommandLauncher in
                guard let self else {
                    return
                }

                if !enableWindowSwitcher {
                    Task { @MainActor [weak self] in
                        self?.endSession(commitSelection: false)
                    }
                }

                if !enableBareCommandLauncher {
                    self.bareCommandDetector.cancel()
                }

                self.reconcileEventTap()
            }
            .store(in: &cancellables)

        settings.$appsLauncherShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] shortcut in
                guard let self else {
                    return
                }

                if shortcut != .commandTap {
                    self.bareCommandDetector.cancel()
                }
            }
            .store(in: &cancellables)
    }

    private func reconcileEventTap() {
        if Self.shouldInstallEventTap(
            isAccessibilityGranted: isAccessibilityGranted,
            enableWindowSwitcher: settings.enableWindowSwitcher,
            enableBareCommandLauncher: settings.enableBareCommandLauncher
        ) {
            start()
        } else {
            stop()
        }
    }

    private func stop() {
        runOnMainActorSynchronously {
            self.endSession(commitSelection: false)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }

        runLoopSource = nil
        eventTap = nil
    }

    private func runOnMainActorSynchronously(_ operation: @MainActor @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                operation()
            }
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                operation()
            }
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let service = Unmanaged<WindowSwitcherService>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return service.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags

        if Self.pointerInteractionEventTypes.contains(type) {
            bareCommandDetector.cancel()
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            if settings.enableBareCommandLauncher,
               settings.appsLauncherShortcut == .commandTap,
               bareCommandDetector.handleFlagsChanged(flags) {
                DispatchQueue.main.async {
                    AppsLauncher.open()
                }
            } else if !settings.enableBareCommandLauncher || settings.appsLauncherShortcut != .commandTap {
                bareCommandDetector.cancel()
            }

            if !flags.contains(.maskAlternate) {
                Task { @MainActor [weak self] in
                    self?.endSession(commitSelection: true)
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == Self.escapeKeyCode, !sessionWindows.isEmpty {
            if type == .keyDown {
                bareCommandDetector.handleKeyDown()
                Task { @MainActor [weak self] in
                    self?.endSession(commitSelection: false)
                }
            }

            return nil
        }

        if type == .keyDown {
            bareCommandDetector.handleKeyDown()
        }

        if settings.enableBareCommandLauncher,
           Self.matchesAppsLauncherShortcut(
               shortcut: settings.appsLauncherShortcut,
               type: type,
               keyCode: keyCode,
               flags: flags
           ) {
            DispatchQueue.main.async {
                AppsLauncher.open()
            }
            return nil
        }

        guard keyCode == Self.tabKeyCode,
              settings.enableWindowSwitcher,
              flags.contains(.maskAlternate),
              !flags.contains(.maskCommand),
              !flags.contains(.maskControl) else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let reverse = flags.contains(.maskShift)
            Task { @MainActor [weak self] in
                self?.cycleWindow(reverse: reverse)
            }
        }

        return nil
    }

    @MainActor
    private func cycleWindow(reverse: Bool) {
        guard AXIsProcessTrusted() else {
            return
        }

        if sessionWindows.isEmpty {
            windowManager.refresh()
            sessionWindows = Self.switchableWindows(
                from: windowManager.windows,
                zOrderedWindowIDs: Self.zOrderedWindowIDs()
            )
            selectedIndex = nil
            thumbnailProvider = WindowSwitcherThumbnailProvider(thumbnailService: thumbnailService)
        }

        let candidateIDs = sessionWindows.map(\.id)
        let currentWindowID = sessionWindows.first?.id

        guard let nextIndex = Self.nextSelectionIndex(
            candidateIDs: candidateIDs,
            currentWindowID: currentWindowID,
            sessionIndex: selectedIndex,
            reverse: reverse
        ) else {
            endSession(commitSelection: false)
            return
        }

        selectedIndex = nextIndex
        showOverlay()
    }

    @MainActor
    private func endSession(commitSelection: Bool) {
        let selectedWindow: WindowInfo?
        if commitSelection,
           let selectedIndex,
           sessionWindows.indices.contains(selectedIndex) {
            selectedWindow = sessionWindows[selectedIndex]
        } else {
            selectedWindow = nil
        }

        closeOverlayPanels()
        thumbnailProvider?.cancel()
        thumbnailProvider = nil
        sessionWindows.removeAll()
        selectedIndex = nil

        if let selectedWindow {
            activate(window: selectedWindow)
        }
    }

    @MainActor
    private func showOverlay() {
        guard let selectedIndex,
              !sessionWindows.isEmpty else {
            return
        }
        let thumbnailProvider = self.thumbnailProvider ?? WindowSwitcherThumbnailProvider(thumbnailService: thumbnailService)
        self.thumbnailProvider = thumbnailProvider

        let items = sessionWindows.map { window in
            WindowSwitcherItem(
                id: window.id,
                cgWindowID: window.cgWindowID,
                appName: window.appName,
                title: window.title.isEmpty ? window.appName : window.title,
                icon: window.icon
            )
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return
        }

        var visibleDisplayIDs = Set<CGDirectDisplayID>()
        for (fallbackIndex, screen) in screens.enumerated() {
            let displayID = ScreenGeometry.displayID(for: screen) ?? CGDirectDisplayID(1_000_000 + fallbackIndex)
            visibleDisplayIDs.insert(displayID)

            let panel = overlayPanels[displayID] ?? WindowSwitcherPanel(screen: screen)
            overlayPanels[displayID] = panel
            panel.update(
                screen: screen,
                items: items,
                selectedIndex: selectedIndex,
                thumbnailProvider: thumbnailProvider
            )
            panel.orderFrontRegardless()
        }

        for displayID in Set(overlayPanels.keys).subtracting(visibleDisplayIDs) {
            overlayPanels.removeValue(forKey: displayID)?.closeSwitcher()
        }
    }

    @MainActor
    private func closeOverlayPanels() {
        overlayPanels.values.forEach { $0.closeSwitcher() }
        overlayPanels.removeAll()
    }

    @MainActor
    private func activate(window: WindowInfo) {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier == window.pid
        }) else {
            return
        }

        let element: AXUIElement?
        if let cgWindowID = window.cgWindowID {
            element = accessibilityService.enumerateWindows(for: application).first(where: {
                accessibilityService.getWindowID(for: $0) == cgWindowID
            })
        } else {
            element = nil
        }

        switch Self.activationAction(
            applicationIsRunning: true,
            hasMatchedAXWindow: element != nil
        ) {
        case .raiseAXWindow:
            guard let element else {
                return
            }
            accessibilityService.raiseAndActivate(element: element, app: application)
        case .activateApplication:
            application.unhide()
            _ = application.activate(options: .activateAllWindows)
        case .none:
            return
        }
    }

    private static func zOrderedWindowIDs() -> [CGWindowID] {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        return windowList.compactMap { entry in
            guard
                let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                let layer = entry[kCGWindowLayer as String] as? Int,
                layer == 0,
                let alpha = entry[kCGWindowAlpha as String] as? Double,
                alpha > 0,
                let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width * bounds.height >= 100
            else {
                return nil
            }

            return windowID
        }
    }

}
