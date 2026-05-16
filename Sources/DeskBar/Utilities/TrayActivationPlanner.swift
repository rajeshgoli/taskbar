enum TrayActivationAction: Equatable {
    case activateApplication
    case reopenApplication
    case openFinderWindow
}

enum TrayActivationPlanner {
    static func action(
        bundleIdentifier: String?
    ) -> TrayActivationAction {
        if bundleIdentifier == LauncherActivationPlanner.finderBundleIdentifier {
            return .openFinderWindow
        }

        return bundleIdentifier == nil ? .activateApplication : .reopenApplication
    }
}
