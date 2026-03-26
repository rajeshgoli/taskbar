import AppKit

struct WindowInfo {
    let pid: pid_t
    var appName: String
    var icon: NSImage?
    var bundleIdentifier: String?
    var windowTitle: String = ""
    var cgWindowID: CGWindowID = 0
    var isMinimized: Bool = false
    var isHidden: Bool = false
    var isActive: Bool = false
    var bounds: CGRect = .zero
    var isProvisional: Bool = false
}
