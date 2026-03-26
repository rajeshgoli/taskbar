import AppKit
import Combine

class TaskbarContentView: NSView {
    private var windowManager: WindowManager
    private var cancellable: AnyCancellable?

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]

        cancellable = windowManager.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildViews()
            }
        rebuildViews()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    private func rebuildViews() {
        subviews.forEach { $0.removeFromSuperview() }

        let iconSize: CGFloat = 32
        let padding: CGFloat = 8
        var x: CGFloat = padding

        for window in windowManager.windows {
            let iconView = NSImageView(
                frame: NSRect(
                    x: x,
                    y: (bounds.height - iconSize) / 2,
                    width: iconSize,
                    height: iconSize
                )
            )
            iconView.image = window.icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.toolTip = window.appName
            addSubview(iconView)
            x += iconSize + padding
        }
    }

    override func layout() {
        super.layout()
        rebuildViews()
    }
}
