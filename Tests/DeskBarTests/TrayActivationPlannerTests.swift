import Testing
@testable import DeskBar

@Test
func trayActivationPlannerReopensBundledApplications() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: "com.example.alpha"
        ) == .reopenApplication
    )
}

@Test
func trayActivationPlannerActivatesUnbundledApplications() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: nil
        ) == .activateApplication
    )
}

@Test
func trayActivationPlannerOpensFinderWindow() {
    #expect(
        TrayActivationPlanner.action(
            bundleIdentifier: LauncherActivationPlanner.finderBundleIdentifier
        ) == .openFinderWindow
    )
}
