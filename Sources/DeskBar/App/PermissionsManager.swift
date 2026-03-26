import AppKit
import ApplicationServices
import Combine

final class PermissionsManager: ObservableObject {
    @Published private(set) var isAccessibilityGranted: Bool

    private let pollQueue = DispatchQueue(label: "com.deskbar.permissions")
    private var pollTimer: DispatchSourceTimer?

    init() {
        isAccessibilityGranted = Self.checkAccessibilityPermissionOnLaunch()
        startPolling()
    }

    deinit {
        pollTimer?.cancel()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.refreshAccessibilityPermission()
        }
        timer.resume()
        pollTimer = timer
    }

    private func refreshAccessibilityPermission() {
        let isGranted = AXIsProcessTrusted()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAccessibilityGranted != isGranted else {
                return
            }

            self.isAccessibilityGranted = isGranted
        }
    }

    private static func checkAccessibilityPermissionOnLaunch() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
