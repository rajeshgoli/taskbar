import Foundation
import Testing
@testable import DeskBar

struct TaskbarSettingsTests {
    @Test
    func showOnAllMonitorsDefaultsToTrue() {
        let suiteName = "TaskbarSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = TaskbarSettings(defaults: defaults)

        #expect(settings.showOnAllMonitors)
        #expect(settings.groupingMode == .never)
        #expect(settings.flashAttentionIndicators)
        #expect(settings.showProgressIndicators)
        #expect(settings.enableActivityMode)
    }

    @Test
    func migratesLegacyGroupByAppSetting() {
        let suiteName = "TaskbarSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "groupByApp")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = TaskbarSettings(defaults: defaults)

        #expect(settings.groupingMode == .always)
    }
}
