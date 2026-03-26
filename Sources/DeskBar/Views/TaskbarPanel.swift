import AppKit
import Combine

final class TaskbarPanel: NSPanel {
    private static let bannerHeight: CGFloat = 32

    private let permissionsManager: PermissionsManager
    private let settings: TaskbarSettings
    private let visualEffectView: NSVisualEffectView
    private weak var hostedView: NSView?
    private var cancellables = Set<AnyCancellable>()

    init(permissionsManager: PermissionsManager, settings: TaskbarSettings) {
        self.permissionsManager = permissionsManager
        self.settings = settings

        let frame = Self.panelFrame(
            isAccessibilityGranted: permissionsManager.isAccessibilityGranted,
            taskbarHeight: settings.taskbarHeight,
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

        settings.$taskbarHeight
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFrameForCurrentState(animated: true)
            }
            .store(in: &cancellables)
    }

    func setContentSubview(_ view: NSView) {
        hostedView?.removeFromSuperview()
        view.frame = visualEffectView.bounds
        view.autoresizingMask = [.width, .height]
        visualEffectView.addSubview(view)
        hostedView = view
    }

    func updateForAccessibilityPermissionChange() {
        updateFrameForCurrentState(animated: true)
    }

    private func updateFrameForCurrentState(animated: Bool) {
        let nextFrame = Self.panelFrame(
            isAccessibilityGranted: permissionsManager.isAccessibilityGranted,
            taskbarHeight: settings.taskbarHeight,
            screen: screen ?? NSScreen.main ?? NSScreen.screens.first
        )

        setFrame(nextFrame, display: true, animate: animated)
        visualEffectView.frame = NSRect(origin: .zero, size: nextFrame.size)
        hostedView?.frame = visualEffectView.bounds
    }

    private static func panelFrame(
        isAccessibilityGranted: Bool,
        taskbarHeight: CGFloat,
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
