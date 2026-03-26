import AppKit

struct WindowInfo {
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let bundleIdentifier: String?
}
