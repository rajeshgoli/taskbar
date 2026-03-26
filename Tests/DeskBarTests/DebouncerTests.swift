import Foundation
import Testing
@testable import DeskBar

@MainActor
@Test
func debounceRunsOnlyLatestAction() async throws {
    let debouncer = Debouncer(interval: 0.01)
    var values: [Int] = []

    debouncer.debounce {
        values.append(1)
    }

    debouncer.debounce {
        values.append(2)
    }

    try await Task.sleep(for: .milliseconds(50))
    #expect(values == [2])
}
