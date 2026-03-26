import AppKit
import Combine

enum DockMode: String, CaseIterable {
    case independent
    case autoHide
    case hidden
}

class TaskbarSettings: ObservableObject {
    private let defaults = UserDefaults(suiteName: "com.deskbar.app")!

    @Published var showLaunchpadButton: Bool {
        didSet { defaults.set(showLaunchpadButton, forKey: "showLaunchpadButton") }
    }

    @Published var taskbarHeight: CGFloat {
        didSet { defaults.set(taskbarHeight, forKey: "taskbarHeight") }
    }

    @Published var titleFontSize: CGFloat {
        didSet { defaults.set(titleFontSize, forKey: "titleFontSize") }
    }

    @Published var maxTaskWidth: CGFloat {
        didSet { defaults.set(maxTaskWidth, forKey: "maxTaskWidth") }
    }

    @Published var showTitles: Bool {
        didSet { defaults.set(showTitles, forKey: "showTitles") }
    }

    @Published var groupByApp: Bool {
        didSet { defaults.set(groupByApp, forKey: "groupByApp") }
    }

    @Published var dragReorder: Bool {
        didSet { defaults.set(dragReorder, forKey: "dragReorder") }
    }

    @Published var middleClickCloses: Bool {
        didSet { defaults.set(middleClickCloses, forKey: "middleClickCloses") }
    }

    @Published var thumbnailSize: CGFloat {
        didSet { defaults.set(thumbnailSize, forKey: "thumbnailSize") }
    }

    @Published var hoverDelay: TimeInterval {
        didSet { defaults.set(hoverDelay, forKey: "hoverDelay") }
    }

    @Published var dockMode: DockMode {
        didSet { defaults.set(dockMode.rawValue, forKey: "dockMode") }
    }

    @Published var showOverFullScreenApps: Bool {
        didSet { defaults.set(showOverFullScreenApps, forKey: "showOverFullScreenApps") }
    }

    @Published var startAtLogin: Bool {
        didSet { defaults.set(startAtLogin, forKey: "startAtLogin") }
    }

    @Published var showOnAllMonitors: Bool {
        didSet { defaults.set(showOnAllMonitors, forKey: "showOnAllMonitors") }
    }

    init() {
        showLaunchpadButton = defaults.object(forKey: "showLaunchpadButton") as? Bool ?? true
        taskbarHeight = defaults.object(forKey: "taskbarHeight") as? CGFloat ?? 40
        titleFontSize = defaults.object(forKey: "titleFontSize") as? CGFloat ?? 12
        maxTaskWidth = defaults.object(forKey: "maxTaskWidth") as? CGFloat ?? 200
        showTitles = defaults.object(forKey: "showTitles") as? Bool ?? true
        groupByApp = defaults.object(forKey: "groupByApp") as? Bool ?? false
        dragReorder = defaults.object(forKey: "dragReorder") as? Bool ?? true
        middleClickCloses = defaults.object(forKey: "middleClickCloses") as? Bool ?? true
        thumbnailSize = defaults.object(forKey: "thumbnailSize") as? CGFloat ?? 200
        hoverDelay = defaults.object(forKey: "hoverDelay") as? TimeInterval ?? 0.4
        dockMode = DockMode(rawValue: defaults.string(forKey: "dockMode") ?? "") ?? .independent
        showOverFullScreenApps = defaults.object(forKey: "showOverFullScreenApps") as? Bool ?? false
        startAtLogin = defaults.object(forKey: "startAtLogin") as? Bool ?? false
        showOnAllMonitors = defaults.object(forKey: "showOnAllMonitors") as? Bool ?? false
    }
}
