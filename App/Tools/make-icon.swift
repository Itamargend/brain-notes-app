// Renders the app icon's PNGs from the B4 logo SVGs, 1024 by 1024.
// iOS: square corners and no alpha, because the system rounds the corners itself and the App Store refuses an alpha channel.
// Mac: the rounded icon as drawn, because macOS does not round a square, it shows the sharp corners on a grey plate.
// Usage: swift App/Tools/make-icon.swift <folder with B4-cut-out-link-*.svg> App/Assets.xcassets/AppIcon.appiconset
import AppKit

let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

func render(_ svg: String, to name: String, rounded: Bool = false) throws {
    var text = try String(contentsOf: source.appendingPathComponent(svg), encoding: .utf8)
    if !rounded { text = text.replacingOccurrences(of: #" rx="229.1""#, with: "") }
    guard let image = NSImage(data: Data(text.utf8)) else { fatalError("can't read \(svg)") }
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: (rounded ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.current = nil
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}

try render("B4-cut-out-link-appstore-fullbleed.svg", to: "icon-dark.png")
try render("B4-cut-out-link-icon-light.svg", to: "icon-light.png")
try render("B4-cut-out-link-icon-accent.svg", to: "icon-accent.png")
try render("B4-cut-out-link-icon-dark.svg", to: "icon-mac.png", rounded: true)
