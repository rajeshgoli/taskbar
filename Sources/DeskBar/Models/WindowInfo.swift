import AppKit

struct WindowInfo: Equatable, Identifiable {
    let pid: pid_t
    let cgWindowID: CGWindowID?
    let provisionalID: String?
    let appName: String
    let title: String
    let icon: NSImage?
    let bundleIdentifier: String?
    let isMinimized: Bool
    let isHidden: Bool
    let isProvisional: Bool

    init(
        pid: pid_t,
        cgWindowID: CGWindowID? = nil,
        provisionalID: String? = nil,
        appName: String,
        title: String = "",
        icon: NSImage?,
        bundleIdentifier: String?,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        isProvisional: Bool = false
    ) {
        self.pid = pid
        self.cgWindowID = cgWindowID
        self.provisionalID = provisionalID
        self.appName = appName
        self.title = title
        self.icon = icon
        self.bundleIdentifier = bundleIdentifier
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.isProvisional = isProvisional
    }

    var id: String {
        if let cgWindowID {
            return "\(pid)-\(cgWindowID)"
        }

        return provisionalID ?? "\(pid)-\(appName)"
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.pid == rhs.pid &&
            lhs.cgWindowID == rhs.cgWindowID &&
            lhs.provisionalID == rhs.provisionalID &&
            lhs.appName == rhs.appName &&
            lhs.title == rhs.title &&
            lhs.bundleIdentifier == rhs.bundleIdentifier &&
            lhs.isMinimized == rhs.isMinimized &&
            lhs.isHidden == rhs.isHidden &&
            lhs.isProvisional == rhs.isProvisional
    }
}
