import Testing
@testable import DeskBar

@Test
func trayActivationPlannerActivatesBundledApplicationsWithWindows() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: "com.example.alpha",
            hasAnyWindows: true
        ) == .activateApplication
    )
}

@Test
func trayActivationPlannerReopensBundledApplicationsWithoutWindows() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: "com.example.alpha",
            hasAnyWindows: false
        ) == .reopenApplication
    )
}

@Test
func trayActivationPlannerActivatesUnbundledApplications() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: nil,
            hasAnyWindows: false
        ) == .activateApplication
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
