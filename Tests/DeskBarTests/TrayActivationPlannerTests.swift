import Testing
@testable import DeskBar

@Test
func trayActivationPlannerActivatesApplicationsWithWindows() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: "com.example.alpha",
            hasAnyWindows: true
        ) == .activateApplication
    )
}

@Test
func trayActivationPlannerReopensApplicationsWithoutWindows() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: "com.example.alpha",
            hasAnyWindows: false
        ) == .reopenApplication
    )
}

@Test
func trayActivationPlannerActivatesWhenWindowStateIsUnknown() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: "com.example.alpha",
            hasAnyWindows: nil
        ) == .activateApplication
    )
}

@Test
func trayActivationPlannerOpensFinderWindow() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: LauncherActivationPlanner.finderBundleIdentifier,
            hasAnyWindows: true
        ) == .openFinderWindow
    )
}
