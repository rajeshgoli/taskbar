import Darwin
import Foundation

final class SingleInstanceLock {
    private enum AcquisitionResult {
        case acquired
        case locked
        case setupFailed
    }

    private let lockURL: URL
    private let fallbackLockURL: URL?
    private var fileDescriptor: Int32 = -1

    init(
        lockURL: URL = SingleInstanceLock.defaultLockURL(),
        fallbackLockURL: URL? = SingleInstanceLock.defaultFallbackLockURL()
    ) {
        self.lockURL = lockURL
        self.fallbackLockURL = fallbackLockURL
    }

    deinit {
        release()
    }

    func acquire() -> Bool {
        guard fileDescriptor == -1 else {
            return true
        }

        switch acquireLock(at: lockURL) {
        case .acquired:
            return true
        case .locked:
            return false
        case .setupFailed:
            guard let fallbackLockURL, fallbackLockURL != lockURL else {
                return false
            }

            switch acquireLock(at: fallbackLockURL) {
            case .acquired:
                return true
            case .locked, .setupFailed:
                return false
            }
        }
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

    static func defaultFallbackLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.deskbar.app", isDirectory: true)
            .appendingPathComponent("deskbar.lock")
    }

    private func acquireLock(at url: URL) -> AcquisitionResult {
        let directoryURL = url.deletingLastPathComponent()
        guard ensureLockDirectory(at: directoryURL) else {
            return .setupFailed
        }

        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            print("DeskBar: failed to open instance lock at \(url.path)")
            return .setupFailed
        }

        guard validateLockFile(descriptor: descriptor, url: url) else {
            close(descriptor)
            return .setupFailed
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return .locked
        }

        fileDescriptor = descriptor
        writeCurrentPID()
        return .acquired
    }

    private func ensureLockDirectory(at url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            print("DeskBar: failed to create lock parent directory at \(url.deletingLastPathComponent().path): \(error)")
            return false
        }

        if mkdir(url.path, S_IRWXU) == 0 {
            return true
        }

        guard errno == EEXIST else {
            print("DeskBar: failed to create lock directory at \(url.path)")
            return false
        }

        var directoryInfo = stat()
        guard lstat(url.path, &directoryInfo) == 0 else {
            print("DeskBar: failed to inspect lock directory at \(url.path)")
            return false
        }

        guard directoryInfo.st_mode & S_IFMT == S_IFDIR else {
            print("DeskBar: lock directory path is not a directory: \(url.path)")
            return false
        }

        guard directoryInfo.st_uid == getuid() else {
            print("DeskBar: lock directory is not owned by the current user: \(url.path)")
            return false
        }

        if directoryInfo.st_mode & (S_IWGRP | S_IWOTH) != 0,
           chmod(url.path, S_IRWXU) != 0 {
            print("DeskBar: failed to restrict lock directory permissions at \(url.path)")
            return false
        }

        return true
    }

    private func validateLockFile(descriptor: Int32, url: URL) -> Bool {
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else {
            print("DeskBar: failed to inspect instance lock at \(url.path)")
            return false
        }

        guard fileInfo.st_mode & S_IFMT == S_IFREG else {
            print("DeskBar: instance lock is not a regular file at \(url.path)")
            return false
        }

        guard fileInfo.st_uid == getuid() else {
            print("DeskBar: instance lock is not owned by the current user: \(url.path)")
            return false
        }

        return true
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
