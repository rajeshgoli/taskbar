import AppKit
import ApplicationServices
import Combine

final class BadgeMonitor: ObservableObject {
    @Published var appBadges: [String: Bool] = [:]

    private let pollInterval: TimeInterval = 5.0
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    init() {
        registerObservers()
        startPolling()
        refresh()
    }

    deinit {
        pollTimer?.invalidate()

        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.forEach(notificationCenter.removeObserver)
    }

    func refresh() {
        let runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        var nextBadges: [String: Bool] = [:]
        runningApplications.forEach { application in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return
            }

            nextBadges[bundleIdentifier] = false
        }

        dockBadgeStates(for: runningApplications).forEach { bundleIdentifier, hasBadge in
            nextBadges[bundleIdentifier] = hasBadge
        }

        guard nextBadges != appBadges else {
            return
        }

        appBadges = nextBadges
    }

    private func registerObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let notificationNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        observers = notificationNames.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func dockBadgeStates(for applications: [NSRunningApplication]) -> [String: Bool] {
        guard AXIsProcessTrusted() else {
            return [:]
        }

        guard let dockApplication = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == "com.apple.dock" }
        ) else {
            return [:]
        }

        let bundleIdentifiersByPath = applications.reduce(into: [String: String]()) { result, application in
            guard
                let bundleIdentifier = application.bundleIdentifier,
                let bundlePath = application.bundleURL?.standardizedFileURL.path
            else {
                return
            }

            result[bundlePath] = bundleIdentifier
        }

        let bundleIdentifiersByName = applications.reduce(into: [String: String]()) { result, application in
            guard
                let bundleIdentifier = application.bundleIdentifier,
                let localizedName = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !localizedName.isEmpty
            else {
                return
            }

            result[localizedName] = bundleIdentifier
        }
        let knownBundleIdentifiers = Set(applications.compactMap { $0.bundleIdentifier })

        var badges: [String: Bool] = [:]
        var visited = Set<UnsafeMutableRawPointer>()
        let dockElement = AXUIElementCreateApplication(dockApplication.processIdentifier)

        collectBadges(
            from: dockElement,
            inheritedBundleIdentifier: nil,
            knownBundleIdentifiers: knownBundleIdentifiers,
            bundleIdentifiersByPath: bundleIdentifiersByPath,
            bundleIdentifiersByName: bundleIdentifiersByName,
            visited: &visited,
            depth: 0,
            badges: &badges
        )

        return badges
    }

    private func collectBadges(
        from element: AXUIElement,
        inheritedBundleIdentifier: String?,
        knownBundleIdentifiers: Set<String>,
        bundleIdentifiersByPath: [String: String],
        bundleIdentifiersByName: [String: String],
        visited: inout Set<UnsafeMutableRawPointer>,
        depth: Int,
        badges: inout [String: Bool]
    ) {
        guard depth <= 6 else {
            return
        }

        let opaquePointer = Unmanaged.passUnretained(element).toOpaque()
        guard visited.insert(opaquePointer).inserted else {
            return
        }

        let bundleIdentifier = resolveBundleIdentifier(
            for: element,
            knownBundleIdentifiers: knownBundleIdentifiers,
            bundleIdentifiersByPath: bundleIdentifiersByPath,
            bundleIdentifiersByName: bundleIdentifiersByName
        ) ?? inheritedBundleIdentifier

        if let bundleIdentifier, elementHasBadgeIndicator(element) {
            badges[bundleIdentifier] = true
        }

        children(of: element).forEach { child in
            collectBadges(
                from: child,
                inheritedBundleIdentifier: bundleIdentifier,
                knownBundleIdentifiers: knownBundleIdentifiers,
                bundleIdentifiersByPath: bundleIdentifiersByPath,
                bundleIdentifiersByName: bundleIdentifiersByName,
                visited: &visited,
                depth: depth + 1,
                badges: &badges
            )
        }
    }

    private func resolveBundleIdentifier(
        for element: AXUIElement,
        knownBundleIdentifiers: Set<String>,
        bundleIdentifiersByPath: [String: String],
        bundleIdentifiersByName: [String: String]
    ) -> String? {
        if let identifier = stringValue(for: element, attribute: "AXIdentifier"),
           knownBundleIdentifiers.contains(identifier) {
            return identifier
        }

        if let urlValue = copyAttributeValue(for: element, attribute: "AXURL") {
            if let url = urlValue as? URL,
               let bundleIdentifier = bundleIdentifiersByPath[url.standardizedFileURL.path] {
                return bundleIdentifier
            }

            if let urlString = urlValue as? String,
               let url = URL(string: urlString),
               let bundleIdentifier = bundleIdentifiersByPath[url.standardizedFileURL.path] {
                return bundleIdentifier
            }
        }

        if let title = stringValue(for: element, attribute: kAXTitleAttribute as String),
           let bundleIdentifier = bundleIdentifiersByName[title] {
            return bundleIdentifier
        }

        if let description = stringValue(for: element, attribute: kAXDescriptionAttribute as String),
           let bundleIdentifier = bundleIdentifiersByName[description] {
            return bundleIdentifier
        }

        return nil
    }

    private func elementHasBadgeIndicator(_ element: AXUIElement) -> Bool {
        if let statusLabel = stringValue(for: element, attribute: "AXStatusLabel"), !statusLabel.isEmpty {
            return true
        }

        let attributeNames = attributeNames(for: element)
        for attribute in attributeNames where attribute.localizedCaseInsensitiveContains("badge") {
            if let value = stringValue(for: element, attribute: attribute), !value.isEmpty {
                return true
            }
        }

        if let description = stringValue(for: element, attribute: kAXDescriptionAttribute as String) {
            let normalizedDescription = description.lowercased()
            if normalizedDescription.contains("badge") || normalizedDescription.contains("notification") {
                return true
            }
        }

        return false
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttributeValue(for: element, attribute: kAXChildrenAttribute as String) else {
            return []
        }

        return (value as? [Any])?.compactMap { child in
            let childValue = child as CFTypeRef
            guard CFGetTypeID(childValue) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(childValue, to: AXUIElement.self)
        } ?? []
    }

    private func attributeNames(for element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else {
            return []
        }

        return names as? [String] ?? []
    }

    private func stringValue(for element: AXUIElement, attribute: String) -> String? {
        guard let value = copyAttributeValue(for: element, attribute: attribute) else {
            return nil
        }

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private func copyAttributeValue(for element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        return value
    }
}
