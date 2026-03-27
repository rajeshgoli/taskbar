import AppKit
import Combine

final class BlacklistManager: ObservableObject {
    static let didChangeNotification = Notification.Name("BlacklistManager.didChange")

    @Published var blacklistedBundleIDs: Set<String>

    private let defaults = UserDefaults.standard
    private let defaultsKey = "blacklistedApps"

    init() {
        let storedBundleIDs = defaults.stringArray(forKey: defaultsKey) ?? []
        blacklistedBundleIDs = Set(storedBundleIDs)
    }

    func add(bundleIdentifier: String) {
        let trimmedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleIdentifier.isEmpty else {
            return
        }

        let (inserted, _) = blacklistedBundleIDs.insert(trimmedBundleIdentifier)
        guard inserted else {
            return
        }

        persistAndNotify()
    }

    func remove(bundleIdentifier: String) {
        let trimmedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard blacklistedBundleIDs.remove(trimmedBundleIdentifier) != nil else {
            return
        }

        persistAndNotify()
    }

    func isBlacklisted(bundleIdentifier: String) -> Bool {
        blacklistedBundleIDs.contains(bundleIdentifier)
    }

    private func persistAndNotify() {
        defaults.set(Array(blacklistedBundleIDs).sorted(), forKey: defaultsKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
