// Generates the placeholder app icon: a white page with text lines on slate blue. No Apple art.
// Usage: swift App/Tools/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = CommandLine.arguments[1]

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(size: Int, to url: URL) {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // No alpha: App Store icons must be opaque.
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let top = color(0x5B, 0x80, 0xB6), bottom = color(0x3F, 0x60, 0x93)
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // The page.
    let page = CGRect(x: s * 0.24, y: s * 0.17, width: s * 0.52, height: s * 0.66)
    ctx.setFillColor(color(255, 255, 255))
    ctx.addPath(CGPath(roundedRect: page, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
    ctx.fillPath()

    // The heading bar and text lines.
    ctx.setFillColor(color(0x4A, 0x6F, 0xA5))
    let heading = CGRect(x: s * 0.31, y: s * 0.66, width: s * 0.30, height: s * 0.055)
    ctx.addPath(CGPath(roundedRect: heading, cornerWidth: s * 0.02, cornerHeight: s * 0.02, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(color(0x9F, 0xB4, 0xD2))
    for (i, w) in [0.38, 0.34, 0.38, 0.24].enumerated() {
        let line = CGRect(x: s * 0.31, y: s * (0.55 - CGFloat(i) * 0.09), width: s * CGFloat(w), height: s * 0.035)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: s * 0.015, cornerHeight: s * 0.015, transform: nil))
        ctx.fillPath()
    }

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    render(size: size, to: URL(fileURLWithPath: folder).appendingPathComponent("icon-\(size).png"))
}
