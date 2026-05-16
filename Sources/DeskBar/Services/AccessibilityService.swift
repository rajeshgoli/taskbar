import AppKit
import ApplicationServices
import Darwin

final class AccessibilityService {
    typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias GetProcessForPIDFunc = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetFrontProcessWithOptionsFunc = @convention(c) (UnsafePointer<ProcessSerialNumber>, OptionBits) -> OSStatus

    private struct PreservedDisplayWindow {
        let element: AXUIElement
    }

    private let frameMatchTolerance: CGFloat = 2
    private var _axGetWindow: AXUIElementGetWindowFunc?
    private var _getProcessForPID: GetProcessForPIDFunc?
    private var _setFrontProcessWithOptions: SetFrontProcessWithOptionsFunc?
    private var activationRequestID = UUID()
    private var delayedActivationWorkItems: [DispatchWorkItem] = []

    init() {
        let symbolHandle = dlopen(nil, RTLD_LAZY)

        if let sym = dlsym(symbolHandle, "_AXUIElementGetWindow") {
            _axGetWindow = unsafeBitCast(sym, to: AXUIElementGetWindowFunc.self)
        } else {
            print("DeskBar: _AXUIElementGetWindow unavailable, using frame-matching fallback. Thumbnail accuracy may be reduced.")
        }

        if let sym = dlsym(symbolHandle, "GetProcessForPID") {
            _getProcessForPID = unsafeBitCast(sym, to: GetProcessForPIDFunc.self)
        }

        if let sym = dlsym(symbolHandle, "SetFrontProcessWithOptions") {
            _setFrontProcessWithOptions = unsafeBitCast(sym, to: SetFrontProcessWithOptionsFunc.self)
        }
    }

    func getWindowID(for element: AXUIElement) -> CGWindowID? {
        if let axGetWindow = _axGetWindow {
            var windowID: CGWindowID = 0
            let error = axGetWindow(element, &windowID)

            if error == .success, windowID != 0 {
                return windowID
            }

            if error == .apiDisabled {
                return nil
            }
        }

        return matchWindowIDByFrame(for: element)
    }

    func enumerateWindows(for application: NSRunningApplication) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)

        guard let windowsValue = copyAttributeValue(
            for: appElement,
            attribute: kAXWindowsAttribute as String
        ) else {
            return []
        }

        let windows = (windowsValue as? [Any])?.compactMap { value -> AXUIElement? in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(cfValue, to: AXUIElement.self)
        } ?? []

        return windows.filter(isEligibleWindow)
    }

    @discardableResult
    func raiseAndActivate(element: AXUIElement, app: NSRunningApplication) -> Bool {
        cancelDelayedActivationWorkItems()
        let requestID = UUID()
        activationRequestID = requestID

        let preservedDisplayWindows = topmostWindowsOnOtherDisplays(excludingDisplayFor: element)
        let didFocus = focusAndRaise(element: element, app: app)

        if app.isActive && isTopmostVisibleWindowOnDisplay(element: element, app: app) {
            return didFocus
        }

        let didActivate = activateFrontWindowOnly(app: app) || app.activate()

        scheduleDelayedActivationRefocus(
            after: 0.05,
            requestID: requestID,
            element: element,
            app: app,
            preservedDisplayWindows: preservedDisplayWindows
        )
        scheduleDelayedActivationRefocus(
            after: 0.18,
            requestID: requestID,
            element: element,
            app: app,
            preservedDisplayWindows: preservedDisplayWindows
        )

        return didFocus || didActivate
    }

    private func scheduleDelayedActivationRefocus(
        after delay: TimeInterval,
        requestID: UUID,
        element: AXUIElement,
        app: NSRunningApplication,
        preservedDisplayWindows: [PreservedDisplayWindow]
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.activationRequestID == requestID,
                !app.isTerminated,
                self.shouldContinueDelayedActivation(app: app)
            else {
                return
            }

            self.restorePreservedDisplayWindows(preservedDisplayWindows)

            guard
                self.activationRequestID == requestID,
                self.shouldContinueDelayedActivation(app: app)
            else {
                return
            }

            _ = self.focusAndRaise(element: element, app: app)
        }

        delayedActivationWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelDelayedActivationWorkItems() {
        for workItem in delayedActivationWorkItems {
            workItem.cancel()
        }
        delayedActivationWorkItems.removeAll()
    }

    private func shouldContinueDelayedActivation(app: NSRunningApplication) -> Bool {
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != app.processIdentifier,
           frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return false
        }

        return true
    }

    private func activateFrontWindowOnly(app: NSRunningApplication) -> Bool {
        guard
            let getProcessForPID = _getProcessForPID,
            let setFrontProcessWithOptions = _setFrontProcessWithOptions
        else {
            return false
        }

        var processSerialNumber = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard getProcessForPID(app.processIdentifier, &processSerialNumber) == noErr else {
            return false
        }

        return setFrontProcessWithOptions(
            &processSerialNumber,
            OptionBits(kSetFrontProcessFrontWindowOnly)
        ) == noErr
    }

    private func topmostWindowsOnOtherDisplays(excludingDisplayFor element: AXUIElement) -> [PreservedDisplayWindow] {
        guard
            let targetFrame = frame(for: element),
            let targetScreen = ScreenGeometry.screen(for: targetFrame),
            let targetDisplayID = ScreenGeometry.displayID(for: targetScreen),
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let applicationsByPID = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { ($0.processIdentifier, $0) }
        )
        var seenDisplayIDs = Set<CGDirectDisplayID>()
        var preservedWindows: [PreservedDisplayWindow] = []

        for windowInfo in windowList {
            guard
                let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                pid != currentPID,
                let app = applicationsByPID[pid],
                let layer = windowInfo[kCGWindowLayer as String] as? Int,
                layer == 0,
                let alpha = windowInfo[kCGWindowAlpha as String] as? Double,
                alpha > 0,
                let boundsDictionary = windowInfo[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width * bounds.height >= 100,
                let screen = ScreenGeometry.screen(for: bounds),
                let displayID = ScreenGeometry.displayID(for: screen),
                displayID != targetDisplayID,
                !seenDisplayIDs.contains(displayID),
                let element = windowElement(with: windowID, app: app)
            else {
                continue
            }

            preservedWindows.append(PreservedDisplayWindow(element: element))
            seenDisplayIDs.insert(displayID)
        }

        return preservedWindows
    }

    private func restorePreservedDisplayWindows(_ windows: [PreservedDisplayWindow]) {
        for window in windows {
            _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        }
    }

    private func windowElement(with windowID: CGWindowID, app: NSRunningApplication) -> AXUIElement? {
        enumerateWindows(for: app).first { getWindowID(for: $0) == windowID }
    }

    private func isTopmostVisibleWindowOnDisplay(
        element: AXUIElement,
        app: NSRunningApplication
    ) -> Bool {
        guard
            let targetWindowID = getWindowID(for: element),
            let targetFrame = frame(for: element),
            let targetScreen = ScreenGeometry.screen(for: targetFrame),
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else {
            return false
        }

        let targetDisplayBounds = ScreenGeometry.displayBounds(for: targetScreen)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let regularPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )

        for windowInfo in windowList {
            guard
                let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                pid != currentPID,
                regularPIDs.contains(pid),
                let layer = windowInfo[kCGWindowLayer as String] as? Int,
                layer == 0,
                let alpha = windowInfo[kCGWindowAlpha as String] as? Double,
                alpha > 0,
                let boundsDictionary = windowInfo[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width * bounds.height >= 100,
                ScreenGeometry.isWindow(bounds: bounds, onDisplay: targetDisplayBounds)
            else {
                continue
            }

            return windowID == targetWindowID
        }

        return false
    }

    @discardableResult
    private func focusAndRaise(element: AXUIElement, app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var didFocus = false

        if AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            element
        ) == .success {
            didFocus = true
        }

        if AXUIElementSetAttributeValue(
            element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        ) == .success {
            didFocus = true
        }

        if AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success {
            didFocus = true
        }

        if AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success {
            didFocus = true
        }

        return didFocus
    }

    func minimize(element: AXUIElement) {
        _ = AXUIElementSetAttributeValue(
            element,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        )
    }

    func close(element: AXUIElement) {
        guard let closeButton = copyAXUIElementAttribute(
            for: element,
            attribute: kAXCloseButtonAttribute as String
        ) else {
            return
        }

        _ = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
    }

    func windowTitle(for element: AXUIElement) -> String? {
        copyAttributeValue(for: element, attribute: kAXTitleAttribute as String) as? String
    }

    func isMinimized(element: AXUIElement) -> Bool {
        guard let minimizedValue = copyAttributeValue(
            for: element,
            attribute: kAXMinimizedAttribute as String
        ) else {
            return false
        }

        if let number = minimizedValue as? NSNumber {
            return number.boolValue
        }

        return false
    }

    private func isEligibleWindow(_ element: AXUIElement) -> Bool {
        guard let roleValue = copyAttributeValue(
            for: element,
            attribute: kAXRoleAttribute as String
        ) as? String,
        roleValue == kAXWindowRole as String else {
            return false
        }

        guard let subroleValue = copyAttributeValue(
            for: element,
            attribute: kAXSubroleAttribute as String
        ) as? String else {
            return false
        }

        return subroleValue == kAXStandardWindowSubrole as String ||
            subroleValue == kAXDialogSubrole as String
    }

    private func matchWindowIDByFrame(for element: AXUIElement) -> CGWindowID? {
        guard let pid = pid(for: element),
              let frame = frame(for: element),
              let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let windowPIDNumber = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
                  pid_t(windowPIDNumber.int32Value) == pid,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  frameMatches(frame, bounds),
                  let number = windowInfo[kCGWindowNumber as String] as? NSNumber else {
                continue
            }

            return CGWindowID(number.uint32Value)
        }

        return nil
    }

    private func pid(for element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        let error = AXUIElementGetPid(element, &pid)

        if error == .success {
            return pid
        }

        return nil
    }

    func frame(for element: AXUIElement) -> CGRect? {
        guard let position = cgPointAttribute(
            for: element,
            attribute: kAXPositionAttribute as String
        ),
        let size = cgSizeAttribute(
            for: element,
            attribute: kAXSizeAttribute as String
        ) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    func isFullScreen(element: AXUIElement) -> Bool {
        guard let value = copyAttributeValue(
            for: element,
            attribute: "AXFullScreen"
        ) else {
            return false
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return false
    }

    @discardableResult
    func setFrame(_ frame: CGRect, for element: AXUIElement) -> Bool {
        var position = frame.origin
        var size = frame.size

        guard
            let positionValue = AXValueCreate(.cgPoint, &position),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return false
        }

        let positionError = AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            positionValue
        )
        let sizeError = AXUIElementSetAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            sizeValue
        )

        return positionError == .success && sizeError == .success
    }

    private func cgPointAttribute(for element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = copyAXValueAttribute(for: element, attribute: attribute),
              AXValueGetType(value) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func cgSizeAttribute(for element: AXUIElement, attribute: String) -> CGSize? {
        guard let value = copyAXValueAttribute(for: element, attribute: attribute),
              AXValueGetType(value) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private func copyAttributeValue(for element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        if error == .success {
            return value
        }

        if error == .apiDisabled {
            return nil
        }

        return nil
    }

    private func copyAXUIElementAttribute(for element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = copyAttributeValue(for: element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyAXValueAttribute(for element: AXUIElement, attribute: String) -> AXValue? {
        guard let value = copyAttributeValue(for: element, attribute: attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXValue.self)
    }

    private func frameMatches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameMatchTolerance &&
            abs(lhs.origin.y - rhs.origin.y) <= frameMatchTolerance &&
            abs(lhs.size.width - rhs.size.width) <= frameMatchTolerance &&
            abs(lhs.size.height - rhs.size.height) <= frameMatchTolerance
    }
}
