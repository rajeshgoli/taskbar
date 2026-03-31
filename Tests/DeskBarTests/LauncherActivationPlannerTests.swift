import Testing
@testable import DeskBar

@Test
func launcherActivationPlannerLaunchesNonRunningApps() {
    #expect(
        LauncherActivationPlanner.action(
            bundleIdentifier: "com.example.alpha",
            isRunning: false,
            hasVisibleLocalWindows: false,
            hasAnyWindows: nil
        ) == .launchApplication
    )
}

@Test
func launcherActivationPlannerActivatesVisibleWindows() {
    #expect(
        LauncherActivationPlanner.action(
            bundleIdentifier: "com.example.alpha",
            isRunning: true,
            hasVisibleLocalWindows: true,
            hasAnyWindows: true
        ) == .activateMostRecentWindow
    )
}

@Test
func launcherActivationPlannerActivatesRunningAppsWithoutLocalWindows() {
    #expect(
        LauncherActivationPlanner.action(
            bundleIdentifier: "com.example.alpha",
            isRunning: true,
            hasVisibleLocalWindows: false,
            hasAnyWindows: true
        ) == .activateApplication
    )
}

@Test
func launcherActivationPlannerOpensFinderWindowWhenFinderHasNoWindows() {
    #expect(
        LauncherActivationPlanner.action(
            bundleIdentifier: LauncherActivationPlanner.finderBundleIdentifier,
            isRunning: true,
            hasVisibleLocalWindows: false,
            hasAnyWindows: false
        ) == .openFinderWindow
    )
}

@Test
func launcherActivationPlannerActivatesFinderWhenWindowsExistElsewhere() {
    #expect(
        LauncherActivationPlanner.action(
            bundleIdentifier: LauncherActivationPlanner.finderBundleIdentifier,
            isRunning: true,
            hasVisibleLocalWindows: false,
            hasAnyWindows: true
        ) == .activateApplication
    )
}

@Test
func launcherActivationPlannerDoesNotOpenFinderWindowWhenWindowStateIsUnknown() {
    #expect(
        LauncherActivationPlanner.action(
            bundleIdentifier: LauncherActivationPlanner.finderBundleIdentifier,
            isRunning: true,
            hasVisibleLocalWindows: false,
            hasAnyWindows: nil
        ) == .activateApplication
    )
}
