import Foundation
import Testing
@testable import DeskBar

@Test
func singleInstanceLockRejectsSecondHolderUntilReleased() {
    let lockURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskBarTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("deskbar.lock")
    let firstLock = SingleInstanceLock(lockURL: lockURL)
    let secondLock = SingleInstanceLock(lockURL: lockURL)
    defer {
        firstLock.release()
        secondLock.release()
        try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent())
    }

    #expect(firstLock.acquire())
    #expect(secondLock.acquire() == false)

    firstLock.release()
    #expect(secondLock.acquire())
}
