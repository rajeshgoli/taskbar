import AppKit

extension NSImage {
    /// Scale image to target size
    func scaled(to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .copy,
                  fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    /// Desaturate the image (for minimized/inactive states)
    func desaturated() -> NSImage {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIColorControls") else { return self }
        let ciImage = CIImage(cgImage: cgImage)
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return self }
        let context = CIContext()
        guard let resultCG = context.createCGImage(output, from: output.extent) else { return self }
        return NSImage(cgImage: resultCG, size: self.size)
    }

    /// Apply alpha/transparency
    func withAlpha(_ alpha: CGFloat) -> NSImage {
        let newImage = NSImage(size: self.size)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: self.size),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .copy,
                  fraction: alpha)
        newImage.unlockFocus()
        return newImage
    }

    /// Draw a notification dot overlay (top-right corner)
    func withBadgeDot(dotSize: CGFloat = 6, color: NSColor = .systemRed) -> NSImage {
        let newImage = NSImage(size: self.size)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: self.size))
        let dotRect = NSRect(
            x: self.size.width - dotSize - 1,
            y: self.size.height - dotSize - 1,
            width: dotSize,
            height: dotSize
        )
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        newImage.unlockFocus()
        return newImage
    }
}
