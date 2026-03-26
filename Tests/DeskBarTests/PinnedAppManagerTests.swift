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
