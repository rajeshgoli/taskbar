import AppKit
import ApplicationServices
import Combine

final class WindowManager: ObservableObject {
    @Published var windows: [WindowInfo] = []

    private let accessibilityService: AccessibilityService
    private let refreshDebouncer = Debouncer()
    private var workspaceMonitor: WorkspaceMonitor?
    private var axObserverManager: AXObserverManager?
    private var pollTimer: Timer?

    private var authoritative: [CGWindowID: WindowInfo] = [:]
    private var provisional: [String: WindowInfo] = [:]
    private var provisionalElements: [String: AXUIElement] = [:]
    private var promotionWorkItems: [String: DispatchWorkItem] = [:]

    init(accessibilityService: AccessibilityService = AccessibilityService()) {
        self.accessibilityService = accessibilityService
        workspaceMonitor = WorkspaceMonitor(windowManager: self)
        axObserverManager = AXObserverManager(windowManager: self)
        startPollTimer()
        refresh()
    }

    deinit {
        pollTimer?.invalidate()
        promotionWorkItems.values.forEach { $0.cancel() }
    }

    func refreshDebounced() {
        refreshDebouncer.debounce { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        let regularApplications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let applicationsByPID = Dictionary(uniqueKeysWithValues: regularApplications.map { ($0.processIdentifier, $0) })
        let displayBounds = currentDisplayBounds()
        let cgSnapshots = fetchCGWindowSnapshots(
            displayBounds: displayBounds,
            applicationsByPID: applicationsByPID
        )

        var nextAuthoritative: [CGWindowID: WindowInfo] = Dictionary(
            uniqueKeysWithValues: cgSnapshots.map { snapshot in
                let application = applicationsByPID[snapshot.pid]
                let info = WindowInfo(
                    pid: snapshot.pid,
                    cgWindowID: snapshot.id,
                    provisionalID: nil,
                    appName: snapshot.appName,
                    title: snapshot.title,
                    icon: application?.icon,
                    bundleIdentifier: application?.bundleIdentifier,
                    isMinimized: false,
                    isHidden: application?.isHidden ?? false,
                    isProvisional: false
                )

                return (snapshot.id, info)
            }
        )

        var visibleProvisionalKeys = Set<String>()

        for application in regularApplications {
            let axWindows = accessibilityService.enumerateWindows(for: application)

            for axWindow in axWindows {
                guard isEligibleAXWindow(axWindow, displayBounds: displayBounds) else {
                    continue
                }

                let provisionalKey = provisionalKey(for: application.processIdentifier, element: axWindow)
                visibleProvisionalKeys.insert(provisionalKey)

                let title = axTitle(for: axWindow) ?? nextAuthoritative.values.first(where: {
                    $0.pid == application.processIdentifier && !$0.title.isEmpty
                })?.title ?? application.localizedName ?? ""

                let minimized = axIsMinimized(axWindow)
                let hidden = application.isHidden
                let baseInfo = WindowInfo(
                    pid: application.processIdentifier,
                    cgWindowID: nil,
                    provisionalID: provisionalKey,
                    appName: application.localizedName ?? "",
                    title: title,
                    icon: application.icon,
                    bundleIdentifier: application.bundleIdentifier,
                    isMinimized: minimized,
                    isHidden: hidden,
                    isProvisional: true
                )

                if let windowID = accessibilityService.getWindowID(for: axWindow) {
                    let merged = mergeAuthoritativeWindow(
                        existing: nextAuthoritative[windowID],
                        fallback: baseInfo,
                        windowID: windowID
                    )
                    nextAuthoritative[windowID] = merged
                    removeProvisionalWindow(forKey: provisionalKey)
                } else {
                    provisional[provisionalKey] = baseInfo
                    provisionalElements[provisionalKey] = axWindow
                    schedulePromotionRetry(for: provisionalKey)
                }
            }
        }

        for key in provisional.keys where !visibleProvisionalKeys.contains(key) {
            removeProvisionalWindow(forKey: key)
        }

        authoritative = nextAuthoritative
        publishWindows()
    }

    private func startPollTimer() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func currentDisplayBounds() -> CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    private func fetchCGWindowSnapshots(
        displayBounds: CGRect,
        applicationsByPID: [pid_t: NSRunningApplication]
    ) -> [CGWindowSnapshot] {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        return windowList.compactMap { entry in
            guard
                let id = entry[kCGWindowNumber as String] as? CGWindowID,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                let application = applicationsByPID[pid],
                let layer = entry[kCGWindowLayer as String] as? Int,
                let alpha = entry[kCGWindowAlpha as String] as? Double,
                let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else {
                return nil
            }

            let area = bounds.width * bounds.height
            guard
                layer == 0,
                alpha > 0,
                area >= 100,
                application.activationPolicy == .regular,
                displayBounds.contains(bounds.origin)
            else {
                return nil
            }

            let appName = (entry[kCGWindowOwnerName as String] as? String) ?? application.localizedName ?? ""
            let title = (entry[kCGWindowName as String] as? String) ?? ""

            return CGWindowSnapshot(
                id: id,
                pid: pid,
                appName: appName,
                title: title,
                bounds: bounds
            )
        }
    }

    private func isEligibleAXWindow(_ element: AXUIElement, displayBounds: CGRect) -> Bool {
        let role = axStringValue(for: element, attribute: kAXRoleAttribute as CFString)
        let subrole = axStringValue(for: element, attribute: kAXSubroleAttribute as CFString)

        guard
            role == (kAXWindowRole as String),
            subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String),
            let frame = axFrame(for: element),
            frame.width * frame.height >= 100,
            displayBounds.contains(frame.origin)
        else {
            return false
        }

        return true
    }

    private func axTitle(for element: AXUIElement) -> String? {
        let title = axStringValue(for: element, attribute: kAXTitleAttribute as CFString)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    private func axIsMinimized(_ element: AXUIElement) -> Bool {
        guard let value = axBoolValue(for: element, attribute: kAXMinimizedAttribute as CFString) else {
            return false
        }

        return value
    }

    private func axFrame(for element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue,
            let sizeValue
        else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero

        guard
            AXValueGetType(positionAXValue) == .cgPoint,
            AXValueGetValue(positionAXValue, .cgPoint, &position),
            AXValueGetType(sizeAXValue) == .cgSize,
            AXValueGetValue(sizeAXValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func axStringValue(for element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func axBoolValue(for element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let boolValue = value as? Bool
        else {
            return nil
        }

        return boolValue
    }

    private func schedulePromotionRetry(for key: String) {
        guard promotionWorkItems[key] == nil else {
            return
        }

        schedulePromotionRetry(for: key, remainingAttempts: 5)
    }

    private func schedulePromotionRetry(for key: String, remainingAttempts: Int) {
        guard remainingAttempts > 0 else {
            promotionWorkItems[key] = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.promotionWorkItems[key] = nil

            if self.promoteProvisionalWindow(forKey: key) {
                self.publishWindows()
                return
            }

            self.schedulePromotionRetry(for: key, remainingAttempts: remainingAttempts - 1)
        }

        promotionWorkItems[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    @discardableResult
    private func promoteProvisionalWindow(forKey key: String) -> Bool {
        guard
            let provisionalWindow = provisional[key],
            let element = provisionalElements[key],
            let windowID = accessibilityService.getWindowID(for: element)
        else {
            return false
        }

        if authoritative[windowID] == nil {
            authoritative[windowID] = WindowInfo(
                pid: provisionalWindow.pid,
                cgWindowID: windowID,
                provisionalID: nil,
                appName: provisionalWindow.appName,
                title: provisionalWindow.title,
                icon: provisionalWindow.icon,
                bundleIdentifier: provisionalWindow.bundleIdentifier,
                isMinimized: provisionalWindow.isMinimized,
                isHidden: provisionalWindow.isHidden,
                isProvisional: false
            )
        }

        removeProvisionalWindow(forKey: key)
        return true
    }

    private func removeProvisionalWindow(forKey key: String) {
        provisional.removeValue(forKey: key)
        provisionalElements.removeValue(forKey: key)
        promotionWorkItems.removeValue(forKey: key)?.cancel()
    }

    private func mergeAuthoritativeWindow(
        existing: WindowInfo?,
        fallback: WindowInfo,
        windowID: CGWindowID
    ) -> WindowInfo {
        WindowInfo(
            pid: fallback.pid,
            cgWindowID: windowID,
            provisionalID: nil,
            appName: existing?.appName.isEmpty == false ? existing!.appName : fallback.appName,
            title: fallback.title.isEmpty ? (existing?.title ?? "") : fallback.title,
            icon: fallback.icon ?? existing?.icon,
            bundleIdentifier: fallback.bundleIdentifier ?? existing?.bundleIdentifier,
            isMinimized: fallback.isMinimized,
            isHidden: fallback.isHidden,
            isProvisional: false
        )
    }

    private func publishWindows() {
        let combined = Array(authoritative.values) + Array(provisional.values)

        windows = combined.sorted {
            if $0.appName != $1.appName {
                return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }

            if $0.title != $1.title {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

            return $0.id < $1.id
        }
    }

    private func provisionalKey(for pid: pid_t, element: AXUIElement) -> String {
        "\(pid)-\(Unmanaged.passUnretained(element).toOpaque())"
    }
}

private struct CGWindowSnapshot {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
}
