import AppKit

final class WorkspaceMonitor {
    private weak var windowManager: WindowManager?
    private let debouncer = Debouncer()
    private var observers: [NSObjectProtocol] = []

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
        registerObservers()
    }

    deinit {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.forEach(notificationCenter.removeObserver)
    }

    private func registerObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]

        observers = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.debouncer.debounce { [weak self] in
                    self?.windowManager?.refresh()
                }
            }
        }
    }
}
