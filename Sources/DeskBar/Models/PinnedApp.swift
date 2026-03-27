import AppKit
import Combine

struct PinnedApp: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    var name: String
    var iconData: Data?

    var icon: NSImage? {
        if let data = iconData {
            return NSImage(data: data)
        }

        return NSWorkspace.shared.icon(forFile:
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.path ?? "")
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }
}

final class PinnedAppManager: ObservableObject {
    @Published private(set) var pinnedApps: [PinnedApp]

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "pinnedApps"
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        pinnedApps = []
        pinnedApps = loadPinnedApps()
    }

    func pin(bundleIdentifier: String, name: String) {
        guard !isPinned(bundleIdentifier: bundleIdentifier) else {
            return
        }

        let iconData = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path).tiffRepresentation } ?? nil

        pinnedApps.append(
            PinnedApp(
                bundleIdentifier: bundleIdentifier,
                name: name,
                iconData: iconData
            )
        )
        savePinnedApps()
    }

    func unpin(bundleIdentifier: String) {
        pinnedApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        savePinnedApps()
    }

    func reorder(from: Int, to: Int) {
        guard pinnedApps.indices.contains(from) else {
            return
        }

        let destination = min(max(to, 0), pinnedApps.count - 1)
        guard from != destination else {
            return
        }

        let item = pinnedApps.remove(at: from)
        pinnedApps.insert(item, at: destination)
        savePinnedApps()
    }

    func isPinned(bundleIdentifier: String) -> Bool {
        pinnedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func loadPinnedApps() -> [PinnedApp] {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return []
        }

        return (try? decoder.decode([PinnedApp].self, from: data)) ?? []
    }

    private func savePinnedApps() {
        guard let data = try? encoder.encode(pinnedApps) else {
            return
        }

        defaults.set(data, forKey: defaultsKey)
    }
}
