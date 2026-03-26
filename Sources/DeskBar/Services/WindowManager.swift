import AppKit
import Combine

class WindowManager: ObservableObject {
    @Published var windows: [WindowInfo] = []

    init() {}

    func refresh() {}
}
