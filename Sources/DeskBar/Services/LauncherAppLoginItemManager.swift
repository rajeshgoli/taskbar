import Foundation

final class LauncherAppLoginItemManager {
    private let fileManager: FileManager
    private let launchAgentsDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        launchAgentsDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.launchAgentsDirectoryURL = launchAgentsDirectoryURL
    }

    func isEnabled(bundleIdentifier: String) -> Bool {
        fileManager.fileExists(atPath: plistURL(for: bundleIdentifier).path)
    }

    func setEnabled(_ enabled: Bool, bundleIdentifier: String) throws {
        if enabled {
            try enable(bundleIdentifier: bundleIdentifier)
        } else {
            try disable(bundleIdentifier: bundleIdentifier)
        }
    }

    func plistURL(for bundleIdentifier: String) -> URL {
        launchAgentsDirectoryURL.appendingPathComponent("\(Self.label(for: bundleIdentifier)).plist")
    }

    func plistContents(bundleIdentifier: String) -> String {
        let escapedLabel = xmlEscaped(Self.label(for: bundleIdentifier))
        let escapedBundleIdentifier = xmlEscaped(bundleIdentifier)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(escapedLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-b</string>
                <string>\(escapedBundleIdentifier)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }

    static func label(for bundleIdentifier: String) -> String {
        let sanitized = bundleIdentifier.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" ? character : "-"
        }

        return "com.deskbar.launcher-login.\(String(sanitized))"
    }

    private func enable(bundleIdentifier: String) throws {
        try fileManager.createDirectory(
            at: launchAgentsDirectoryURL,
            withIntermediateDirectories: true
        )

        try plistContents(bundleIdentifier: bundleIdentifier).write(
            to: plistURL(for: bundleIdentifier),
            atomically: true,
            encoding: .utf8
        )
    }

    private func disable(bundleIdentifier: String) throws {
        let plistURL = plistURL(for: bundleIdentifier)
        guard fileManager.fileExists(atPath: plistURL.path) else {
            return
        }

        try fileManager.removeItem(at: plistURL)
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
