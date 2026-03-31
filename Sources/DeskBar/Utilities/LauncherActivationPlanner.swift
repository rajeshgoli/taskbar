enum LauncherActivationAction: Equatable {
    case launchApplication
    case activateMostRecentWindow
    case activateApplication
    case openFinderWindow
}

enum LauncherActivationPlanner {
    static let finderBundleIdentifier = "com.apple.finder"

    static func action(
        bundleIdentifier: String,
        isRunning: Bool,
        hasVisibleLocalWindows: Bool,
        hasAnyWindows: Bool
    ) -> LauncherActivationAction {
        if hasVisibleLocalWindows {
            return .activateMostRecentWindow
        }

        if bundleIdentifier == finderBundleIdentifier {
            return hasAnyWindows ? .activateApplication : .openFinderWindow
        }

        return isRunning ? .activateApplication : .launchApplication
    }
}
