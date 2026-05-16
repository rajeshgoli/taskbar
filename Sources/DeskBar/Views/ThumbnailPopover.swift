import AppKit
import Combine

final class ThumbnailPopover: NSPopover, NSPopoverDelegate {
    private let popoverEdge: NSRectEdge = .maxY
    private let thumbnailViewController: ThumbnailPopoverViewController
    private var cancellables = Set<AnyCancellable>()
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var localKeyboardMonitor: Any?
    private var globalKeyboardMonitor: Any?
    private var appResignActiveObserver: NSObjectProtocol?
    private var workspaceActivateObserver: NSObjectProtocol?

    init(settings: TaskbarSettings) {
        thumbnailViewController = ThumbnailPopoverViewController(
            thumbnailSize: settings.thumbnailSize
        )
        super.init()
        behavior = .applicationDefined
        animates = true
        contentViewController = thumbnailViewController
        delegate = self

        settings.$thumbnailSize
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.thumbnailViewController.updateThumbnailSize(value)
            }
            .store(in: &cancellables)
    }

    deinit {
        removeDismissalMonitors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        removeDismissalMonitors()
        super.close()
    }

    func show(thumbnail: NSImage, relativeTo view: NSView) {
        thumbnailViewController.show(thumbnail: thumbnail)
        show(relativeTo: view.bounds, of: view, preferredEdge: popoverEdge)
        installDismissalMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        removeDismissalMonitors()
    }

    private func installDismissalMonitors() {
        guard localMouseDownMonitor == nil, globalMouseDownMonitor == nil else {
            return
        }

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let keyboardEventMask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.closeUnlessEventTargetsPopover(event)
            return event
        }

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.close()
            }
        }

        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: keyboardEventMask) { [weak self] event in
            self?.close()
            return event
        }

        globalKeyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: keyboardEventMask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.close()
            }
        }

        appResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }

        workspaceActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }
    }

    private func closeUnlessEventTargetsPopover(_ event: NSEvent) {
        guard isShown else {
            return
        }

        guard event.window !== contentViewController?.view.window else {
            return
        }

        close()
    }

    private func removeDismissalMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }

        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }

        if let localKeyboardMonitor {
            NSEvent.removeMonitor(localKeyboardMonitor)
            self.localKeyboardMonitor = nil
        }

        if let globalKeyboardMonitor {
            NSEvent.removeMonitor(globalKeyboardMonitor)
            self.globalKeyboardMonitor = nil
        }

        if let appResignActiveObserver {
            NotificationCenter.default.removeObserver(appResignActiveObserver)
            self.appResignActiveObserver = nil
        }

        if let workspaceActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivateObserver)
            self.workspaceActivateObserver = nil
        }
    }
}

private final class ThumbnailPopoverViewController: NSViewController {
    private var thumbnailSize: CGFloat
    private let imageView = NSImageView()

    init(thumbnailSize: CGFloat) {
        self.thumbnailSize = thumbnailSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let containerView = NSView(frame: NSRect(origin: .zero, size: squareSize))

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        containerView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: containerView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        view = containerView
        preferredContentSize = squareSize
    }

    func show(thumbnail: NSImage) {
        imageView.image = thumbnail
        preferredContentSize = resolvedSize(for: thumbnail)
        view.setFrameSize(preferredContentSize)
    }

    func updateThumbnailSize(_ thumbnailSize: CGFloat) {
        self.thumbnailSize = thumbnailSize

        if let image = imageView.image {
            preferredContentSize = resolvedSize(for: image)
        } else {
            preferredContentSize = squareSize
        }

        if isViewLoaded {
            view.setFrameSize(preferredContentSize)
        }
    }

    private func resolvedSize(for thumbnail: NSImage) -> NSSize {
        let size = thumbnail.size

        guard size.width > 0, size.height > 0 else {
            return squareSize
        }

        let scale = min(thumbnailSize / size.width, thumbnailSize / size.height)
        let resizedWidth = max(1, size.width * scale)
        let resizedHeight = max(1, size.height * scale)
        return NSSize(width: resizedWidth, height: resizedHeight)
    }

    private var squareSize: NSSize {
        NSSize(width: thumbnailSize, height: thumbnailSize)
    }
}
