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
        #expect(settings.layoutMode == .fullWidth)
        #expect(settings.enableWindowSwitcher)
        #expect(settings.enableBareCommandLauncher)
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

    @Test
    func persistsLayoutAndShortcutSettings() {
        let suiteName = "TaskbarSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var settings = TaskbarSettings(defaults: defaults)
        settings.layoutMode = .fullWidthGlass
        settings.enableWindowSwitcher = false
        settings.enableBareCommandLauncher = false

        settings = TaskbarSettings(defaults: defaults)

        #expect(settings.layoutMode == .fullWidthGlass)
        #expect(settings.enableWindowSwitcher == false)
        #expect(settings.enableBareCommandLauncher == false)
    }

    @Test
    func resetAppearanceSlidersRestoresDefaults() {
        let suiteName = "TaskbarSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var settings = TaskbarSettings(defaults: defaults)
        settings.taskbarHeight = 60
        settings.titleFontSize = 18
        settings.maxTaskWidth = 400
        settings.thumbnailSize = 400

        settings.resetAppearanceSlidersToDefaults()

        #expect(settings.taskbarHeight == TaskbarSettings.defaultTaskbarHeight)
        #expect(settings.titleFontSize == TaskbarSettings.defaultTitleFontSize)
        #expect(settings.maxTaskWidth == TaskbarSettings.defaultMaxTaskWidth)
        #expect(settings.thumbnailSize == TaskbarSettings.defaultThumbnailSize)

        settings = TaskbarSettings(defaults: defaults)

        #expect(settings.taskbarHeight == TaskbarSettings.defaultTaskbarHeight)
        #expect(settings.titleFontSize == TaskbarSettings.defaultTitleFontSize)
        #expect(settings.maxTaskWidth == TaskbarSettings.defaultMaxTaskWidth)
        #expect(settings.thumbnailSize == TaskbarSettings.defaultThumbnailSize)
    }
}
