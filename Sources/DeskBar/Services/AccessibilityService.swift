import AppKit
import ApplicationServices
import Darwin

final class AccessibilityService {
    typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private let frameMatchTolerance: CGFloat = 2
    private var _axGetWindow: AXUIElementGetWindowFunc?

    init() {
        if let sym = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") {
            _axGetWindow = unsafeBitCast(sym, to: AXUIElementGetWindowFunc.self)
        } else {
            print("DeskBar: _AXUIElementGetWindow unavailable, using frame-matching fallback. Thumbnail accuracy may be reduced.")
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

    func raiseAndActivate(element: AXUIElement, app: NSRunningApplication) {
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        _ = app.activate()
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

    private func frame(for element: AXUIElement) -> CGRect? {
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
