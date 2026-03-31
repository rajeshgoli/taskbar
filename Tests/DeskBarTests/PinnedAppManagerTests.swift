import Foundation
import Testing
@testable import DeskBar

@Test
func pinnedAppManagerPersistsOrderedApps() {
    let suiteName = "PinnedAppManagerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let manager = PinnedAppManager(defaults: defaults)
    manager.pin(bundleIdentifier: "com.example.alpha", name: "Alpha")
    manager.pin(bundleIdentifier: "com.example.beta", name: "Beta")
    manager.reorder(from: 1, to: 0)

    let reloadedManager = PinnedAppManager(defaults: defaults)

    #expect(reloadedManager.pinnedApps.map(\.bundleIdentifier) == ["com.example.beta", "com.example.alpha"])
    #expect(reloadedManager.pinnedApps.map(\.name) == ["Beta", "Alpha"])
    #expect(reloadedManager.isPinned(bundleIdentifier: "com.example.beta"))
    #expect(storedPinnedAppsJSON(from: defaults)?.contains(#""iconData""#) == false)
}

@Test
func pinnedAppManagerUnpinsApps() {
    let suiteName = "PinnedAppManagerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let manager = PinnedAppManager(defaults: defaults)
    manager.pin(bundleIdentifier: "com.example.alpha", name: "Alpha")
    manager.unpin(bundleIdentifier: "com.example.alpha")

    #expect(manager.pinnedApps.isEmpty)
    #expect(!manager.isPinned(bundleIdentifier: "com.example.alpha"))
}

@Test
func pinnedAppManagerMigratesLegacyIconPayloads() throws {
    let suiteName = "PinnedAppManagerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let legacyPinnedApps = [
        LegacyPinnedAppFixture(
            bundleIdentifier: "com.example.alpha",
            name: "Alpha",
            iconData: Data(repeating: 0xAB, count: 1024)
        )
    ]
    let legacyData = try JSONEncoder().encode(legacyPinnedApps)
    defaults.set(legacyData, forKey: "pinnedApps")

    let manager = PinnedAppManager(defaults: defaults)
    let rewrittenData = try #require(defaults.data(forKey: "pinnedApps"))
    let rewrittenJSON = try #require(String(data: rewrittenData, encoding: .utf8))

    #expect(manager.pinnedApps.map(\.bundleIdentifier) == ["com.example.alpha"])
    #expect(manager.pinnedApps.map(\.name) == ["Alpha"])
    #expect(rewrittenData.count < legacyData.count)
    #expect(!rewrittenJSON.contains(#""iconData""#))
}

@Test
func pinnedAppManagerDoesNotRewriteMalformedLegacyPayloads() {
    let suiteName = "PinnedAppManagerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let malformedLegacyData = Data(#"[{"bundleIdentifier":"com.example.alpha","name":"Alpha","iconData":"oops"}"#.utf8)
    defaults.set(malformedLegacyData, forKey: "pinnedApps")

    let manager = PinnedAppManager(defaults: defaults)

    #expect(manager.pinnedApps.isEmpty)
    #expect(defaults.data(forKey: "pinnedApps") == malformedLegacyData)
}

private struct LegacyPinnedAppFixture: Encodable {
    let bundleIdentifier: String
    let name: String
    let iconData: Data
}

private func storedPinnedAppsJSON(from defaults: UserDefaults) -> String? {
    guard let data = defaults.data(forKey: "pinnedApps") else {
        return nil
    }

    return String(data: data, encoding: .utf8)
}
