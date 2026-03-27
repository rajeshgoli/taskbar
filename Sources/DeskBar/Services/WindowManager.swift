import AppKit
import ApplicationServices
import Combine

final class WindowManager: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published private(set) var visibleWindows: [WindowInfo] = []
    @Published private(set) var trayApps: [NSRunningApplication] = []

    private let accessibilityService: AccessibilityService
    private let blacklistManager: BlacklistManager
    private let pinnedAppManager: PinnedAppManager
    private let refreshDebouncer = Debouncer()
    private var workspaceMonitor: WorkspaceMonitor?
    private var axObserverManager: AXObserverManager?
    private var pollTimer: Timer?
    private var blacklistObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    private var authoritative: [CGWindowID: WindowInfo] = [:]
    private var authoritativeBounds: [CGWindowID: CGRect] = [:]
    private var provisional: [String: WindowInfo] = [:]
    private var provisionalBounds: [String: CGRect] = [:]
    private var provisionalElements: [String: AXUIElement] = [:]
    private var promotionWorkItems: [String: DispatchWorkItem] = [:]

    init(
        accessibilityService: AccessibilityService = AccessibilityService(),
        blacklistManager: BlacklistManager = BlacklistManager(),
        pinnedAppManager: PinnedAppManager = PinnedAppManager()
    ) {
        self.accessibilityService = accessibilityService
        self.blacklistManager = blacklistManager
        self.pinnedAppManager = pinnedAppManager
        workspaceMonitor = WorkspaceMonitor(windowManager: self)
        axObserverManager = AXObserverManager(windowManager: self)
        blacklistObserver = NotificationCenter.default.addObserver(
            forName: BlacklistManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        pinnedAppManager.$pinnedApps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.publishDerivedState()
            }
            .store(in: &cancellables)
        startPollTimer()
        refresh()
    }

    deinit {
        pollTimer?.invalidate()
        promotionWorkItems.values.forEach { $0.cancel() }

        if let blacklistObserver {
            NotificationCenter.default.removeObserver(blacklistObserver)
        }
    }

    func refreshDebounced() {
        refreshDebouncer.debounce { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        let regularApplications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !isBlacklisted(bundleIdentifier: $0.bundleIdentifier)
        }
        let applicationsByPID = Dictionary(uniqueKeysWithValues: regularApplications.map { ($0.processIdentifier, $0) })
        let cgSnapshots = fetchCGWindowSnapshots(applicationsByPID: applicationsByPID)

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
        var nextAuthoritativeBounds = Dictionary(
            uniqueKeysWithValues: cgSnapshots.map { ($0.id, $0.bounds) }
        )

        var visibleProvisionalKeys = Set<String>()

        for application in regularApplications {
            let axWindows = accessibilityService.enumerateWindows(for: application)

            for axWindow in axWindows {
                guard
                    let frame = axFrame(for: axWindow),
                    isEligibleAXWindow(axWindow, frame: frame)
                else {
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
                    nextAuthoritativeBounds[windowID] = nextAuthoritativeBounds[windowID] ?? frame
                    removeProvisionalWindow(forKey: provisionalKey)
                } else {
                    provisional[provisionalKey] = baseInfo
                    provisionalBounds[provisionalKey] = frame
                    provisionalElements[provisionalKey] = axWindow
                    schedulePromotionRetry(for: provisionalKey)
                }
            }
        }

        for key in provisional.keys where !visibleProvisionalKeys.contains(key) {
            removeProvisionalWindow(forKey: key)
        }

        authoritative = nextAuthoritative
        authoritativeBounds = nextAuthoritativeBounds
        publishWindows()
    }

    func windows(on screen: NSScreen) -> [WindowInfo] {
        windows(onDisplay: ScreenGeometry.displayBounds(for: screen))
    }

    func windows(onDisplay displayBounds: CGRect) -> [WindowInfo] {
        windows.filter { window in
            guard let bounds = bounds(for: window) else {
                return false
            }

            return ScreenGeometry.isWindow(bounds: bounds, onDisplay: displayBounds)
        }
    }

    func visibleWindows(on screen: NSScreen) -> [WindowInfo] {
        visibleWindows(onDisplay: ScreenGeometry.displayBounds(for: screen))
    }

    func visibleWindows(onDisplay displayBounds: CGRect) -> [WindowInfo] {
        let scopedWindows = windows(onDisplay: displayBounds)
        let visibleWindowPIDs = Self.visibleWindowPIDs(from: scopedWindows)
        return scopedWindows.filter { visibleWindowPIDs.contains($0.pid) }
    }

    func trayApplications(on screen: NSScreen) -> [NSRunningApplication] {
        let displayBounds = ScreenGeometry.displayBounds(for: screen)
        let scopedWindows = windows(onDisplay: displayBounds)
        let visibleWindowPIDs = Self.visibleWindowPIDs(from: scopedWindows)
        let runningApplications = regularRunningApplications()
        let applicationsByPID = Dictionary(uniqueKeysWithValues: runningApplications.map { ($0.processIdentifier, $0) })
        let trayCandidates = Self.trayApplicationCandidates(
            from: runningApplications.map {
                RunningApplicationCandidate(
                    pid: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "Unknown"
                )
            },
            visibleWindowPIDs: visibleWindowPIDs,
            pinnedBundleIdentifiers: Set(pinnedAppManager.pinnedApps.map(\.bundleIdentifier)),
            blacklistedBundleIdentifiers: blacklistManager.blacklistedBundleIDs,
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )

        return trayCandidates.compactMap { applicationsByPID[$0.pid] }
    }

    func hasFullScreenWindow(on screen: NSScreen) -> Bool {
        let displayBounds = ScreenGeometry.displayBounds(for: screen)

        if AXIsProcessTrusted(), hasAXFullScreenWindow(onDisplay: displayBounds) {
            return true
        }

        return hasCGFullScreenWindow(onDisplay: displayBounds)
    }

    private func startPollTimer() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func fetchCGWindowSnapshots(applicationsByPID: [pid_t: NSRunningApplication]) -> [CGWindowSnapshot] {
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
                ScreenGeometry.screen(for: bounds) != nil
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

    private func isEligibleAXWindow(_ element: AXUIElement, frame: CGRect) -> Bool {
        let role = axStringValue(for: element, attribute: kAXRoleAttribute as CFString)
        let subrole = axStringValue(for: element, attribute: kAXSubroleAttribute as CFString)

        guard
            role == (kAXWindowRole as String),
            subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String),
            frame.width * frame.height >= 100,
            ScreenGeometry.screen(for: frame) != nil
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
            if let bounds = provisionalBounds[key] {
                authoritativeBounds[windowID] = bounds
            }
        }

        removeProvisionalWindow(forKey: key)
        return true
    }

    private func removeProvisionalWindow(forKey key: String) {
        provisional.removeValue(forKey: key)
        provisionalBounds.removeValue(forKey: key)
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
        let combined = (Array(authoritative.values) + Array(provisional.values)).filter { window in
            !isBlacklisted(bundleIdentifier: window.bundleIdentifier)
        }

        windows = combined.sorted {
            if $0.appName != $1.appName {
                return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }

            if $0.title != $1.title {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

            return $0.id < $1.id
        }

        publishDerivedState()
    }

    private func publishDerivedState() {
        let visibleWindowPIDs = Self.visibleWindowPIDs(from: windows)
        visibleWindows = windows.filter { visibleWindowPIDs.contains($0.pid) }

        let runningApplications = regularRunningApplications()
        let applicationsByPID = Dictionary(uniqueKeysWithValues: runningApplications.map { ($0.processIdentifier, $0) })
        let trayCandidates = Self.trayApplicationCandidates(
            from: runningApplications.map {
                RunningApplicationCandidate(
                    pid: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "Unknown"
                )
            },
            visibleWindowPIDs: visibleWindowPIDs,
            pinnedBundleIdentifiers: Set(pinnedAppManager.pinnedApps.map(\.bundleIdentifier)),
            blacklistedBundleIdentifiers: blacklistManager.blacklistedBundleIDs,
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )

        trayApps = trayCandidates.compactMap { applicationsByPID[$0.pid] }
    }

    private func regularRunningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
    }

    private func provisionalKey(for pid: pid_t, element: AXUIElement) -> String {
        "\(pid)-\(Unmanaged.passUnretained(element).toOpaque())"
    }

    private func bounds(for window: WindowInfo) -> CGRect? {
        if let cgWindowID = window.cgWindowID {
            return authoritativeBounds[cgWindowID]
        }

        if let provisionalID = window.provisionalID {
            return provisionalBounds[provisionalID]
        }

        return nil
    }

    private func isBlacklisted(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return blacklistManager.isBlacklisted(bundleIdentifier: bundleIdentifier)
    }

    private func hasAXFullScreenWindow(onDisplay displayBounds: CGRect) -> Bool {
        let regularApplications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }

        for application in regularApplications {
            let axWindows = accessibilityService.enumerateWindows(for: application)

            for axWindow in axWindows {
                guard
                    axBoolValue(for: axWindow, attribute: "AXFullScreen" as CFString) == true,
                    let frame = axFrame(for: axWindow),
                    ScreenGeometry.isWindow(bounds: frame, onDisplay: displayBounds)
                else {
                    continue
                }

                return true
            }
        }

        return false
    }

    private func hasCGFullScreenWindow(onDisplay displayBounds: CGRect) -> Bool {
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return false
        }

        return windowList.contains { entry in
            guard
                let layer = entry[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else {
                return false
            }

            return ScreenGeometry.matchesFullScreenWindow(bounds: bounds, onDisplay: displayBounds)
        }
    }

    static func visibleWindowPIDs(from windows: [WindowInfo]) -> Set<pid_t> {
        Set(
            Dictionary(grouping: windows, by: \.pid)
                .compactMap { pid, appWindows in
                    appWindows.contains(where: { !$0.isMinimized && !$0.isHidden }) ? pid : nil
                }
        )
    }

    static func trayApplicationCandidates(
        from candidates: [RunningApplicationCandidate],
        visibleWindowPIDs: Set<pid_t>,
        pinnedBundleIdentifiers: Set<String>,
        blacklistedBundleIdentifiers: Set<String>,
        currentBundleIdentifier: String?
    ) -> [RunningApplicationCandidate] {
        candidates
            .filter { candidate in
                guard candidate.bundleIdentifier != currentBundleIdentifier else {
                    return false
                }

                guard !visibleWindowPIDs.contains(candidate.pid) else {
                    return false
                }

                guard let bundleIdentifier = candidate.bundleIdentifier else {
                    return true
                }

                return !pinnedBundleIdentifiers.contains(bundleIdentifier) &&
                    !blacklistedBundleIdentifiers.contains(bundleIdentifier)
            }
            .sorted { lhs, rhs in
                let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

                return lhs.pid < rhs.pid
            }
    }
}

struct RunningApplicationCandidate: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
}

private struct CGWindowSnapshot {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
}
