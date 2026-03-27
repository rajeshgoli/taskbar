import Combine
import Foundation

final class LoginItemManager {
    private enum LoginItemManagerError: Error {
        case missingBinaryPath
        case launchctlFailed(arguments: [String], status: Int32)
    }

    private let settings: TaskbarSettings
    private let fileManager: FileManager
    private let plistURL: URL
    private let binaryPathProvider: () -> String?
    private let launchctl: ([String]) throws -> Void
    private var cancellables = Set<AnyCancellable>()

    var isEnabled: Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    init(
        settings: TaskbarSettings,
        fileManager: FileManager = .default,
        plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.deskbar.app.plist"),
        binaryPathProvider: @escaping () -> String? = {
            Bundle.main.executablePath ?? CommandLine.arguments.first
        },
        launchctl: @escaping ([String]) throws -> Void = LoginItemManager.runLaunchctl
    ) {
        self.settings = settings
        self.fileManager = fileManager
        self.plistURL = plistURL
        self.binaryPathProvider = binaryPathProvider
        self.launchctl = launchctl

        syncToSettings()

        settings.$startAtLogin
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                self?.updateStartAtLogin(isEnabled)
            }
            .store(in: &cancellables)
    }

    func enable() throws {
        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plistContents = try launchAgentPlist(binaryPath: currentBinaryPath())
        try plistContents.write(to: plistURL, atomically: true, encoding: .utf8)
        try launchctl(["load", plistURL.path])
    }

    func disable() throws {
        guard isEnabled else {
            return
        }

        var unloadError: Error?

        do {
            try launchctl(["unload", plistURL.path])
        } catch {
            unloadError = error
        }

        try fileManager.removeItem(at: plistURL)

        if let unloadError {
            throw unloadError
        }
    }

    private func syncToSettings() {
        if settings.startAtLogin && !isEnabled {
            updateStartAtLogin(true)
        } else if !settings.startAtLogin && isEnabled {
            updateStartAtLogin(false)
        }
    }

    private func updateStartAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try enable()
            } else {
                try disable()
            }
        } catch {
            let action = isEnabled ? "enable" : "disable"
            print("DeskBar: Failed to \(action) start at login: \(error)")
        }
    }

    private func currentBinaryPath() throws -> String {
        guard let binaryPath = binaryPathProvider(), !binaryPath.isEmpty else {
            throw LoginItemManagerError.missingBinaryPath
        }

        return binaryPath
    }

    private func launchAgentPlist(binaryPath: String) -> String {
        let escapedBinaryPath = xmlEscaped(binaryPath)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.deskbar.app</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escapedBinaryPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func runLaunchctl(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw LoginItemManagerError.launchctlFailed(
                arguments: arguments,
                status: process.terminationStatus
            )
        }
    }
}
