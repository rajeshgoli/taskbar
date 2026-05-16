import AppKit
import Combine

final class TaskbarPanel: NSPanel {
    private static let bannerHeight: CGFloat = 32
    private static let compactHorizontalMargin: CGFloat = 12
    private static let compactMinimumWidth: CGFloat = 420
    private static let compactFallbackWidth: CGFloat = 860

    let displayID: CGDirectDisplayID

    private let permissionsManager: PermissionsManager
    private let settings: TaskbarSettings
    private let rootView: TaskbarPanelRootView
    private let visualEffectView: NSVisualEffectView
    private weak var hostedView: NSView?
    private var cancellables = Set<AnyCancellable>()

    init(
        permissionsManager: PermissionsManager,
        settings: TaskbarSettings,
        screen: NSScreen
    ) {
        self.displayID = ScreenGeometry.displayID(for: screen) ?? CGMainDisplayID()
        self.permissionsManager = permissionsManager
        self.settings = settings

        let frame = Self.panelFrame(
            isAccessibilityGranted: permissionsManager.isAccessibilityGranted,
            taskbarHeight: settings.taskbarHeight,
            screen: screen
        )

        rootView = TaskbarPanelRootView(settings: settings, frame: NSRect(origin: .zero, size: frame.size))
        visualEffectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isMovableByWindowBackground = false
        isOpaque = false
        hasShadow = false

        rootView.autoresizingMask = [.width, .height]
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        rootView.addSubview(visualEffectView)
        rootView.chromeView = visualEffectView
        contentView = rootView
        updateChromeLayout(animated: false)

        settings.$taskbarHeight
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFrameForCurrentState(animated: true)
            }
            .store(in: &cancellables)

        settings.$layoutMode
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
        updateFrameForCurrentState(animated: false)
    }

    func updateForAccessibilityPermissionChange() {
        updateFrameForCurrentState(animated: true)
    }

    func updateFrame(for screen: NSScreen) {
        updateFrameForCurrentState(animated: true, screen: screen)
    }

    func requestLayoutUpdate(animated: Bool) {
        updateFrameForCurrentState(animated: animated)
    }

    func updateCollectionBehavior(showOverFullScreenApps: Bool) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if showOverFullScreenApps {
            behavior.insert(.fullScreenAuxiliary)
        }

        collectionBehavior = behavior
    }

    private func updateFrameForCurrentState(animated: Bool, screen: NSScreen? = nil) {
        let resolvedScreen = screen ??
            ScreenGeometry.screen(for: displayID) ??
            self.screen ??
            NSScreen.screens.first

        let nextFrame = Self.panelFrame(
            isAccessibilityGranted: permissionsManager.isAccessibilityGranted,
            taskbarHeight: settings.taskbarHeight,
            screen: resolvedScreen
        )

        let frameChanged = !Self.framesApproximatelyEqual(frame, nextFrame)
        if frameChanged {
            setFrame(nextFrame, display: true, animate: animated)
            rootView.frame = NSRect(origin: .zero, size: nextFrame.size)
        }

        updateChromeLayout(animated: animated)
    }

    private func updateChromeLayout(animated: Bool) {
        let chromeFrame = Self.chromeFrame(
            layoutMode: settings.layoutMode,
            compactContentWidth: compactContentWidth(),
            bounds: rootView.bounds
        )
        let shouldAnimate = animated &&
            !settings.layoutMode.usesCompactWidth &&
            !Self.framesApproximatelyEqual(visualEffectView.frame, chromeFrame)

        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                visualEffectView.animator().frame = chromeFrame
            }
        } else if !Self.framesApproximatelyEqual(visualEffectView.frame, chromeFrame) {
            visualEffectView.frame = chromeFrame
        }

        let hostedFrame = visualEffectView.bounds
        if let hostedView, !Self.framesApproximatelyEqual(hostedView.frame, hostedFrame) {
            hostedView.frame = hostedFrame
        }
        updateVisualStyle(for: chromeFrame)
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

    private static func chromeFrame(
        layoutMode: DeskBarLayoutMode,
        compactContentWidth: CGFloat?,
        bounds: NSRect
    ) -> NSRect {
        let width: CGFloat

        switch layoutMode {
        case .fullWidth, .fullWidthGlass:
            width = bounds.width
        case .compact, .compactGlass:
            let maximumWidth = max(120, bounds.width - compactHorizontalMargin * 2)
            let minimumWidth = min(compactMinimumWidth, maximumWidth)
            let desiredWidth = compactContentWidth ?? min(compactFallbackWidth, maximumWidth)
            width = min(max(ceil(desiredWidth), minimumWidth), maximumWidth)
        }

        let originX = bounds.minX + floor((bounds.width - width) / 2)
        return NSRect(
            x: originX,
            y: bounds.minY,
            width: width,
            height: bounds.height
        )
    }

    private func compactContentWidth() -> CGFloat? {
        guard let taskbarContentView = hostedView as? TaskbarContentView else {
            return hostedView?.fittingSize.width
        }

        return taskbarContentView.preferredCompactWidth()
    }

    private func updateVisualStyle(for frame: NSRect) {
        let usesGlassChrome = settings.layoutMode == .compactGlass || settings.layoutMode == .fullWidthGlass
        visualEffectView.layer?.cornerRadius = usesGlassChrome ? min(frame.height / 2, 18) : 0
        visualEffectView.layer?.masksToBounds = usesGlassChrome
        visualEffectView.shadow = usesGlassChrome ? Self.glassShadow() : nil
    }

    private static func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5 &&
            abs(lhs.origin.y - rhs.origin.y) < 0.5 &&
            abs(lhs.size.width - rhs.size.width) < 0.5 &&
            abs(lhs.size.height - rhs.size.height) < 0.5
    }

    private static func glassShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: 2)
        return shadow
    }
}

private extension DeskBarLayoutMode {
    var usesCompactWidth: Bool {
        self == .compact || self == .compactGlass
    }
}

private final class TaskbarPanelRootView: NSView {
    private let settings: TaskbarSettings
    weak var chromeView: NSView?

    init(settings: TaskbarSettings, frame frameRect: NSRect) {
        self.settings = settings
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if settings.layoutMode.usesCompactWidth,
           let chromeView,
           !chromeView.frame.contains(point) {
            return nil
        }

        return super.hitTest(point)
    }
}
