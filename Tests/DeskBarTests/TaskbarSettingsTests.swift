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
        #expect(settings.showSystemResourceWidget)
        #expect(settings.showSystemResourceMemoryMetric)
        #expect(settings.showSystemResourceCPUMetric)
        #expect(settings.showSystemResourceGPUMetric)
        #expect(settings.systemResourceWidgetCollapsed == false)
        #expect(settings.systemResourceWidgetPinnedDisplayID == nil)
        #expect(settings.layoutMode == .fullWidth)
        #expect(settings.enableWindowSwitcher)
        #expect(settings.enableBareCommandLauncher)
        #expect(settings.appsLauncherShortcut == .controlOptionReturn)
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
        settings.appsLauncherShortcut = .optionSpace
        settings.showSystemResourceWidget = false
        settings.showSystemResourceMemoryMetric = false
        settings.showSystemResourceCPUMetric = false
        settings.showSystemResourceGPUMetric = true
        settings.systemResourceWidgetCollapsed = true
        settings.systemResourceWidgetPinnedDisplayID = 12345

        settings = TaskbarSettings(defaults: defaults)

        #expect(settings.layoutMode == .fullWidthGlass)
        #expect(settings.enableWindowSwitcher == false)
        #expect(settings.enableBareCommandLauncher == false)
        #expect(settings.appsLauncherShortcut == .optionSpace)
        #expect(settings.showSystemResourceWidget == false)
        #expect(settings.showSystemResourceMemoryMetric == false)
        #expect(settings.showSystemResourceCPUMetric == false)
        #expect(settings.showSystemResourceGPUMetric)
        #expect(settings.systemResourceWidgetCollapsed)
        #expect(settings.systemResourceWidgetPinnedDisplayID == 12345)

        settings.systemResourceWidgetPinnedDisplayID = nil
        settings = TaskbarSettings(defaults: defaults)

        #expect(settings.systemResourceWidgetPinnedDisplayID == nil)
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
