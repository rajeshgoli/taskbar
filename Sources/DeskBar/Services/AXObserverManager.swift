import AppKit
import ApplicationServices

final class AXObserverManager {
    private weak var windowManager: WindowManager?
    private let debouncer = Debouncer()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var observers: [pid_t: AXObserver] = [:]

    private let notificationNames: [CFString] = [
        kAXCreatedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXTitleChangedNotification as CFString
    ]

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
        registerWorkspaceObservers()
        installObserversForRunningApps()
    }

    deinit {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)

        for observer in observers.values {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
    }

    private func registerWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    application.activationPolicy == .regular
                else {
                    return
                }

                self?.installObserver(for: application)
            }
        )

        workspaceObservers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else {
                    return
                }

                self?.removeObserver(for: application.processIdentifier)
            }
        )
    }

    private func installObserversForRunningApps() {
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            installObserver(for: application)
        }
    }

    private func installObserver(for application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard observers[pid] == nil else {
            return
        }

        var observer: AXObserver?
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let error = AXObserverCreate(pid, observerCallback, &observer)

        guard error == .success, let observer else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        notificationNames.forEach { notification in
            _ = AXObserverAddNotification(observer, appElement, notification, context)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        observers[pid] = observer
    }

    private func removeObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else {
            return
        }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    fileprivate func handleAXNotification() {
        debouncer.debounce { [weak self] in
            self?.windowManager?.refresh()
        }
    }
}

private let observerCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else {
        return
    }

    let manager = Unmanaged<AXObserverManager>.fromOpaque(refcon).takeUnretainedValue()
    manager.handleAXNotification()
}
