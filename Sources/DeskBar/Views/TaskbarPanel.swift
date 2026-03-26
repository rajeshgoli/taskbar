import AppKit

class TaskbarPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    func setContentSubview(_ view: NSView) {
        contentView = view
    }
}
