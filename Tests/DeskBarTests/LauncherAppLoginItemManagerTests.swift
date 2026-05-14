import Foundation
import Testing
@testable import DeskBar

@Test
func launcherAppLoginItemManagerWritesLaunchAgentPlist() throws {
    let fileManager = FileManager.default
    let launchAgentsDirectoryURL = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("LaunchAgents", isDirectory: true)
    defer {
        try? fileManager.removeItem(at: launchAgentsDirectoryURL.deletingLastPathComponent())
    }

    let manager = LauncherAppLoginItemManager(
        fileManager: fileManager,
        launchAgentsDirectoryURL: launchAgentsDirectoryURL
    )

    try manager.setEnabled(true, bundleIdentifier: "com.google.Chrome")

    let plistURL = manager.plistURL(for: "com.google.Chrome")
    let plistContents = try String(contentsOf: plistURL, encoding: .utf8)

    #expect(manager.isEnabled(bundleIdentifier: "com.google.Chrome"))
    #expect(plistURL.lastPathComponent == "com.deskbar.launcher-login.com.google.Chrome.plist")
    #expect(plistContents.contains("<string>com.deskbar.launcher-login.com.google.Chrome</string>"))
    #expect(plistContents.contains("<string>/usr/bin/open</string>"))
    #expect(plistContents.contains("<string>-b</string>"))
    #expect(plistContents.contains("<string>com.google.Chrome</string>"))
    #expect(plistContents.contains("<key>RunAtLoad</key>"))
}

@Test
func launcherAppLoginItemManagerRemovesLaunchAgentPlist() throws {
    let fileManager = FileManager.default
    let launchAgentsDirectoryURL = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("LaunchAgents", isDirectory: true)
    defer {
        try? fileManager.removeItem(at: launchAgentsDirectoryURL.deletingLastPathComponent())
    }

    let manager = LauncherAppLoginItemManager(
        fileManager: fileManager,
        launchAgentsDirectoryURL: launchAgentsDirectoryURL
    )

    try manager.setEnabled(true, bundleIdentifier: "com.example.App")
    try manager.setEnabled(false, bundleIdentifier: "com.example.App")

    #expect(!manager.isEnabled(bundleIdentifier: "com.example.App"))
}

@Test
func launcherAppLoginItemManagerSanitizesLaunchAgentLabel() {
    #expect(
        LauncherAppLoginItemManager.label(for: "com.example.App Helper") ==
            "com.deskbar.launcher-login.com.example.App-Helper"
    )
}
