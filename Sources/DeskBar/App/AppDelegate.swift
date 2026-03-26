import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: TaskbarPanel?
    private var windowManager: WindowManager?
    private var permissionsManager: PermissionsManager?
    private var contentView: TaskbarContentView?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let permissions = PermissionsManager()
        permissionsManager = permissions

        let wm = WindowManager()
        windowManager = wm

        let contentView = TaskbarContentView(windowManager: wm, permissionsManager: permissions)
        self.contentView = contentView

        let taskbarPanel = TaskbarPanel(permissionsManager: permissions)
        taskbarPanel.setContentSubview(contentView)
        taskbarPanel.orderFrontRegardless()
        panel = taskbarPanel

        permissions.$isAccessibilityGranted
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.contentView?.handleAccessibilityPermissionChange()
                self?.panel?.updateForAccessibilityPermissionChange()
            }
            .store(in: &cancellables)

        contentView.handleAccessibilityPermissionChange()
    }
}
