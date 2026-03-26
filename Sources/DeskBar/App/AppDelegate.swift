import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: TaskbarPanel?
    private var windowManager: WindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wm = WindowManager()
        windowManager = wm

        let contentView = TaskbarContentView(windowManager: wm)
        let taskbarPanel = TaskbarPanel()
        taskbarPanel.setContentSubview(contentView)
        taskbarPanel.orderFrontRegardless()
        panel = taskbarPanel
    }
}
