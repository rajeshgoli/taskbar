import Foundation

final class Debouncer {
    private var workItem: DispatchWorkItem?
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    func debounce(action: @escaping () -> Void) {
        workItem?.cancel()

        let item = DispatchWorkItem(block: action)
        workItem = item

        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }
}
