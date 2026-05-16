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

        if hasAnyWindows == false {
            return .reopenApplication
        }

        return .activateApplication
    }
}
