import AppKit

struct WindowInfo: Identifiable, Equatable {
    let id: UUID = UUID()
    let pid: pid_t
    var appName: String
    var icon: NSImage?
    var bundleIdentifier: String?

    // Phase 2+ fields — declared with defaults, populated later
    var windowTitle: String = ""
    var cgWindowID: CGWindowID = 0
    var axElement: AXUIElement?
    var isMinimized: Bool = false
    var isHidden: Bool = false
    var isActive: Bool = false
    var bounds: CGRect = .zero
    var isProvisional: Bool = false

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
}
