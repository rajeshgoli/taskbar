import AppKit
import ApplicationServices
import Combine
import Darwin

@MainActor
final class AppStateMonitor: ObservableObject {
    @Published private(set) var states: [pid_t: AppRuntimeState] = [:]

    private let accessibilityService: AccessibilityService
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var launchDeadlines: [pid_t: Date] = [:]
    private var attentionDeadlines: [pid_t: Date] = [:]
    private var cpuSamples: [pid_t: CPUSample] = [:]
    private var previousProgressFractions: [pid_t: Double] = [:]

    init(accessibilityService: AccessibilityService = AccessibilityService()) {
        self.accessibilityService = accessibilityService
        installWorkspaceObservers()
        startPollTimer()
        refresh()
    }

    deinit {
        pollTimer?.invalidate()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
    }

    func state(for pid: pid_t) -> AppRuntimeState {
        states[pid] ?? AppRuntimeState()
    }

    func requestAttention(for pid: pid_t, duration: TimeInterval = 1.6) {
        attentionDeadlines[pid] = Date().addingTimeInterval(duration)
        refresh()
    }

    private func installWorkspaceObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let refreshNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]

        workspaceObservers = refreshNames.map { name in
            workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else {
                    return
                }

                Task { @MainActor [weak self] in
                    self?.handleWorkspaceNotification(name: name, notification: notification)
                }
            }
        }
    }

    private func handleWorkspaceNotification(name: Notification.Name, notification: Notification) {
        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            refresh()
            return
        }

        let pid = application.processIdentifier

        switch name {
        case NSWorkspace.didLaunchApplicationNotification:
            launchDeadlines[pid] = Date().addingTimeInterval(8)
            requestAttention(for: pid, duration: 1.0)
        case NSWorkspace.didActivateApplicationNotification:
            attentionDeadlines.removeValue(forKey: pid)
            launchDeadlines.removeValue(forKey: pid)
        case NSWorkspace.didTerminateApplicationNotification:
            launchDeadlines.removeValue(forKey: pid)
            attentionDeadlines.removeValue(forKey: pid)
            cpuSamples.removeValue(forKey: pid)
            previousProgressFractions.removeValue(forKey: pid)
        default:
            break
        }

        refresh()
    }

    private func startPollTimer() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let now = Date()
        let timestamp = now.timeIntervalSinceReferenceDate
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let livePIDs = Set(applications.map(\.processIdentifier))

        launchDeadlines = launchDeadlines.filter { livePIDs.contains($0.key) && $0.value > now }
        attentionDeadlines = attentionDeadlines.filter { livePIDs.contains($0.key) && $0.value > now }
        cpuSamples = cpuSamples.filter { livePIDs.contains($0.key) }
        previousProgressFractions = previousProgressFractions.filter { livePIDs.contains($0.key) }

        var nextStates: [pid_t: AppRuntimeState] = [:]

        for application in applications {
            let pid = application.processIdentifier
            let windows = AXIsProcessTrusted() ? accessibilityService.enumerateWindows(for: application) : []
            let resourceSample = sampleResources(for: pid, timestamp: timestamp)
            let progressFraction = progressFraction(for: windows)
            let previousProgress = previousProgressFractions[pid]

            if let previousProgress,
               let progressFraction,
               progressFraction > previousProgress + 0.08,
               frontmostPID != pid {
                attentionDeadlines[pid] = now.addingTimeInterval(1.2)
            }

            if let progressFraction {
                previousProgressFractions[pid] = progressFraction
            } else {
                previousProgressFractions.removeValue(forKey: pid)
            }

            nextStates[pid] = AppRuntimeState(
                isLaunching: isLaunching(
                    application: application,
                    pid: pid,
                    now: now,
                    hasWindows: !windows.isEmpty,
                    progressFraction: progressFraction
                ),
                needsAttention: attentionDeadlines[pid].map { $0 > now } ?? false,
                cpuPercent: resourceSample.cpuPercent,
                memoryMB: resourceSample.memoryMB,
                progressFraction: progressFraction
            )
        }

        states = nextStates
    }

    private func isLaunching(
        application: NSRunningApplication,
        pid: pid_t,
        now: Date,
        hasWindows: Bool,
        progressFraction: Double?
    ) -> Bool {
        guard let deadline = launchDeadlines[pid], deadline > now else {
            return false
        }

        if application.isFinishedLaunching, hasWindows || progressFraction != nil || application.isActive {
            launchDeadlines.removeValue(forKey: pid)
            return false
        }

        return true
    }

    private func progressFraction(for windows: [AXUIElement]) -> Double? {
        guard AXIsProcessTrusted(), !windows.isEmpty else {
            return nil
        }

        let maxDepth = 3
        let maxNodes = 96
        var queue = windows.map { QueuedAXElement(element: $0, depth: 0) }
        var scannedNodes = 0
        var bestProgress: Double?

        while !queue.isEmpty, scannedNodes < maxNodes {
            let queued = queue.removeFirst()
            scannedNodes += 1

            if axRole(for: queued.element) == kAXProgressIndicatorRole as String,
               let progress = normalizedProgressValue(for: queued.element) {
                bestProgress = max(bestProgress ?? progress, progress)
            }

            guard queued.depth < maxDepth else {
                continue
            }

            let children = axChildren(for: queued.element)
            queue.append(contentsOf: children.map { QueuedAXElement(element: $0, depth: queued.depth + 1) })
        }

        return bestProgress
    }

    private func axChildren(for element: AXUIElement) -> [AXUIElement] {
        let childAttributes: [CFString] = [
            kAXChildrenAttribute as CFString,
            "AXContents" as CFString
        ]

        var children: [AXUIElement] = []

        for attribute in childAttributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
                  let values = value as? [Any] else {
                continue
            }

            for value in values {
                let cfValue = value as CFTypeRef
                guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
                    continue
                }

                children.append(unsafeBitCast(cfValue, to: AXUIElement.self))
            }
        }

        return children
    }

    private func axRole(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func normalizedProgressValue(for element: AXUIElement) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }

        if let number = value as? NSNumber {
            let rawValue = number.doubleValue
            if (0 ... 1).contains(rawValue) {
                return rawValue
            }

            if (0 ... 100).contains(rawValue) {
                return rawValue / 100
            }
        }

        return nil
    }

    private func sampleResources(for pid: pid_t, timestamp: TimeInterval) -> ResourceSample {
        var taskInfo = proc_taskinfo()
        let result = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_taskinfo>.size)
            )
        }

        guard result == MemoryLayout<proc_taskinfo>.size else {
            return ResourceSample(cpuPercent: nil, memoryMB: nil)
        }

        let totalCPUTime = taskInfo.pti_total_user + taskInfo.pti_total_system
        let memoryMB = Double(taskInfo.pti_resident_size) / 1_048_576
        var cpuPercent: Double?

        if let previousSample = cpuSamples[pid], timestamp > previousSample.timestamp {
            let elapsedNanoseconds = (timestamp - previousSample.timestamp) * 1_000_000_000
            if elapsedNanoseconds > 0 {
                let usedNanoseconds = Double(totalCPUTime - previousSample.totalCPUTime)
                cpuPercent = min(max((usedNanoseconds / elapsedNanoseconds) * 100, 0), 999)
            }
        }

        cpuSamples[pid] = CPUSample(totalCPUTime: totalCPUTime, timestamp: timestamp)
        return ResourceSample(cpuPercent: cpuPercent, memoryMB: memoryMB)
    }
}

private struct CPUSample {
    let totalCPUTime: UInt64
    let timestamp: TimeInterval
}

private struct ResourceSample {
    let cpuPercent: Double?
    let memoryMB: Double?
}

private struct QueuedAXElement {
    let element: AXUIElement
    let depth: Int
}
