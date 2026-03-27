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
