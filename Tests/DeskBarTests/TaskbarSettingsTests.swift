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
    }
}
