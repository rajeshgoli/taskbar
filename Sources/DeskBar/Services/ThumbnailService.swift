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
            return cachedLegacyThumbnail(windowID: windowID, size: size)
        }

        isScreenRecordingGranted = true

        guard let content = try? await SCShareableContent.current else {
            return cachedLegacyThumbnail(windowID: windowID, size: size)
        }

        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        return await captureThumbnail(
            windowID: windowID,
            size: size,
            screenCaptureWindowsByID: windowsByID
        )
    }

    func cachedThumbnail(windowID: CGWindowID) -> NSImage? {
        guard windowID != 0 else {
            return nil
        }

        pruneExpiredCache()
        guard let cached = cache[windowID], cached.expirationDate > Date() else {
            return nil
        }

        return cached.image
    }

    func makeCaptureSession() async -> ThumbnailCaptureSession {
        pruneExpiredCache()

        guard CGPreflightScreenCaptureAccess() else {
            isScreenRecordingGranted = false
            return ThumbnailCaptureSession(
                thumbnailService: self,
                screenCaptureWindowsByID: nil
            )
        }

        isScreenRecordingGranted = true

        guard let content = try? await SCShareableContent.current else {
            return ThumbnailCaptureSession(
                thumbnailService: self,
                screenCaptureWindowsByID: nil
            )
        }

        return ThumbnailCaptureSession(
            thumbnailService: self,
            screenCaptureWindowsByID: Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        )
    }

    fileprivate func captureThumbnail(
        windowID: CGWindowID,
        size: CGSize,
        screenCaptureWindowsByID: [CGWindowID: SCWindow]?
    ) async -> NSImage? {
        guard windowID != 0 else {
            return nil
        }

        if let cached = cachedThumbnail(windowID: windowID) {
            return cached
        }

        guard let window = screenCaptureWindowsByID?[windowID] else {
            return cachedLegacyThumbnail(windowID: windowID, size: size)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        config.width = Int(size.width) * 2
        config.height = Int(size.height) * 2
        config.scalesToFit = true
        config.showsCursor = false

        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else {
            return cachedLegacyThumbnail(windowID: windowID, size: size)
        }

        let thumbnail = NSImage(cgImage: image, size: size)
        cache[windowID] = CachedThumbnail(
            image: thumbnail,
            expirationDate: Date().addingTimeInterval(cacheTTL)
        )
        return thumbnail
    }

    private func cachedLegacyThumbnail(windowID: CGWindowID, size: CGSize) -> NSImage? {
        guard let thumbnail = legacyWindowThumbnail(windowID: windowID, size: size) else {
            return nil
        }

        cache[windowID] = CachedThumbnail(
            image: thumbnail,
            expirationDate: Date().addingTimeInterval(cacheTTL)
        )
        return thumbnail
    }

    private func legacyWindowThumbnail(windowID: CGWindowID, size: CGSize) -> NSImage? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }

        return NSImage(cgImage: image, size: size)
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

@MainActor
final class ThumbnailCaptureSession {
    private weak var thumbnailService: ThumbnailService?
    private let screenCaptureWindowsByID: [CGWindowID: SCWindow]?

    init(
        thumbnailService: ThumbnailService,
        screenCaptureWindowsByID: [CGWindowID: SCWindow]?
    ) {
        self.thumbnailService = thumbnailService
        self.screenCaptureWindowsByID = screenCaptureWindowsByID
    }

    func captureThumbnail(
        windowID: CGWindowID,
        size: CGSize
    ) async -> NSImage? {
        await thumbnailService?.captureThumbnail(
            windowID: windowID,
            size: size,
            screenCaptureWindowsByID: screenCaptureWindowsByID
        )
    }
}
