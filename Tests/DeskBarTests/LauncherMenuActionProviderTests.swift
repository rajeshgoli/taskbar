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

@Test
func launcherMenuActionProviderMatchesKnownCommandsByAXShortcutAttributes() {
    #expect(
        LauncherMenuActionProvider.launcherActionIdentifier(
            bundleIdentifier: "com.google.Chrome",
            commandCharacter: "n",
            commandModifiers: 0,
            title: "Localized window title"
        ) == "newWindow"
    )
    #expect(
        LauncherMenuActionProvider.launcherActionIdentifier(
            bundleIdentifier: "com.google.Chrome",
            commandCharacter: "N",
            commandModifiers: 1,
            title: "Localized private title"
        ) == "newPrivateWindow"
    )
}

@Test
func launcherMenuActionProviderDoesNotTreatFinderNewFolderAsLauncherAction() {
    #expect(
        LauncherMenuActionProvider.launcherActionIdentifier(
            bundleIdentifier: LauncherActivationPlanner.finderBundleIdentifier,
            commandCharacter: "N",
            commandModifiers: 1,
            title: "New Folder"
        ) == nil
    )
}

@Test
func launcherMenuActionProviderStillMatchesEnglishTitlesWhenShortcutsAreCustomized() {
    #expect(
        LauncherMenuActionProvider.launcherActionIdentifier(
            bundleIdentifier: "com.apple.Safari",
            commandCharacter: "T",
            commandModifiers: 0,
            title: "New Private Window"
        ) == "newPrivateWindow"
    )
}
