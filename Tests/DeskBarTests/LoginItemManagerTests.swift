import Foundation
import Testing
@testable import DeskBar

@MainActor
struct LoginItemManagerTests {
    @Test
    func enableWritesLaunchAgentPlistAndLoadsIt() throws {
        let suiteName = "LoginItemManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let fileManager = FileManager.default
        let plistURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("com.deskbar.app.plist")
        var launchctlCalls: [[String]] = []

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? fileManager.removeItem(at: plistURL.deletingLastPathComponent())
        }

        let settings = TaskbarSettings(defaults: defaults)
        let manager = LoginItemManager(
            settings: settings,
            fileManager: fileManager,
            plistURL: plistURL,
            binaryPathProvider: { "/Applications/DeskBar.app/Contents/MacOS/DeskBar" },
            launchctl: { launchctlCalls.append($0) }
        )

        try manager.enable()

        let plistContents = try String(contentsOf: plistURL, encoding: .utf8)

        #expect(manager.isEnabled)
        #expect(launchctlCalls == [["load", plistURL.path]])
        #expect(plistContents == """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.deskbar.app</string>
            <key>ProgramArguments</key>
            <array>
                <string>/Applications/DeskBar.app/Contents/MacOS/DeskBar</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """)
    }

    @Test
    func disableUnloadsLaunchAgentAndDeletesPlist() throws {
        let suiteName = "LoginItemManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let fileManager = FileManager.default
        let plistURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("com.deskbar.app.plist")
        var launchctlCalls: [[String]] = []

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? fileManager.removeItem(at: plistURL.deletingLastPathComponent())
        }

        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "placeholder".write(to: plistURL, atomically: true, encoding: .utf8)
        defaults.set(true, forKey: "startAtLogin")

        let settings = TaskbarSettings(defaults: defaults)
        let manager = LoginItemManager(
            settings: settings,
            fileManager: fileManager,
            plistURL: plistURL,
            binaryPathProvider: { "/Applications/DeskBar.app/Contents/MacOS/DeskBar" },
            launchctl: { launchctlCalls.append($0) }
        )

        try manager.disable()

        #expect(!manager.isEnabled)
        #expect(launchctlCalls == [["unload", plistURL.path]])
        #expect(!fileManager.fileExists(atPath: plistURL.path))
    }

    @Test
    func startAtLoginChangesEnableAndDisableLaunchAgent() throws {
        let suiteName = "LoginItemManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let fileManager = FileManager.default
        let plistURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("com.deskbar.app.plist")
        var launchctlCalls: [[String]] = []

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? fileManager.removeItem(at: plistURL.deletingLastPathComponent())
        }

        let settings = TaskbarSettings(defaults: defaults)
        let manager = LoginItemManager(
            settings: settings,
            fileManager: fileManager,
            plistURL: plistURL,
            binaryPathProvider: { "/Applications/DeskBar.app/Contents/MacOS/DeskBar" },
            launchctl: { launchctlCalls.append($0) }
        )
        _ = manager

        settings.startAtLogin = true
        #expect(fileManager.fileExists(atPath: plistURL.path))

        settings.startAtLogin = false
        #expect(!fileManager.fileExists(atPath: plistURL.path))
        #expect(launchctlCalls == [
            ["load", plistURL.path],
            ["unload", plistURL.path],
        ])
    }
}
