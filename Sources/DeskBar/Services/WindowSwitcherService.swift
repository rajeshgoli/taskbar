import AppKit
import ApplicationServices

enum WindowSwitcherActivationAction: Equatable {
    case raiseAXWindow
    case activateApplication
    case none
}

final class WindowSwitcherService {
    private static let tabKeyCode: CGKeyCode = 48
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
    private let accessibilityService: AccessibilityService
    private let thumbnailService: ThumbnailService
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var overlayPanels: [CGDirectDisplayID: WindowSwitcherPanel] = [:]
    private var sessionWindows: [WindowInfo] = []
    private var selectedIndex: Int?
    private var bareCommandDetector = BareCommandShortcutDetector()

    init(
        windowManager: WindowManager,
        thumbnailService: ThumbnailService,
        accessibilityService: AccessibilityService = AccessibilityService()
    ) {
        self.windowManager = windowManager
        self.thumbnailService = thumbnailService
        self.accessibilityService = accessibilityService
        updateForAccessibilityPermissionChange(isGranted: AXIsProcessTrusted())
    }

    deinit {
        stop()
    }

    func updateForAccessibilityPermissionChange(isGranted: Bool) {
        if isGranted {
            start()
        } else {
            stop()
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

    private func stop() {
        endSession(commitSelection: false)

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }

        runLoopSource = nil
        eventTap = nil
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
            if bareCommandDetector.handleFlagsChanged(flags) {
                DispatchQueue.main.async {
                    AppsLauncher.open()
                }
            }

            if !flags.contains(.maskAlternate) {
                DispatchQueue.main.async { [weak self] in
                    self?.endSession(commitSelection: true)
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == Self.escapeKeyCode, !sessionWindows.isEmpty {
            if type == .keyDown {
                bareCommandDetector.handleKeyDown()
                DispatchQueue.main.async { [weak self] in
                    self?.endSession(commitSelection: false)
                }
            }

            return nil
        }

        if type == .keyDown {
            bareCommandDetector.handleKeyDown()
        }

        guard keyCode == Self.tabKeyCode,
              flags.contains(.maskAlternate),
              !flags.contains(.maskCommand),
              !flags.contains(.maskControl) else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let reverse = flags.contains(.maskShift)
            DispatchQueue.main.async { [weak self] in
                self?.cycleWindow(reverse: reverse)
            }
        }

        return nil
    }

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
        sessionWindows.removeAll()
        selectedIndex = nil

        if let selectedWindow {
            activate(window: selectedWindow)
        }
    }

    private func showOverlay() {
        guard let selectedIndex,
              !sessionWindows.isEmpty else {
            return
        }

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
                thumbnailService: thumbnailService
            )
            panel.orderFrontRegardless()
        }

        for displayID in Set(overlayPanels.keys).subtracting(visibleDisplayIDs) {
            overlayPanels.removeValue(forKey: displayID)?.closeSwitcher()
        }
    }

    private func closeOverlayPanels() {
        overlayPanels.values.forEach { $0.closeSwitcher() }
        overlayPanels.removeAll()
    }

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
