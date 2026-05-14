import Testing
@testable import DeskBar

@Test
func launcherMenuActionProviderUsesChromeFallbackActions() {
    #expect(
        LauncherMenuActionProvider.fallbackActionTitles(bundleIdentifier: "com.google.Chrome") == [
            "New Window",
            "New Incognito Window",
        ]
    )
}

@Test
func launcherMenuActionProviderUsesSafariFallbackActions() {
    #expect(
        LauncherMenuActionProvider.fallbackActionTitles(bundleIdentifier: "com.apple.Safari") == [
            "New Window",
            "New Private Window",
        ]
    )
}

@Test
func launcherMenuActionProviderUsesFinderFallbackAction() {
    #expect(
        LauncherMenuActionProvider.fallbackActionTitles(
            bundleIdentifier: LauncherActivationPlanner.finderBundleIdentifier
        ) == ["New Finder Window"]
    )
}

@Test
func launcherMenuActionProviderOmitsFallbackActionsForUnknownApps() {
    #expect(LauncherMenuActionProvider.fallbackActionTitles(bundleIdentifier: "com.example.Unknown") == [])
}
