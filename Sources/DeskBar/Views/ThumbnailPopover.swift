import AppKit
import Combine

final class ThumbnailPopover: NSPopover {
    private let popoverEdge: NSRectEdge = .maxY
    private let thumbnailViewController: ThumbnailPopoverViewController
    private var cancellables = Set<AnyCancellable>()

    init(settings: TaskbarSettings) {
        thumbnailViewController = ThumbnailPopoverViewController(
            thumbnailSize: settings.thumbnailSize
        )
        super.init()
        behavior = .semitransient
        animates = true
        contentViewController = thumbnailViewController

        settings.$thumbnailSize
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.thumbnailViewController.updateThumbnailSize(value)
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(thumbnail: NSImage, relativeTo view: NSView) {
        thumbnailViewController.show(thumbnail: thumbnail)
        show(relativeTo: view.bounds, of: view, preferredEdge: popoverEdge)
    }

    func showSyncing(relativeTo view: NSView) {
        thumbnailViewController.showSyncing()
        show(relativeTo: view.bounds, of: view, preferredEdge: popoverEdge)
    }
}

private final class ThumbnailPopoverViewController: NSViewController {
    private var thumbnailSize: CGFloat
    private let imageView = NSImageView()
    private let syncingLabel = NSTextField(labelWithString: "(syncing...)")
    private var currentThumbnail: NSImage?
    private var isShowingSyncing = true

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

        syncingLabel.translatesAutoresizingMaskIntoConstraints = false
        syncingLabel.alignment = .center
        syncingLabel.textColor = .secondaryLabelColor

        containerView.addSubview(imageView)
        containerView.addSubview(syncingLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: containerView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            syncingLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            syncingLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
        ])

        view = containerView
        preferredContentSize = squareSize
        showSyncing()
    }

    func show(thumbnail: NSImage) {
        currentThumbnail = thumbnail
        isShowingSyncing = false
        imageView.image = thumbnail
        imageView.isHidden = false
        syncingLabel.isHidden = true
        preferredContentSize = resolvedSize(for: thumbnail)
        view.setFrameSize(preferredContentSize)
    }

    func showSyncing() {
        currentThumbnail = nil
        isShowingSyncing = true
        imageView.image = nil
        imageView.isHidden = true
        syncingLabel.isHidden = false
        preferredContentSize = squareSize
        view.setFrameSize(preferredContentSize)
    }

    func updateThumbnailSize(_ thumbnailSize: CGFloat) {
        self.thumbnailSize = thumbnailSize

        if isShowingSyncing {
            preferredContentSize = squareSize
        } else if let currentThumbnail {
            preferredContentSize = resolvedSize(for: currentThumbnail)
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
