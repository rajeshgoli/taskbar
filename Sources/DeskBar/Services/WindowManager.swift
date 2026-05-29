import AppKit
import ApplicationServices
import Combine
import Darwin

final class WindowManager: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published private(set) var visibleWindows: [WindowInfo] = []
    @Published private(set) var trayApps: [TrayApplicationInfo] = []

    private let accessibilityService: AccessibilityService
    private let blacklistManager: BlacklistManager
    private let pinnedAppManager: PinnedAppManager
    private let refreshDebouncer = Debouncer()
    private var workspaceMonitor: WorkspaceMonitor?
    private var axObserverManager: AXObserverManager?
    private var pollTimer: Timer?
    private var blacklistObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    var taskbarHeight: CGFloat = 40
    var activeDisplayIDs: Set<CGDirectDisplayID> = []

    private var authoritative: [CGWindowID: WindowInfo] = [:]
    private var authoritativeBounds: [CGWindowID: CGRect] = [:]
    private var provisional: [String: WindowInfo] = [:]
    private var provisionalBounds: [String: CGRect] = [:]
    private var provisionalElements: [String: AXUIElement] = [:]
    private var promotionWorkItems: [String: DispatchWorkItem] = [:]
    private var windowOrder: [String] = []
    private var publishedWindowState = PublishedWindowState(windows: [], boundsByWindowID: [:])

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
        var currentWindowOrder: [String] = []
        var seenWindowIDs = Set<String>()

        var nextAuthoritative: [CGWindowID: WindowInfo] = Dictionary(
            uniqueKeysWithValues: cgSnapshots.map { snapshot in
                let info = WindowInfo(
                    pid: snapshot.pid,
                    cgWindowID: snapshot.id,
                    provisionalID: nil,
                    appName: snapshot.appName,
                    title: snapshot.title,
                    icon: snapshot.icon,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    applicationURL: snapshot.bundleURL,
                    isMinimized: false,
                    isHidden: snapshot.isHidden,
                    isProvisional: false
                )
                Self.appendWindowID(info.id, to: &currentWindowOrder, seenWindowIDs: &seenWindowIDs)

                return (snapshot.id, info)
            }
        )
        var nextAuthoritativeBounds = Dictionary(
            uniqueKeysWithValues: cgSnapshots.map { ($0.id, $0.bounds) }
        )

        var visibleProvisionalKeys = Set<String>()
        var allAXWindows: [AXUIElement] = []

        for application in regularApplications {
            let axWindows = accessibilityService.enumerateWindows(for: application)

            for axWindow in axWindows {
                guard
                    let frame = axFrame(for: axWindow),
                    isEligibleAXWindow(axWindow, frame: frame)
                else {
                    continue
                }

                allAXWindows.append(axWindow)

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
                    applicationURL: application.bundleURL,
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
                    Self.appendWindowID(merged.id, to: &currentWindowOrder, seenWindowIDs: &seenWindowIDs)
                    removeProvisionalWindow(forKey: provisionalKey)
                } else {
                    provisional[provisionalKey] = baseInfo
                    provisionalBounds[provisionalKey] = frame
                    provisionalElements[provisionalKey] = axWindow
                    Self.appendWindowID(baseInfo.id, to: &currentWindowOrder, seenWindowIDs: &seenWindowIDs)
                    schedulePromotionRetry(for: provisionalKey)
                }
            }
        }

        for key in provisional.keys where !visibleProvisionalKeys.contains(key) {
            removeProvisionalWindow(forKey: key)
        }

        authoritative = nextAuthoritative
        authoritativeBounds = nextAuthoritativeBounds
        publishWindows(currentWindowOrder: currentWindowOrder)

        for axWindow in allAXWindows {
            adjustWindowForTaskbar(axWindow)
        }
    }

    func windows(on screen: NSScreen) -> [WindowInfo] {
        windows(onDisplay: ScreenGeometry.displayBounds(for: screen))
    }

    func windows(onDisplay displayBounds: CGRect) -> [WindowInfo] {
        windows.filter { window in
            // Minimized/hidden windows don't appear in CGWindowList (off-screen).
            // Keep them associated with the main display so they stay in the taskbar.
            if window.isMinimized || window.isHidden {
                guard let bounds = bounds(for: window) else {
                    // No known bounds — show on main display
                    return displayBounds == ScreenGeometry.mainDisplayBounds()
                }
                return ScreenGeometry.isWindow(bounds: bounds, onDisplay: displayBounds)
            }

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

    func taskbarZone(for window: WindowInfo, on screen: NSScreen) -> TaskbarWindowZone {
        guard let bounds = bounds(for: window) else {
            return .neutral
        }

        return ScreenGeometry.taskbarZone(
            for: bounds,
            onDisplay: ScreenGeometry.displayBounds(for: screen),
            topInset: ScreenGeometry.topInset(for: screen),
            taskbarHeight: taskbarHeight
        )
    }

    func frame(for window: WindowInfo) -> CGRect? {
        bounds(for: window)
    }

    func layoutSnapshotCandidates() -> [WindowLayoutCaptureCandidate] {
        windows.compactMap { window in
            guard
                !window.isMinimized,
                !window.isHidden,
                let bounds = bounds(for: window),
                let screen = ScreenGeometry.screen(for: bounds),
                let displayID = ScreenGeometry.displayID(for: screen),
                activeDisplayIDs.isEmpty || activeDisplayIDs.contains(displayID)
            else {
                return nil
            }

            return WindowLayoutCaptureCandidate(
                window: window,
                bounds: bounds,
                screen: screen,
                displayID: displayID,
                displayBounds: ScreenGeometry.displayBounds(for: screen)
            )
        }
    }

    func trayApplications(on screen: NSScreen) -> [TrayApplicationInfo] {
        let displayBounds = ScreenGeometry.displayBounds(for: screen)
        let scopedWindows = windows(onDisplay: displayBounds)
        let visibleWindowPIDs = Self.visibleWindowPIDs(from: scopedWindows)
        let visibleWindowBundleIdentifiers = Self.visibleWindowBundleIdentifiers(from: scopedWindows)
        let candidatesByKey = trayApplicationInfoByCandidateKey()
        let trayCandidates = Self.trayApplicationCandidates(
            from: candidatesByKey.values.map {
                RunningApplicationCandidate(
                    pid: $0.pid,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.name
                )
            },
            visibleWindowPIDs: visibleWindowPIDs,
            visibleWindowBundleIdentifiers: visibleWindowBundleIdentifiers,
            pinnedBundleIdentifiers: Set(pinnedAppManager.pinnedApps.map(\.bundleIdentifier)),
            blacklistedBundleIdentifiers: blacklistManager.blacklistedBundleIDs,
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )

        return trayCandidates.compactMap { candidatesByKey[Self.trayCandidateKey(for: $0)] }
    }

    func adjustWindowForTaskbar(_ element: AXUIElement) {
        guard AXIsProcessTrusted() else { return }

        // Don't touch true full-screen windows
        if axBoolValue(for: element, attribute: "AXFullScreen" as CFString) == true {
            return
        }

        guard let frame = axFrame(for: element) else { return }

        // Find which display this window is on — only adjust on displays with a DeskBar panel
        guard let screen = ScreenGeometry.screen(for: frame),
              let displayID = ScreenGeometry.displayID(for: screen),
              activeDisplayIDs.contains(displayID)
        else { return }
        guard let adjustedFrame = ScreenGeometry.adjustedFrameAvoidingTaskbar(
            for: frame,
            on: screen,
            taskbarHeight: taskbarHeight
        ) else { return }

        var size = adjustedFrame.size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }

    func hasFullScreenWindow(on screen: NSScreen) -> Bool {
        let displayBounds = ScreenGeometry.displayBounds(for: screen)

        // When accessibility is available, use AXFullScreen which reliably
        // distinguishes true full-screen from zoomed/maximized windows.
        // The CG geometry fallback cannot tell them apart — a zoomed window
        // with Dock hidden has the same bounds as a full-screen window.
        if AXIsProcessTrusted() {
            return hasAXFullScreenWindow(onDisplay: displayBounds)
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
                ScreenGeometry.screen(for: bounds) != nil
            else {
                return nil
            }

            let ownerName = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            guard let applicationInfo = cgWindowApplicationInfo(
                pid: pid,
                ownerName: ownerName,
                applicationsByPID: applicationsByPID
            ) else {
                return nil
            }

            let title = (entry[kCGWindowName as String] as? String) ?? ""

            return CGWindowSnapshot(
                id: id,
                pid: pid,
                appName: applicationInfo.name,
                title: title,
                icon: applicationInfo.icon,
                bundleIdentifier: applicationInfo.bundleIdentifier,
                bundleURL: applicationInfo.bundleURL,
                isHidden: applicationInfo.isHidden,
                bounds: bounds
            )
        }
    }

    private func cgWindowApplicationInfo(
        pid: pid_t,
        ownerName: String,
        applicationsByPID: [pid_t: NSRunningApplication]
    ) -> CGWindowApplicationInfo? {
        if let application = applicationsByPID[pid] {
            guard !isBlacklisted(bundleIdentifier: application.bundleIdentifier) else {
                return nil
            }

            let name = ownerName.isEmpty ? application.localizedName ?? "" : ownerName
            return CGWindowApplicationInfo(
                name: name,
                icon: application.icon,
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                isHidden: application.isHidden
            )
        }

        guard let inferredInfo = Self.inferredApplicationInfo(pid: pid, ownerName: ownerName),
              !isBlacklisted(bundleIdentifier: inferredInfo.bundleIdentifier)
        else {
            return nil
        }

        return inferredInfo
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
                applicationURL: provisionalWindow.applicationURL,
                isMinimized: provisionalWindow.isMinimized,
                isHidden: provisionalWindow.isHidden,
                isProvisional: false
            )
            if let bounds = provisionalBounds[key] {
                authoritativeBounds[windowID] = bounds
            }
        }

        replaceWindowOrderID(oldID: key, newID: provisionalWindow.withCGWindowID(windowID).id)
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
            applicationURL: fallback.applicationURL ?? existing?.applicationURL,
            isMinimized: fallback.isMinimized,
            isHidden: fallback.isHidden,
            isProvisional: false
        )
    }

    private func publishWindows(currentWindowOrder: [String]? = nil) {
        let combined = (Array(authoritative.values) + Array(provisional.values)).filter { window in
            !isBlacklisted(bundleIdentifier: window.bundleIdentifier)
        }
        let windowsByID = Dictionary(uniqueKeysWithValues: combined.map { ($0.id, $0) })
        let reconciledOrder = Self.reconcileStableWindowOrder(
            previousOrder: windowOrder,
            currentOrder: currentWindowOrder ?? combined.map(\.id)
        )

        let nextWindowOrder = reconciledOrder.filter { windowsByID[$0] != nil }
        let nextWindows = nextWindowOrder.compactMap { windowsByID[$0] }
        let nextPublishedWindowState = PublishedWindowState(
            windows: nextWindows,
            boundsByWindowID: boundsByWindowID(for: nextWindows)
        )

        windowOrder = nextWindowOrder
        if nextPublishedWindowState != publishedWindowState {
            publishedWindowState = nextPublishedWindowState
            windows = nextWindows
        }

        publishDerivedState()
    }

    private func publishDerivedState() {
        let visibleWindowPIDs = Self.visibleWindowPIDs(from: windows)
        let visibleWindowBundleIdentifiers = Self.visibleWindowBundleIdentifiers(from: windows)
        let nextVisibleWindows = windows.filter { visibleWindowPIDs.contains($0.pid) }
        if nextVisibleWindows != visibleWindows {
            visibleWindows = nextVisibleWindows
        }

        let candidatesByKey = trayApplicationInfoByCandidateKey()
        let trayCandidates = Self.trayApplicationCandidates(
            from: candidatesByKey.values.map {
                RunningApplicationCandidate(
                    pid: $0.pid,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.name
                )
            },
            visibleWindowPIDs: visibleWindowPIDs,
            visibleWindowBundleIdentifiers: visibleWindowBundleIdentifiers,
            pinnedBundleIdentifiers: Set(pinnedAppManager.pinnedApps.map(\.bundleIdentifier)),
            blacklistedBundleIdentifiers: blacklistManager.blacklistedBundleIDs,
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )

        let nextTrayApps = trayCandidates.compactMap { candidatesByKey[Self.trayCandidateKey(for: $0)] }
        if nextTrayApps != trayApps {
            trayApps = nextTrayApps
        }
    }

    private func boundsByWindowID(for windows: [WindowInfo]) -> [String: CGRect] {
        Dictionary(
            uniqueKeysWithValues: windows.compactMap { window in
                guard let bounds = bounds(for: window) else {
                    return nil
                }

                return (window.id, bounds)
            }
        )
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

    private static func inferredApplicationInfo(pid: pid_t, ownerName: String) -> CGWindowApplicationInfo? {
        guard
            let processPath = processPath(for: pid),
            let bundleURL = preferredDisplayBundleURL(containingExecutableAt: processPath),
            let bundle = Bundle(url: bundleURL)
        else {
            return nil
        }

        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
        let trimmedBundleName = bundleName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOwnerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedBundleName?.isEmpty == false ? trimmedBundleName! : trimmedOwnerName

        return CGWindowApplicationInfo(
            name: name.isEmpty ? "Unknown" : name,
            icon: NSWorkspace.shared.icon(forFile: bundleURL.path),
            bundleIdentifier: bundle.bundleIdentifier,
            bundleURL: bundleURL,
            isHidden: false
        )
    }

    static func preferredDisplayBundleURL(containingExecutableAt executablePath: String) -> URL? {
        let candidates = applicationBundleURLs(containingExecutableAt: executablePath)
        guard let nearestBundleURL = candidates.first else {
            return nil
        }

        if isHelperApplicationBundle(nearestBundleURL),
           let containingApplicationURL = candidates.dropFirst().first {
            return containingApplicationURL
        }

        return nearestBundleURL
    }

    private static func applicationBundleURLs(containingExecutableAt executablePath: String) -> [URL] {
        var candidates: [URL] = []
        var currentURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let rootURL = URL(fileURLWithPath: "/")

        while currentURL.path != rootURL.path {
            if isApplicationBundleDirectory(currentURL) {
                candidates.append(currentURL)
            }

            let parentURL = currentURL.deletingLastPathComponent()
            guard parentURL.path != currentURL.path else {
                break
            }
            currentURL = parentURL
        }

        return candidates
    }

    private static func isApplicationBundleDirectory(_ url: URL) -> Bool {
        guard
            let bundle = Bundle(url: url),
            let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
        else {
            return false
        }

        return packageType == "APPL"
    }

    private static func isHelperApplicationBundle(_ url: URL) -> Bool {
        guard let bundle = Bundle(url: url) else {
            return false
        }

        if let lsUIElement = bundle.object(forInfoDictionaryKey: "LSUIElement"),
           isTruthyInfoPlistValue(lsUIElement) {
            return true
        }

        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String ??
            url.deletingPathExtension().lastPathComponent
        return bundleName.localizedCaseInsensitiveContains("helper")
    }

    private static func isTruthyInfoPlistValue(_ value: Any) -> Bool {
        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes":
                return true
            default:
                return false
            }
        }

        return false
    }

    private static func processPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }

        return String(cString: buffer)
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

    static func visibleWindowBundleIdentifiers(from windows: [WindowInfo]) -> Set<String> {
        Set(
            windows.compactMap { window in
                guard !window.isMinimized, !window.isHidden else {
                    return nil
                }

                return window.bundleIdentifier
            }
        )
    }

    private func trayApplicationInfoByCandidateKey() -> [String: TrayApplicationInfo] {
        let regularInfos = regularRunningApplications().map(TrayApplicationInfo.init(application:))
        let regularPIDs = Set(regularInfos.map(\.pid))
        let inferredInfos = inferredTrayApplicationInfos(excludingPIDs: regularPIDs)

        return (regularInfos + inferredInfos).reduce(into: [:]) { result, info in
            let key = Self.trayCandidateKey(pid: info.pid, bundleIdentifier: info.bundleIdentifier)
            if let existing = result[key], existing.runningApplication != nil {
                return
            }

            result[key] = info
        }
    }

    private func inferredTrayApplicationInfos(excludingPIDs excludedPIDs: Set<pid_t>) -> [TrayApplicationInfo] {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        var infosByKey: [String: TrayApplicationInfo] = [:]
        for entry in windowList {
            guard
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                !excludedPIDs.contains(pid),
                let layer = entry[kCGWindowLayer as String] as? Int,
                let alpha = entry[kCGWindowAlpha as String] as? Double,
                let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                layer == 0,
                alpha > 0,
                bounds.width * bounds.height >= 100,
                let info = Self.inferredApplicationInfo(
                    pid: pid,
                    ownerName: (entry[kCGWindowOwnerName as String] as? String) ?? ""
                ),
                !isBlacklisted(bundleIdentifier: info.bundleIdentifier)
            else {
                continue
            }

            let trayInfo = TrayApplicationInfo(
                pid: pid,
                bundleIdentifier: info.bundleIdentifier,
                name: info.name,
                icon: info.icon,
                bundleURL: info.bundleURL,
                runningApplication: nil
            )
            let key = Self.trayCandidateKey(pid: pid, bundleIdentifier: info.bundleIdentifier)
            infosByKey[key] = infosByKey[key] ?? trayInfo
        }

        return Array(infosByKey.values)
    }

    static func trayApplicationCandidates(
        from candidates: [RunningApplicationCandidate],
        visibleWindowPIDs: Set<pid_t>,
        visibleWindowBundleIdentifiers: Set<String> = [],
        pinnedBundleIdentifiers: Set<String>,
        blacklistedBundleIdentifiers: Set<String>,
        currentBundleIdentifier: String?
    ) -> [RunningApplicationCandidate] {
        let uniqueCandidates = candidates.reduce(into: [String: RunningApplicationCandidate]()) { result, candidate in
            result[trayCandidateKey(for: candidate)] = result[trayCandidateKey(for: candidate)] ?? candidate
        }

        return uniqueCandidates.values
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

                guard !visibleWindowBundleIdentifiers.contains(bundleIdentifier) else {
                    return false
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

    private static func trayCandidateKey(for candidate: RunningApplicationCandidate) -> String {
        trayCandidateKey(pid: candidate.pid, bundleIdentifier: candidate.bundleIdentifier)
    }

    private static func trayCandidateKey(pid: pid_t, bundleIdentifier: String?) -> String {
        if let bundleIdentifier {
            return "bundle:\(bundleIdentifier)"
        }

        return "pid:\(pid)"
    }

    static func reconcileStableWindowOrder(previousOrder: [String], currentOrder: [String]) -> [String] {
        let currentIDSet = Set(currentOrder)
        var reconciledOrder = previousOrder.filter { currentIDSet.contains($0) }
        var seenIDs = Set(reconciledOrder)

        for windowID in currentOrder where seenIDs.insert(windowID).inserted {
            reconciledOrder.append(windowID)
        }

        return reconciledOrder
    }

    private static func appendWindowID(
        _ windowID: String,
        to orderedWindowIDs: inout [String],
        seenWindowIDs: inout Set<String>
    ) {
        guard seenWindowIDs.insert(windowID).inserted else {
            return
        }

        orderedWindowIDs.append(windowID)
    }

    private func replaceWindowOrderID(oldID: String, newID: String) {
        guard oldID != newID else {
            return
        }

        let existingNewIndex = windowOrder.firstIndex(of: newID)

        if let oldIndex = windowOrder.firstIndex(of: oldID) {
            if existingNewIndex == nil {
                windowOrder[oldIndex] = newID
            } else {
                windowOrder.remove(at: oldIndex)
            }
            return
        }

        guard existingNewIndex == nil else {
            return
        }

        windowOrder.append(newID)
    }

    private static func sameRunningApplications(
        _ lhs: [NSRunningApplication],
        _ rhs: [NSRunningApplication]
    ) -> Bool {
        runningApplicationSignatures(lhs) == runningApplicationSignatures(rhs)
    }

    private static func runningApplicationSignatures(
        _ applications: [NSRunningApplication]
    ) -> [RunningApplicationSignature] {
        applications.map { application in
            RunningApplicationSignature(
                pid: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName,
                iconSignature: ImageMetadataSignature(application.icon)
            )
        }
    }
}

private struct PublishedWindowState: Equatable {
    let windows: [WindowInfo]
    let boundsByWindowID: [String: CGRect]
}

private struct RunningApplicationSignature: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let iconSignature: ImageMetadataSignature
}

private struct CGWindowApplicationInfo {
    let name: String
    let icon: NSImage?
    let bundleIdentifier: String?
    let bundleURL: URL?
    let isHidden: Bool
}

struct TrayApplicationInfo: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
    let icon: NSImage?
    let bundleURL: URL?
    let runningApplication: NSRunningApplication?
    private let iconSignature: ImageMetadataSignature

    init(
        pid: pid_t,
        bundleIdentifier: String?,
        name: String,
        icon: NSImage?,
        bundleURL: URL?,
        runningApplication: NSRunningApplication?
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.icon = icon
        self.bundleURL = bundleURL
        self.runningApplication = runningApplication
        iconSignature = ImageMetadataSignature(icon)
    }

    init(application: NSRunningApplication) {
        self.init(
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            name: application.localizedName ?? application.bundleIdentifier ?? "Unknown",
            icon: application.icon,
            bundleURL: application.bundleURL,
            runningApplication: application
        )
    }

    static func == (lhs: TrayApplicationInfo, rhs: TrayApplicationInfo) -> Bool {
        lhs.pid == rhs.pid &&
            lhs.bundleIdentifier == rhs.bundleIdentifier &&
            lhs.name == rhs.name &&
            lhs.bundleURL == rhs.bundleURL &&
            lhs.iconSignature == rhs.iconSignature &&
            lhs.runningApplication?.processIdentifier == rhs.runningApplication?.processIdentifier
    }
}

struct RunningApplicationCandidate: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
}

struct WindowLayoutCaptureCandidate {
    let window: WindowInfo
    let bounds: CGRect
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
}

private struct CGWindowSnapshot {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage?
    let bundleIdentifier: String?
    let bundleURL: URL?
    let isHidden: Bool
    let bounds: CGRect
}

private extension WindowInfo {
    func withCGWindowID(_ cgWindowID: CGWindowID) -> WindowInfo {
        WindowInfo(
            pid: pid,
            cgWindowID: cgWindowID,
            provisionalID: nil,
            appName: appName,
            title: title,
            icon: icon,
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL,
            isMinimized: isMinimized,
            isHidden: isHidden,
            isProvisional: false
        )
    }
}
