import AppKit
import Combine
import ScreenCaptureKit

@MainActor
final class ThumbnailService: ObservableObject {
    @Published var isScreenRecordingGranted: Bool

    private let cacheTTL: TimeInterval = 2
    private var cache: [CGWindowID: CachedThumbnail] = [:]

    init() {
        isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func refreshScreenRecordingPermission() {
        isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            isScreenRecordingGranted = true
            return true
        }

        let granted = CGRequestScreenCaptureAccess()
        isScreenRecordingGranted = granted
        return granted
    }

    func captureThumbnail(
        windowID: CGWindowID,
        size: CGSize = CGSize(width: 200, height: 200)
    ) async -> NSImage? {
        guard windowID != 0 else {
            return nil
        }

        pruneExpiredCache()

        if let cached = cache[windowID], cached.expirationDate > Date() {
            return cached.image
        }

        guard CGPreflightScreenCaptureAccess() else {
            isScreenRecordingGranted = false
            return nil
        }

        isScreenRecordingGranted = true

        guard let content = try? await SCShareableContent.current else {
            return nil
        }

        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        config.width = Int(size.width) * 2
        config.height = Int(size.height) * 2
        config.scalesToFit = true
        config.showsCursor = false

        guard
            let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        else {
            return nil
        }

        let thumbnail = NSImage(cgImage: image, size: size)
        cache[windowID] = CachedThumbnail(
            image: thumbnail,
            expirationDate: Date().addingTimeInterval(cacheTTL)
        )
        return thumbnail
    }

    private func pruneExpiredCache() {
        let now = Date()
        cache = cache.filter { $0.value.expirationDate > now }
    }
}

private struct CachedThumbnail {
    let image: NSImage
    let expirationDate: Date
}
