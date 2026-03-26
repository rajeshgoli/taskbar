import AppKit
import Combine

class WindowManager: ObservableObject {
    @Published var windows: [WindowInfo] = []

    init() {
        refresh()
    }

    func refresh() {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        windows = runningApps.map { app in
            WindowInfo(
                pid: app.processIdentifier,
                appName: app.localizedName ?? "Unknown",
                icon: app.icon,
                bundleIdentifier: app.bundleIdentifier
            )
        }
    }
}
