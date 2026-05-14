import AppKit
import ApplicationServices

final class LauncherMenuAction: NSObject {
    let title: String
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.title = title
        self.handler = handler
    }

    func perform() {
        handler()
    }
}

enum LauncherMenuActionProvider {
    private static let commandKeyFlag = CGEventFlags.maskCommand
    private static let commandShiftKeyFlags: CGEventFlags = [.maskCommand, .maskShift]
    private static let keyCodeN: CGKeyCode = 45
    private static let allowedAXTitles = Set([
        "New Window",
        "New Finder Window",
        "New Incognito Window",
        "New Private Window"
    ])

    static func actions(
        pinnedApp: PinnedApp,
        runningApplication: NSRunningApplication?
    ) -> [LauncherMenuAction] {
        var actions = fallbackActions(
            bundleIdentifier: pinnedApp.bundleIdentifier,
            application: runningApplication
        )

        for axAction in axMenuActions(for: runningApplication)
            where !actions.contains(where: { $0.title == axAction.title }) {
            actions.append(axAction)
        }

        return actions
    }

    static func fallbackActionTitles(bundleIdentifier: String) -> [String] {
        fallbackActionDescriptors(bundleIdentifier: bundleIdentifier).map(\.title)
    }

    private static func fallbackActions(
        bundleIdentifier: String,
        application: NSRunningApplication?
    ) -> [LauncherMenuAction] {
        fallbackActionDescriptors(bundleIdentifier: bundleIdentifier).map { descriptor in
            LauncherMenuAction(title: descriptor.title) {
                descriptor.perform(application, bundleIdentifier)
            }
        }
    }

    private static func fallbackActionDescriptors(bundleIdentifier: String) -> [LauncherMenuActionDescriptor] {
        switch bundleIdentifier {
        case LauncherActivationPlanner.finderBundleIdentifier:
            return [
                LauncherMenuActionDescriptor(title: "New Finder Window") { _, _ in
                    LauncherApplicationActivator.openFinderWindow()
                }
            ]
        case "com.google.Chrome":
            return [
                keyboardShortcutDescriptor(title: "New Window", keyCode: keyCodeN, flags: commandKeyFlag),
                keyboardShortcutDescriptor(title: "New Incognito Window", keyCode: keyCodeN, flags: commandShiftKeyFlags)
            ]
        case "com.apple.Safari":
            return [
                keyboardShortcutDescriptor(title: "New Window", keyCode: keyCodeN, flags: commandKeyFlag),
                keyboardShortcutDescriptor(title: "New Private Window", keyCode: keyCodeN, flags: commandShiftKeyFlags)
            ]
        default:
            return []
        }
    }

    private static func keyboardShortcutDescriptor(
        title: String,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> LauncherMenuActionDescriptor {
        LauncherMenuActionDescriptor(title: title) { application, bundleIdentifier in
            LauncherApplicationActivator.activateOrLaunchForKeyboardShortcut(
                application,
                bundleIdentifier: bundleIdentifier
            ) {
                postKeyboardShortcut(keyCode: keyCode, flags: flags)
            }
        }
    }

    private static func axMenuActions(for application: NSRunningApplication?) -> [LauncherMenuAction] {
        guard
            AXIsProcessTrusted(),
            let application,
            let menuBar = copyAXElementAttribute(
                from: AXUIElementCreateApplication(application.processIdentifier),
                attribute: kAXMenuBarAttribute as CFString
            )
        else {
            return []
        }

        let menuItems = children(of: menuBar)
            .flatMap(children(of:))
            .flatMap(children(of:))

        var seenTitles = Set<String>()
        return menuItems.compactMap { item -> LauncherMenuAction? in
            let title = normalizedTitle(for: item)
            guard
                allowedAXTitles.contains(title),
                seenTitles.insert(title).inserted,
                isEnabled(item)
            else {
                return nil
            }

            return LauncherMenuAction(title: title) {
                _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
            }
        }
    }

    private static func postKeyboardShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

        keyDown?.flags = flags
        keyUp?.flags = flags

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
            let children = value as? [Any]
        else {
            return []
        }

        return children.compactMap { child in
            let cfChild = child as CFTypeRef
            guard CFGetTypeID(cfChild) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(cfChild, to: AXUIElement.self)
        }
    }

    private static func copyAXElementAttribute(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
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

    private static func normalizedTitle(for element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
            let title = value as? String
        else {
            return ""
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else {
            return true
        }

        return (value as? NSNumber)?.boolValue ?? true
    }
}

private struct LauncherMenuActionDescriptor {
    let title: String
    let perform: (NSRunningApplication?, String) -> Void
}
