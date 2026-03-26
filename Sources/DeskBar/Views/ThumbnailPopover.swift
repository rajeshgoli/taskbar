import AppKit

final class ThumbnailPopover: NSPopover {
    private let popoverEdge: NSRectEdge = .maxY
    private let thumbnailViewController = ThumbnailPopoverViewController()

    override init() {
        super.init()
        behavior = .semitransient
        animates = true
        contentViewController = thumbnailViewController
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
    private let defaultThumbnailSize = NSSize(width: 200, height: 200)
    private let imageView = NSImageView()
    private let syncingLabel = NSTextField(labelWithString: "(syncing...)")

    override func loadView() {
        let containerView = NSView(frame: NSRect(origin: .zero, size: defaultThumbnailSize))

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
        preferredContentSize = defaultThumbnailSize
        showSyncing()
    }

    func show(thumbnail: NSImage) {
        imageView.image = thumbnail
        imageView.isHidden = false
        syncingLabel.isHidden = true
        preferredContentSize = resolvedSize(for: thumbnail)
    }

    func showSyncing() {
        imageView.image = nil
        imageView.isHidden = true
        syncingLabel.isHidden = false
        preferredContentSize = defaultThumbnailSize
    }

    private func resolvedSize(for thumbnail: NSImage) -> NSSize {
        let size = thumbnail.size

        guard size.width > 0, size.height > 0 else {
            return defaultThumbnailSize
        }

        return size
    }
}
