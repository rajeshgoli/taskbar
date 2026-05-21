import AppKit

struct ImageMetadataSignature: Equatable {
    private struct Representation: Equatable {
        let typeName: String
        let size: CGSize
        let pixelsWide: Int
        let pixelsHigh: Int
        let bitsPerSample: Int
    }

    private let size: CGSize?
    private let isTemplate: Bool?
    private let representations: [Representation]

    init(_ image: NSImage?) {
        guard let image else {
            size = nil
            isTemplate = nil
            representations = []
            return
        }

        size = image.size
        isTemplate = image.isTemplate
        representations = image.representations.map { representation in
            Representation(
                typeName: String(describing: type(of: representation)),
                size: representation.size,
                pixelsWide: representation.pixelsWide,
                pixelsHigh: representation.pixelsHigh,
                bitsPerSample: representation.bitsPerSample
            )
        }
    }
}
