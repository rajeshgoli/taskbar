#!/usr/bin/env swift

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.iconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let iconBackground = NSColor(calibratedWhite: 0.94, alpha: 1)

let iconFiles: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in iconFiles {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.shouldAntialias = true
    NSGraphicsContext.current?.imageInterpolation = .high

    iconBackground.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: size * 0.22, yRadius: size * 0.22).fill()

    let inset = size * 0.18
    let markRect = NSRect(x: inset, y: inset * 0.82, width: size - inset * 2, height: size - inset * 1.64)
    drawDeskBarMark(in: markRect)

    image.unlockFocus()

    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Failed to render \(filename)")
    }

    try pngData.write(to: outputDirectory.appendingPathComponent(filename))
}

func drawDeskBarMark(in rect: NSRect) {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(
            x: rect.minX + rect.width * x,
            y: rect.minY + rect.height * y
        )
    }

    func fill(_ points: [NSPoint], color: NSColor = .black) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach(path.line(to:))
        path.close()
        color.setFill()
        path.fill()
    }

    // Angular "D" inspired by the reference mark: heavy vertical mass,
    // diagonal caps, and a sharp counter-form instead of font outlines.
    fill([
        p(0.06, 0.09),
        p(0.18, 0.16),
        p(0.18, 0.84),
        p(0.06, 0.91)
    ])
    fill([
        p(0.16, 0.16),
        p(0.48, 0.25),
        p(0.48, 0.75),
        p(0.16, 0.84)
    ])
    fill([
        p(0.26, 0.31),
        p(0.36, 0.36),
        p(0.36, 0.64),
        p(0.26, 0.69)
    ], color: iconBackground)

    // Central split keeps the monogram in the same visual family as the
    // provided icon while leaving an unmistakable "DB" read.
    fill([
        p(0.50, 0.08),
        p(0.56, 0.12),
        p(0.56, 0.88),
        p(0.50, 0.92)
    ])

    // Angular "B" with two faceted bowls and triangular counters.
    fill([
        p(0.56, 0.88),
        p(0.88, 0.73),
        p(0.94, 0.61),
        p(0.86, 0.50),
        p(0.56, 0.58)
    ])
    fill([
        p(0.65, 0.74),
        p(0.81, 0.66),
        p(0.79, 0.58),
        p(0.65, 0.62)
    ], color: iconBackground)

    fill([
        p(0.56, 0.47),
        p(0.88, 0.38),
        p(0.95, 0.25),
        p(0.56, 0.08)
    ])
    fill([
        p(0.65, 0.39),
        p(0.81, 0.34),
        p(0.78, 0.25),
        p(0.65, 0.30)
    ], color: iconBackground)
}
