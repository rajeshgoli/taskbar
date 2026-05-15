import AppKit
import ApplicationServices
import Combine

struct WindowLayoutDisplaySnapshot: Codable, Equatable {
    let displayID: CGDirectDisplayID
    let uuidString: String?
    let bounds: CGRect
    let scale: CGFloat
    let resolution: CGSize
    let isMain: Bool

    var displayKey: String {
        uuidString ?? "display-\(displayID)"
    }
}

struct WindowLayoutWindowSnapshot: Codable, Equatable {
    let pid: pid_t
    let cgWindowID: CGWindowID?
    let bundleIdentifier: String?
    let appName: String
    let title: String
    let displayKey: String
    let absoluteFrame: CGRect
    let relativeFrame: CGRect
    let isMinimized: Bool
    let isHidden: Bool
    let isFullScreen: Bool
    let capturedAt: Date
}

struct WindowLayoutSnapshot: Codable, Equatable {
    let capturedAt: Date
    let displays: [WindowLayoutDisplaySnapshot]
    let windows: [WindowLayoutWindowSnapshot]
}

struct WindowLayoutLiveWindow {
    let pid: pid_t
    let cgWindowID: CGWindowID?
    let bundleIdentifier: String?
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let isHidden: Bool
    let isFullScreen: Bool
    let element: AXUIElement?
}

final class WindowLayoutSnapshotManager: ObservableObject {
    private static let restoreDebounceInterval: TimeInterval = 2
    private static let pendingWakeRestoreWindow: TimeInterval = 60
    private static let frameMatchTolerance: CGFloat = 4
    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
        guard let userInfo else {
            return
        }

        let manager = Unmanaged<WindowLayoutSnapshotManager>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        DispatchQueue.main.async {
            manager.handleDisplayConfigurationChange()
        }
    }

    @Published private(set) var hasRestorableSnapshot = false

    private let windowManager: WindowManager
    private let accessibilityService: AccessibilityService
    private let fileManager: FileManager
    private let storageURL: URL
    private let now: () -> Date
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private var latestSnapshot: WindowLayoutSnapshot?
    private var observers: [NSObjectProtocol] = []
    private var restoreWorkItem: DispatchWorkItem?
    private var pendingAutomaticRestoreUntil: Date?
    private var displayCallbackRegistered = false

    init(
        windowManager: WindowManager,
        accessibilityService: AccessibilityService = AccessibilityService(),
        fileManager: FileManager = .default,
        storageURL: URL = WindowLayoutSnapshotManager.defaultStorageURL(),
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        registerObservers: Bool = true
    ) {
        self.windowManager = windowManager
        self.accessibilityService = accessibilityService
        self.fileManager = fileManager
        self.storageURL = storageURL
        self.now = now
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        latestSnapshot = Self.loadSnapshot(from: storageURL)
        hasRestorableSnapshot = latestSnapshot?.windows.isEmpty == false

        if registerObservers {
            installObservers()
        }
    }

    deinit {
        observers.forEach { observer in
            notificationCenter.removeObserver(observer)
            workspaceNotificationCenter.removeObserver(observer)
        }
        restoreWorkItem?.cancel()

        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                Self.displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    func captureLatestLayout(reason: String) {
        guard AXIsProcessTrusted() else {
            print("DeskBar: skipping window layout capture for \(reason); Accessibility permission is unavailable.")
            return
        }

        windowManager.refresh()

        let capturedAt = now()
        let displays = currentDisplaySnapshots()
        let displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })
        let liveWindows = currentLiveWindows()
        let windows = windowManager.layoutSnapshotCandidates().compactMap { candidate -> WindowLayoutWindowSnapshot? in
            guard let display = displaysByID[candidate.displayID] else {
                return nil
            }

            let liveWindow = liveWindows.first {
                $0.pid == candidate.window.pid &&
                    candidate.window.cgWindowID != nil &&
                    $0.cgWindowID == candidate.window.cgWindowID
            }

            guard liveWindow?.isFullScreen != true else {
                return nil
            }

            return WindowLayoutWindowSnapshot(
                pid: candidate.window.pid,
                cgWindowID: candidate.window.cgWindowID,
                bundleIdentifier: candidate.window.bundleIdentifier,
                appName: candidate.window.appName,
                title: candidate.window.title,
                displayKey: display.displayKey,
                absoluteFrame: candidate.bounds,
                relativeFrame: Self.relativeFrame(for: candidate.bounds, in: display.bounds),
                isMinimized: candidate.window.isMinimized,
                isHidden: candidate.window.isHidden,
                isFullScreen: liveWindow?.isFullScreen ?? false,
                capturedAt: capturedAt
            )
        }

        latestSnapshot = WindowLayoutSnapshot(
            capturedAt: capturedAt,
            displays: displays,
            windows: windows
        )
        hasRestorableSnapshot = !windows.isEmpty
        persistLatestSnapshot()
    }

    func restoreLatestSnapshot(manual: Bool) {
        guard let latestSnapshot, !latestSnapshot.windows.isEmpty else {
            if manual {
                print("DeskBar: no sleep window layout snapshot is available.")
            }
            return
        }

        restore(snapshot: latestSnapshot, manual: manual)
    }

    func handleDisplayConfigurationChange() {
        guard pendingAutomaticRestoreUntil != nil else {
            return
        }

        schedulePendingAutomaticRestore()
    }

    static func relativeFrame(for frame: CGRect, in displayBounds: CGRect) -> CGRect {
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            return .zero
        }

        return CGRect(
            x: (frame.minX - displayBounds.minX) / displayBounds.width,
            y: (frame.minY - displayBounds.minY) / displayBounds.height,
            width: frame.width / displayBounds.width,
            height: frame.height / displayBounds.height
        )
    }

    static func absoluteFrame(from relativeFrame: CGRect, in displayBounds: CGRect) -> CGRect {
        CGRect(
            x: displayBounds.minX + relativeFrame.minX * displayBounds.width,
            y: displayBounds.minY + relativeFrame.minY * displayBounds.height,
            width: relativeFrame.width * displayBounds.width,
            height: relativeFrame.height * displayBounds.height
        )
    }

    static func clampedFrame(_ frame: CGRect, to displayBounds: CGRect) -> CGRect {
        let width = min(frame.width, displayBounds.width)
        let height = min(frame.height, displayBounds.height)
        let x = min(max(frame.minX, displayBounds.minX), displayBounds.maxX - width)
        let y = min(max(frame.minY, displayBounds.minY), displayBounds.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func mappedDisplays(
        capturedDisplays: [WindowLayoutDisplaySnapshot],
        currentDisplays: [WindowLayoutDisplaySnapshot]
    ) -> [String: WindowLayoutDisplaySnapshot]? {
        var mapping: [String: WindowLayoutDisplaySnapshot] = [:]
        var mappedCurrentDisplayIDs = Set<CGDirectDisplayID>()

        for capturedDisplay in capturedDisplays {
            guard let currentDisplay = currentDisplay(for: capturedDisplay, in: currentDisplays) else {
                return nil
            }

            guard !mappedCurrentDisplayIDs.contains(currentDisplay.displayID) else {
                return nil
            }

            mapping[capturedDisplay.displayKey] = currentDisplay
            mappedCurrentDisplayIDs.insert(currentDisplay.displayID)
        }

        return mapping
    }

    static func currentDisplay(
        for capturedDisplay: WindowLayoutDisplaySnapshot,
        in currentDisplays: [WindowLayoutDisplaySnapshot]
    ) -> WindowLayoutDisplaySnapshot? {
        if let uuidString = capturedDisplay.uuidString,
           let uuidMatch = currentDisplays.first(where: { $0.uuidString == uuidString }) {
            return uuidMatch
        }

        let fallbackMatches = currentDisplays.filter {
            $0.uuidString == nil &&
                $0.resolution == capturedDisplay.resolution &&
                $0.scale == capturedDisplay.scale
        }

        return fallbackMatches.count == 1 ? fallbackMatches[0] : nil
    }

    static func matchingLiveWindow(
        for snapshot: WindowLayoutWindowSnapshot,
        in liveWindows: [WindowLayoutLiveWindow]
    ) -> WindowLayoutLiveWindow? {
        if let cgWindowID = snapshot.cgWindowID,
           let match = liveWindows.first(where: { $0.pid == snapshot.pid && $0.cgWindowID == cgWindowID }) {
            return match
        }

        if let bundleIdentifier = snapshot.bundleIdentifier, !snapshot.title.isEmpty {
            let titleMatches = liveWindows.filter {
                $0.bundleIdentifier == bundleIdentifier && $0.title == snapshot.title
            }
            if titleMatches.count == 1 {
                return titleMatches[0]
            }
        }

        if let bundleIdentifier = snapshot.bundleIdentifier {
            let bundleMatches = liveWindows.filter { $0.bundleIdentifier == bundleIdentifier }
            if bundleMatches.count == 1 {
                return bundleMatches[0]
            }
        }

        return nil
    }

    private func installObservers() {
        let sleepNotifications: [Notification.Name] = [
            NSWorkspace.willSleepNotification
        ]
        sleepNotifications.forEach { name in
            observers.append(
                workspaceNotificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    self?.captureLatestLayout(reason: notification.name.rawValue)
                }
            )
        }

        observers.append(
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.beginPendingAutomaticRestore()
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleDisplayConfigurationChange()
            }
        )

        let callbackError = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        displayCallbackRegistered = callbackError == .success
    }

    private func beginPendingAutomaticRestore() {
        guard latestSnapshot?.windows.isEmpty == false else {
            return
        }

        pendingAutomaticRestoreUntil = now().addingTimeInterval(Self.pendingWakeRestoreWindow)
        schedulePendingAutomaticRestore()
    }

    private func schedulePendingAutomaticRestore() {
        restoreWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptPendingAutomaticRestore()
        }
        restoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.restoreDebounceInterval,
            execute: workItem
        )
    }

    private func attemptPendingAutomaticRestore() {
        guard let pendingAutomaticRestoreUntil else {
            return
        }

        guard now() <= pendingAutomaticRestoreUntil else {
            self.pendingAutomaticRestoreUntil = nil
            return
        }

        guard
            let latestSnapshot,
            Self.mappedDisplays(
                capturedDisplays: latestSnapshot.displays,
                currentDisplays: currentDisplaySnapshots()
            ) != nil
        else {
            return
        }

        restore(snapshot: latestSnapshot, manual: false)
        self.pendingAutomaticRestoreUntil = nil
    }

    private func restore(snapshot: WindowLayoutSnapshot, manual: Bool) {
        guard AXIsProcessTrusted() else {
            if manual {
                print("DeskBar: cannot restore window layout because Accessibility permission is unavailable.")
            }
            return
        }

        guard let displayMapping = Self.mappedDisplays(
            capturedDisplays: snapshot.displays,
            currentDisplays: currentDisplaySnapshots()
        ) else {
            if manual {
                print("DeskBar: cannot restore window layout because the captured display topology is unavailable.")
            }
            return
        }

        let liveWindows = currentLiveWindows()

        for capturedWindow in snapshot.windows {
            guard
                !capturedWindow.isMinimized,
                !capturedWindow.isHidden,
                !capturedWindow.isFullScreen,
                let currentDisplay = displayMapping[capturedWindow.displayKey],
                let liveWindow = Self.matchingLiveWindow(for: capturedWindow, in: liveWindows),
                !liveWindow.isMinimized,
                !liveWindow.isHidden,
                !liveWindow.isFullScreen,
                let element = liveWindow.element
            else {
                continue
            }

            let desiredFrame = Self.clampedFrame(
                Self.absoluteFrame(
                    from: capturedWindow.relativeFrame,
                    in: currentDisplay.bounds
                ),
                to: currentDisplay.bounds
            )

            guard !Self.framesMatch(liveWindow.frame, desiredFrame, tolerance: Self.frameMatchTolerance) else {
                continue
            }

            guard accessibilityService.setFrame(desiredFrame, for: element) else {
                if manual {
                    print("DeskBar: failed to restore \(capturedWindow.appName) \(capturedWindow.title)")
                }
                continue
            }

            windowManager.adjustWindowForTaskbar(element)
        }

        windowManager.refresh()
    }

    private func currentDisplaySnapshots() -> [WindowLayoutDisplaySnapshot] {
        let activeDisplayIDs = windowManager.activeDisplayIDs

        return NSScreen.screens.compactMap { screen in
            guard let displayID = ScreenGeometry.displayID(for: screen) else {
                return nil
            }

            guard activeDisplayIDs.isEmpty || activeDisplayIDs.contains(displayID) else {
                return nil
            }

            return Self.displaySnapshot(for: screen, displayID: displayID)
        }
    }

    private static func displaySnapshot(
        for screen: NSScreen,
        displayID: CGDirectDisplayID
    ) -> WindowLayoutDisplaySnapshot {
        WindowLayoutDisplaySnapshot(
            displayID: displayID,
            uuidString: uuidString(for: displayID),
            bounds: ScreenGeometry.displayBounds(for: screen),
            scale: screen.backingScaleFactor,
            resolution: CGSize(
                width: CGDisplayPixelsWide(displayID),
                height: CGDisplayPixelsHigh(displayID)
            ),
            isMain: NSScreen.main === screen
        )
    }

    private static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let value = CFUUIDCreateString(nil, uuid) else {
            return nil
        }

        return value as String
    }

    private func currentLiveWindows() -> [WindowLayoutLiveWindow] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .flatMap { application -> [WindowLayoutLiveWindow] in
                accessibilityService.enumerateWindows(for: application).compactMap { element in
                    guard
                        let frame = accessibilityService.frame(for: element),
                        frame.width * frame.height >= 100
                    else {
                        return nil
                    }

                    return WindowLayoutLiveWindow(
                        pid: application.processIdentifier,
                        cgWindowID: accessibilityService.getWindowID(for: element),
                        bundleIdentifier: application.bundleIdentifier,
                        title: accessibilityService.windowTitle(for: element)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                        frame: frame,
                        isMinimized: accessibilityService.isMinimized(element: element),
                        isHidden: application.isHidden,
                        isFullScreen: accessibilityService.isFullScreen(element: element),
                        element: element
                    )
                }
            }
    }

    private func persistLatestSnapshot() {
        guard let latestSnapshot else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(latestSnapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("DeskBar: failed to persist sleep window layout snapshot: \(error)")
        }
    }

    private static func loadSnapshot(from url: URL) -> WindowLayoutSnapshot? {
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(WindowLayoutSnapshot.self, from: data)
            return snapshot.windows.isEmpty ? nil : snapshot
        } catch {
            return nil
        }
    }

    private static func defaultStorageURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return baseURL
            .appendingPathComponent("DeskBar", isDirectory: true)
            .appendingPathComponent("window-layout-last-sleep.json")
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }
}
