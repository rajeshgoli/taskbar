import Darwin
import Foundation

final class SingleInstanceLock {
    private let lockURL: URL
    private var fileDescriptor: Int32 = -1

    init(lockURL: URL = SingleInstanceLock.defaultLockURL()) {
        self.lockURL = lockURL
    }

    deinit {
        release()
    }

    func acquire() -> Bool {
        guard fileDescriptor == -1 else {
            return true
        }

        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            print("DeskBar: failed to create lock directory: \(error)")
            return true
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            print("DeskBar: failed to open instance lock at \(lockURL.path)")
            return true
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        fileDescriptor = descriptor
        writeCurrentPID()
        return true
    }

    func release() {
        guard fileDescriptor >= 0 else {
            return
        }

        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    static func defaultLockURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("deskbar", isDirectory: true)
            .appendingPathComponent("deskbar.lock")
    }

    private func writeCurrentPID() {
        let processID = "\(ProcessInfo.processInfo.processIdentifier)\n"
        let bytes = Array(processID.utf8)

        ftruncate(fileDescriptor, 0)
        lseek(fileDescriptor, 0, SEEK_SET)
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            _ = Darwin.write(fileDescriptor, baseAddress, buffer.count)
        }
    }
}
