import AppKit

enum LauncherApplicationActivator {
    static func launch(bundleIdentifier: String, applicationURL: URL?) {
        if let applicationURL = applicationURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            openApplication(at: applicationURL)
            return
        }

        print("DeskBar: unable to resolve launcher application for bundle identifier \(bundleIdentifier)")
    }

    static func activate(
        _ application: NSRunningApplication,
        bundleIdentifier: String,
        applicationURL: URL?,
        shouldReopen: Bool
    ) {
        application.unhide()
        _ = application.activate(options: .activateAllWindows)

        guard shouldReopen else {
            return
        }

        reopen(bundleIdentifier: bundleIdentifier, applicationURL: applicationURL ?? application.bundleURL)
    }

    static func reopen(bundleIdentifier: String, applicationURL: URL?) {
        if sendReopenEvent(bundleIdentifier: bundleIdentifier) {
            return
        }

        launch(bundleIdentifier: bundleIdentifier, applicationURL: applicationURL)
    }

    static func activateOrLaunchForKeyboardShortcut(
        _ application: NSRunningApplication?,
        bundleIdentifier: String,
        completion: @escaping () -> Void
    ) {
        if let application {
            application.unhide()
            _ = application.activate(options: .activateAllWindows)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                completion()
            }
            return
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
            guard error == nil, let application else {
                if let error {
                    print("DeskBar: failed to open launcher application at \(applicationURL.path): \(error)")
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                application.activate(options: .activateAllWindows)
                completion()
            }
        }
    }

    static func openFinderWindow() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser

        if NSWorkspace.shared.open(homeURL) {
            return
        }

        launch(
            bundleIdentifier: LauncherActivationPlanner.finderBundleIdentifier,
            applicationURL: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: LauncherActivationPlanner.finderBundleIdentifier
            )
        )
    }

    static func hasCGWindows(for application: NSRunningApplication) -> Bool {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else {
            return false
        }

        return windowList.contains { entry in
            guard
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                pid == application.processIdentifier,
                let layer = entry[kCGWindowLayer as String] as? Int,
                let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else {
                return false
            }

            return layer == 0 && bounds.width * bounds.height >= 100
        }
    }

    private static func openApplication(at applicationURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            if let error {
                print("DeskBar: failed to open launcher application at \(applicationURL.path): \(error)")
            }
        }
    }

    private static func sendReopenEvent(bundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        do {
            _ = try event.sendEvent(options: [.noReply, .canInteract], timeout: 1)
            return true
        } catch {
            print("DeskBar: failed to send reopen event to \(bundleIdentifier): \(error)")
            return false
        }
    }
}
