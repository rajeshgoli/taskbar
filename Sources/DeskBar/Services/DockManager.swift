import Darwin
import Foundation

final class DockManager {
    private struct DockPriorState: Codable {
        let autohide: Bool
        let autohideDelay: Double
        let timestamp: Date

        enum CodingKeys: String, CodingKey {
            case autohide
            case autohideDelay = "autohide-delay"
            case timestamp
        }
    }

    private struct ProcessFailure: LocalizedError {
        let executable: String
        let arguments: [String]
        let output: String

        var errorDescription: String? {
            let renderedArguments = arguments.joined(separator: " ")
            let renderedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)

            if renderedOutput.isEmpty {
                return "\(executable) \(renderedArguments) exited with a non-zero status"
            }

            return "\(executable) \(renderedArguments) failed: \(renderedOutput)"
        }
    }

    private let fileManager: FileManager
    private let configDirectoryURL: URL
    private let stateFileURL: URL
    private let watchdogScriptURL: URL
    private let launchAgentURL: URL
    private let launchAgentLabel = "com.deskbar.dock-watchdog"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        configDirectoryURL = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("deskbar", isDirectory: true)
        stateFileURL = configDirectoryURL.appendingPathComponent("dock-prior-state.json")
        watchdogScriptURL = configDirectoryURL.appendingPathComponent("dock-watchdog.sh")
        launchAgentURL = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    func apply(mode: DockMode) {
        switch mode {
        case .independent:
            restoreDockState()

            if !fileManager.fileExists(atPath: stateFileURL.path) {
                removeWatchdog()
            }
        case .autoHide:
            let hadPriorState = fileManager.fileExists(atPath: stateFileURL.path)

            guard ensurePriorStateCaptured() else {
                return
            }

            let priorDelay = hadPriorState ? readPriorState()?.autohideDelay : nil
            guard updateDock(autohide: true, autohideDelay: priorDelay) else {
                return
            }

            installWatchdog()
        case .hidden:
            guard ensurePriorStateCaptured() else {
                return
            }

            guard updateDock(autohide: true, autohideDelay: 1000) else {
                return
            }

            installWatchdog()
        }
    }

    func restoreDockState() {
        guard let priorState = readPriorState() else {
            return
        }

        guard updateDock(
            autohide: priorState.autohide,
            autohideDelay: priorState.autohideDelay
        ) else {
            return
        }

        do {
            try fileManager.removeItem(at: stateFileURL)
        } catch {
            print("DeskBar: failed to delete Dock prior state file: \(error)")
        }
    }

    func installWatchdog() {
        do {
            try ensureConfigDirectory()
            try ensureLaunchAgentsDirectory()
            try writeWatchdogScript()
            try writeLaunchAgentPlist()
            reloadLaunchAgent()
        } catch {
            print("DeskBar: failed to install Dock watchdog: \(error)")
        }
    }

    func removeWatchdog() {
        unloadLaunchAgent()

        do {
            if fileManager.fileExists(atPath: launchAgentURL.path) {
                try fileManager.removeItem(at: launchAgentURL)
            }

            if fileManager.fileExists(atPath: watchdogScriptURL.path) {
                try fileManager.removeItem(at: watchdogScriptURL)
            }
        } catch {
            print("DeskBar: failed to remove Dock watchdog files: \(error)")
        }
    }

    private func ensurePriorStateCaptured() -> Bool {
        if fileManager.fileExists(atPath: stateFileURL.path) {
            return true
        }

        let priorState = DockPriorState(
            autohide: readDockAutohideValue() ?? false,
            autohideDelay: readDockAutohideDelayValue() ?? 0,
            timestamp: Date()
        )

        do {
            try ensureConfigDirectory()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(priorState)
            try data.write(to: stateFileURL, options: .atomic)
            return true
        } catch {
            print("DeskBar: failed to save Dock prior state: \(error)")
            return false
        }
    }

    private func readPriorState() -> DockPriorState? {
        guard fileManager.fileExists(atPath: stateFileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: stateFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DockPriorState.self, from: data)
        } catch {
            print("DeskBar: failed to read Dock prior state: \(error)")
            return nil
        }
    }

    private func readDockAutohideValue() -> Bool? {
        guard let output = try? runProcess(
            executable: "/usr/bin/defaults",
            arguments: ["read", "com.apple.dock", "autohide"]
        ) else {
            return nil
        }

        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    private func readDockAutohideDelayValue() -> Double? {
        guard let output = try? runProcess(
            executable: "/usr/bin/defaults",
            arguments: ["read", "com.apple.dock", "autohide-delay"]
        ) else {
            return nil
        }

        return Double(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    private func updateDock(autohide: Bool, autohideDelay: Double?) -> Bool {
        do {
            _ = try runProcess(
                executable: "/usr/bin/defaults",
                arguments: ["write", "com.apple.dock", "autohide", "-bool", autohide ? "true" : "false"]
            )

            if let autohideDelay {
                _ = try runProcess(
                    executable: "/usr/bin/defaults",
                    arguments: [
                        "write",
                        "com.apple.dock",
                        "autohide-delay",
                        "-float",
                        String(autohideDelay)
                    ]
                )
            }

            _ = try runProcess(executable: "/usr/bin/killall", arguments: ["Dock"])
            return true
        } catch {
            print("DeskBar: failed to update Dock preferences: \(error)")
            return false
        }
    }

    private func ensureConfigDirectory() throws {
        try fileManager.createDirectory(
            at: configDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func ensureLaunchAgentsDirectory() throws {
        let launchAgentsDirectoryURL = launchAgentURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: launchAgentsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func writeWatchdogScript() throws {
        let script = """
        #!/bin/zsh
        set -euo pipefail

        STATE_FILE=\(shellQuoted(stateFileURL.path))

        if [[ ! -f "$STATE_FILE" ]]; then
          exit 0
        fi

        if /usr/bin/pgrep -x \(shellQuoted("DeskBar")) >/dev/null 2>&1; then
          exit 0
        fi

        AUTOHIDE=$(/usr/bin/python3 - "$STATE_FILE" <<'PY'
        import json
        import sys

        with open(sys.argv[1], "r", encoding="utf-8") as handle:
            state = json.load(handle)

        print("true" if state.get("autohide") else "false")
        PY
        )

        AUTOHIDE_DELAY=$(/usr/bin/python3 - "$STATE_FILE" <<'PY'
        import json
        import sys

        with open(sys.argv[1], "r", encoding="utf-8") as handle:
            state = json.load(handle)

        print(state.get("autohide-delay", 0))
        PY
        )

        /usr/bin/defaults write com.apple.dock autohide -bool "$AUTOHIDE"
        /usr/bin/defaults write com.apple.dock autohide-delay -float "$AUTOHIDE_DELAY"
        /usr/bin/killall Dock >/dev/null 2>&1 || true
        /bin/rm -f "$STATE_FILE"
        """

        try script.write(to: watchdogScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: watchdogScriptURL.path
        )
    }

    private func writeLaunchAgentPlist() throws {
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/bin/zsh", watchdogScriptURL.path],
            "RunAtLoad": true,
            "StartInterval": 30
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private func reloadLaunchAgent() {
        let domain = "gui/\(getuid())"
        _ = try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootout", domain, launchAgentURL.path]
        )

        do {
            _ = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["bootstrap", domain, launchAgentURL.path]
            )
        } catch {
            print("DeskBar: failed to load Dock watchdog LaunchAgent: \(error)")
        }
    }

    private func unloadLaunchAgent() {
        let domain = "gui/\(getuid())"
        _ = try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootout", domain, launchAgentURL.path]
        )
    }

    private func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw ProcessFailure(
                executable: executable,
                arguments: arguments,
                output: stderr.isEmpty ? stdout : stderr
            )
        }

        return stdout
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
