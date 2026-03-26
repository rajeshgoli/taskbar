import AppKit
import Combine

final class TaskbarContentView: NSView {
    private let windowManager: WindowManager
    private let taskStackView = NSStackView()
    private var cancellable: AnyCancellable?
    private var workspaceObserver: NSObjectProtocol?

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]

        setupTaskStackView()
        bindWindowUpdates()
        observeFrontmostApplication()
        rebuildViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancellable?.cancel()

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    private func setupTaskStackView() {
        taskStackView.translatesAutoresizingMaskIntoConstraints = false
        taskStackView.orientation = .horizontal
        taskStackView.alignment = .centerY
        taskStackView.spacing = 2
        taskStackView.distribution = .fill

        addSubview(taskStackView)

        NSLayoutConstraint.activate([
            taskStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            taskStackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            taskStackView.topAnchor.constraint(equalTo: topAnchor),
            taskStackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func bindWindowUpdates() {
        cancellable = windowManager.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildViews()
            }
    }

    private func observeFrontmostApplication() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildViews()
        }
    }

    private func rebuildViews() {
        taskStackView.arrangedSubviews.forEach { view in
            taskStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for window in windowManager.windows {
            let buttonView = TaskButtonView(
                windowInfo: window,
                isActive: window.pid == activePID
            ) { [weak self] windowInfo in
                self?.activate(windowInfo: windowInfo)
            }
            taskStackView.addArrangedSubview(buttonView)
            buttonView.heightAnchor.constraint(equalTo: taskStackView.heightAnchor).isActive = true
        }
    }

    private func activate(windowInfo: WindowInfo) {
        guard let application = NSWorkspace.shared.runningApplications.first(
            where: { $0.processIdentifier == windowInfo.pid }
        ) else {
            return
        }

        application.activate(options: .activateAllWindows)
    }
}
