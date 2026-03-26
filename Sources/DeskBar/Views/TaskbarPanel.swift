import AppKit

final class TaskbarPanel: NSPanel {
    private static let taskbarHeight: CGFloat = 44
    private static let bannerHeight: CGFloat = 32

    private let permissionsManager: PermissionsManager
    private let visualEffectView: NSVisualEffectView
    private weak var hostedView: NSView?

    init(permissionsManager: PermissionsManager) {
        self.permissionsManager = permissionsManager

        let frame = Self.panelFrame(
            isAccessibilityGranted: permissionsManager.isAccessibilityGranted,
            screen: NSScreen.main ?? NSScreen.screens.first
        )

        visualEffectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isMovableByWindowBackground = false
        isOpaque = false
        hasShadow = true

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.autoresizingMask = [.width, .height]
        contentView = visualEffectView
    }

    func setContentSubview(_ view: NSView) {
        hostedView?.removeFromSuperview()
        view.frame = visualEffectView.bounds
        view.autoresizingMask = [.width, .height]
        visualEffectView.addSubview(view)
        hostedView = view
    }

    func updateForAccessibilityPermissionChange() {
        let nextFrame = Self.panelFrame(
            isAccessibilityGranted: permissionsManager.isAccessibilityGranted,
            screen: screen ?? NSScreen.main ?? NSScreen.screens.first
        )

        setFrame(nextFrame, display: true, animate: true)
        visualEffectView.frame = NSRect(origin: .zero, size: nextFrame.size)
    }

    private static func panelFrame(
        isAccessibilityGranted: Bool,
        screen: NSScreen?
    ) -> NSRect {
        guard let screen else {
            return .zero
        }

        let height = taskbarHeight + (isAccessibilityGranted ? 0 : bannerHeight)
        return NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y,
            width: screen.frame.width,
            height: height
        )
    }
}
