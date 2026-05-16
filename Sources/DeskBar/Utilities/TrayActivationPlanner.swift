enum TrayActivationAction: Equatable {
    case activateApplication
    case reopenApplication
    case openFinderWindow
}

enum TrayActivationPlanner {
    static func action(
        bundleIdentifier: String?,
        hasAnyWindows: Bool?
    ) -> TrayActivationAction {
        if bundleIdentifier == LauncherActivationPlanner.finderBundleIdentifier {
            return .openFinderWindow
        }

        guard bundleIdentifier != nil else {
            return .activateApplication
        }

        return hasAnyWindows == false ? .reopenApplication : .activateApplication
    }
}
