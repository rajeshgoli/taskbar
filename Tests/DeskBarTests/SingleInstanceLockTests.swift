import Foundation
import Testing
@testable import DeskBar

@Test
func singleInstanceLockRejectsSecondHolderUntilReleased() {
    let lockURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskBarTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("deskbar.lock")
    let firstLock = SingleInstanceLock(lockURL: lockURL, fallbackLockURL: nil)
    let secondLock = SingleInstanceLock(lockURL: lockURL, fallbackLockURL: nil)
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

@Test
func singleInstanceLockFailsClosedWhenSetupFailsWithoutFallback() throws {
    let parentFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskBarTests-\(UUID().uuidString)")
    try "not a directory".write(to: parentFileURL, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: parentFileURL)
    }

    let lock = SingleInstanceLock(
        lockURL: parentFileURL.appendingPathComponent("deskbar.lock"),
        fallbackLockURL: nil
    )

    #expect(lock.acquire() == false)
}

@Test
func singleInstanceLockFallsBackWhenPrimarySetupFails() throws {
    let parentFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskBarTests-\(UUID().uuidString)")
    let fallbackLockURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskBarTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("deskbar.lock")
    try "not a directory".write(to: parentFileURL, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: parentFileURL)
        try? FileManager.default.removeItem(at: fallbackLockURL.deletingLastPathComponent())
    }

    let lock = SingleInstanceLock(
        lockURL: parentFileURL.appendingPathComponent("deskbar.lock"),
        fallbackLockURL: fallbackLockURL
    )
    defer {
        lock.release()
    }

    #expect(lock.acquire())
}
