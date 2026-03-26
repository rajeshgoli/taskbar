import Foundation
import Testing
@testable import DeskBar

@MainActor
struct BlacklistManagerTests {
    @Test
    func addPersistsAndPostsNotification() async throws {
        let defaults = UserDefaults(suiteName: "com.deskbar.app")!
        defaults.removeObject(forKey: "blacklistedApps")

        let manager = BlacklistManager()
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: BlacklistManager.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            defaults.removeObject(forKey: "blacklistedApps")
        }

        manager.add(bundleIdentifier: "com.example.app")

        #expect(manager.isBlacklisted(bundleIdentifier: "com.example.app"))
        #expect(Set(defaults.stringArray(forKey: "blacklistedApps") ?? []) == Set(["com.example.app"]))
        #expect(notificationCount == 1)
    }

    @Test
    func removePersistsAndPostsNotification() async throws {
        let defaults = UserDefaults(suiteName: "com.deskbar.app")!
        defaults.set(["com.example.app"], forKey: "blacklistedApps")

        let manager = BlacklistManager()
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: BlacklistManager.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            defaults.removeObject(forKey: "blacklistedApps")
        }

        manager.remove(bundleIdentifier: "com.example.app")

        #expect(!manager.isBlacklisted(bundleIdentifier: "com.example.app"))
        #expect((defaults.stringArray(forKey: "blacklistedApps") ?? []).isEmpty)
        #expect(notificationCount == 1)
    }
}
