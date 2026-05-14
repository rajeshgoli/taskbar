import AppKit
import ApplicationServices

final class LauncherMenuAction: NSObject {
    let title: String
    let identifier: String
    private let handler: () -> Void

    init(title: String, identifier: String, handler: @escaping () -> Void) {
        self.title = title
        self.identifier = identifier
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
    private static let newWindowIdentifier = "newWindow"
    private static let newPrivateWindowIdentifier = "newPrivateWindow"
    private static let axMenuItemModifierShift: UInt32 = 1 << 0

    static func actions(
        pinnedApp: PinnedApp,
        runningApplication: NSRunningApplication?
    ) -> [LauncherMenuAction] {
        var actions = axMenuActions(
            for: runningApplication,
            bundleIdentifier: pinnedApp.bundleIdentifier
        )

        for fallbackAction in fallbackActions(
            bundleIdentifier: pinnedApp.bundleIdentifier,
            application: runningApplication
        ) where !actions.contains(where: { $0.identifier == fallbackAction.identifier }) {
            actions.append(fallbackAction)
        }

        return actions
    }

    static func launcherActionIdentifier(
        bundleIdentifier: String,
        commandCharacter: String?,
        commandModifiers: UInt32?,
        title: String
    ) -> String? {
        if let identifier = launcherActionIdentifier(
            bundleIdentifier: bundleIdentifier,
            commandCharacter: commandCharacter,
            commandModifiers: commandModifiers
        ) {
            return identifier
        }

        return launcherActionIdentifier(bundleIdentifier: bundleIdentifier, title: title)
    }

    static func fallbackActionTitles(bundleIdentifier: String) -> [String] {
        fallbackActionDescriptors(bundleIdentifier: bundleIdentifier).map(\.title)
    }

    private static func fallbackActions(
        bundleIdentifier: String,
        application: NSRunningApplication?
    ) -> [LauncherMenuAction] {
        fallbackActionDescriptors(bundleIdentifier: bundleIdentifier).map { descriptor in
            LauncherMenuAction(title: descriptor.title, identifier: descriptor.identifier) {
                descriptor.perform(application, bundleIdentifier)
            }
        }
    }

    private static func fallbackActionDescriptors(bundleIdentifier: String) -> [LauncherMenuActionDescriptor] {
        switch bundleIdentifier {
        case LauncherActivationPlanner.finderBundleIdentifier:
            return [
                LauncherMenuActionDescriptor(title: "New Finder Window", identifier: newWindowIdentifier) { _, _ in
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
        LauncherMenuActionDescriptor(title: title, identifier: identifier(for: flags)) { application, bundleIdentifier in
            LauncherApplicationActivator.activateOrLaunchForKeyboardShortcut(
                application,
                bundleIdentifier: bundleIdentifier
            ) {
                postKeyboardShortcut(keyCode: keyCode, flags: flags)
            }
        }
    }

    private static func axMenuActions(
        for application: NSRunningApplication?,
        bundleIdentifier: String
    ) -> [LauncherMenuAction] {
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

        var seenIdentifiers = Set<String>()
        return menuItems.compactMap { item -> LauncherMenuAction? in
            let title = normalizedTitle(for: item)
            let identifier = launcherActionIdentifier(
                bundleIdentifier: bundleIdentifier,
                commandCharacter: commandCharacter(for: item),
                commandModifiers: commandModifiers(for: item),
                title: title
            )
            guard
                let identifier,
                !title.isEmpty,
                seenIdentifiers.insert(identifier).inserted,
                isEnabled(item)
            else {
                return nil
            }

            return LauncherMenuAction(title: title, identifier: identifier) {
                _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
            }
        }
    }

    private static func identifier(for flags: CGEventFlags) -> String {
        flags.contains(.maskShift) ? newPrivateWindowIdentifier : newWindowIdentifier
    }

    private static func launcherActionIdentifier(
        bundleIdentifier: String,
        commandCharacter: String?,
        commandModifiers: UInt32?
    ) -> String? {
        guard
            commandCharacter?.uppercased() == "N",
            let commandModifiers,
            commandModifiers & ~axMenuItemModifierShift == 0
        else {
            return nil
        }

        let includesShift = commandModifiers & axMenuItemModifierShift != 0

        if bundleIdentifier == LauncherActivationPlanner.finderBundleIdentifier {
            return includesShift ? nil : newWindowIdentifier
        }

        if bundleIdentifier == "com.google.Chrome" || bundleIdentifier == "com.apple.Safari" {
            return includesShift ? newPrivateWindowIdentifier : newWindowIdentifier
        }

        return includesShift ? nil : newWindowIdentifier
    }

    private static func launcherActionIdentifier(bundleIdentifier: String, title: String) -> String? {
        switch title {
        case "New Window", "New Finder Window":
            return newWindowIdentifier
        case "New Incognito Window", "New Private Window":
            return bundleIdentifier == LauncherActivationPlanner.finderBundleIdentifier ? nil : newPrivateWindowIdentifier
        default:
            return nil
        }
    }

    private static func commandCharacter(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &value) == .success,
            let commandCharacter = value as? String
        else {
            return nil
        }

        return commandCharacter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commandModifiers(for element: AXUIElement) -> UInt32? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &value) == .success,
            let modifiers = value as? NSNumber
        else {
            return nil
        }

        return modifiers.uint32Value
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
    let identifier: String
    let perform: (NSRunningApplication?, String) -> Void
}
