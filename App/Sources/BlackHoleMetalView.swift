import Metal
import MetalKit
import QuartzCore
import CoreGraphics
import SwiftUI

// MARK: - Credit
//
// Metal host for Brain Notes' original black-hole delete. Behaviour inspired by the
// public riveauxmia/telegram-black-hole-delete write-up; implementation and shaders are ours.
// Full-scene snapshot warp + accretion ring (no procedural placeholder cards).

/// Matches `BlackHoleUniforms` in `BlackHole.metal` (16-byte aligned floats).
struct BlackHoleGPUUniforms {
    var resolution: SIMD2<Float>
    var holeCenter: SIMD2<Float>
    var holeRadius: Float
    var presence: Float
    var swallow: Float
    var bounce: Float
    var time: Float
    var ringBrightness: Float
    var pullStrength: Float
    var hasScene: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

final class BlackHoleMetalCore: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var sceneTexture: MTLTexture?
    private var sceneSampler: MTLSamplerState?
    private var start = CACurrentMediaTime()
    private var elapsed: Double = 0
    private var lastTick = CACurrentMediaTime()
    private var didFinish = false
    private let config: BlackHoleRunConfig
    private let safeTop: CGFloat
    private let onFinished: () -> Void

    init?(config: BlackHoleRunConfig, safeTop: CGFloat, sceneImage: CGImage?, onFinished: @escaping () -> Void) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.config = config
        self.safeTop = safeTop
        self.onFinished = onFinished
        super.init()
        pipeline = Self.makePipeline(device: device)
        sceneSampler = Self.makeSampler(device: device)
        if let sceneImage {
            sceneTexture = Self.makeTexture(from: sceneImage, device: device)
        }
    }

    func attach(to view: MTKView) {
        view.device = device
        view.delegate = self
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = false
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        #else
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = CGColor(gray: 0, alpha: 0)
        #endif
        start = CACurrentMediaTime()
        lastTick = start
        elapsed = 0
        didFinish = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let now = CACurrentMediaTime()
        let dt = min(1.0 / 30.0, max(0, now - lastTick))
        lastTick = now
        elapsed += dt

        let frame = BlackHoleTimeline.state(at: elapsed, config: config)
        let size = view.drawableSize
        let scale: CGFloat
        #if os(iOS)
        scale = view.contentScaleFactor
        #else
        scale = view.window?.backingScaleFactor ?? 2
        #endif
        let pointSize = CGSize(width: size.width / max(scale, 1), height: size.height / max(scale, 1))
        let prefers = BlackHoleTimeline.prefersIsland(safeTop: safeTop, size: pointSize)
        let centerPt = BlackHoleTimeline.holeCenter(in: pointSize, safeTop: safeTop, prefersIsland: prefers)

        var uniforms = BlackHoleGPUUniforms(
            resolution: SIMD2(Float(size.width), Float(size.height)),
            holeCenter: SIMD2(Float(centerPt.x * scale), Float(centerPt.y * scale)),
            holeRadius: Float(frame.holeRadius * scale),
            presence: Float(frame.presence),
            swallow: Float(frame.swallow),
            bounce: Float(frame.bounce),
            time: Float(elapsed),
            ringBrightness: Float(config.ringBrightness),
            pullStrength: Float(config.pullStrength),
            hasScene: sceneTexture == nil ? 0 : 1
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlackHoleGPUUniforms>.stride, index: 0)
        if let sceneTexture, let sceneSampler {
            encoder.setFragmentTexture(sceneTexture, index: 0)
            encoder.setFragmentSamplerState(sceneSampler, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()

        if frame.finished, !didFinish {
            didFinish = true
            view.isPaused = true
            DispatchQueue.main.async { self.onFinished() }
        }
    }

    private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "blackhole_vertex"),
              let fragment = library.makeFunction(name: "blackhole_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    private static func makeSampler(device: MTLDevice) -> MTLSamplerState? {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: desc)
    }

    private static func makeTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width
        let height = image.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
    }
}

#if os(iOS)
struct BlackHoleMetalRepresentable: UIViewRepresentable {
    let config: BlackHoleRunConfig
    let safeTop: CGFloat
    let sceneImage: CGImage?
    var onFinished: () -> Void

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        if let core = BlackHoleMetalCore(config: config, safeTop: safeTop, sceneImage: sceneImage, onFinished: onFinished) {
            context.coordinator.core = core
            core.attach(to: view)
        } else {
            DispatchQueue.main.async { onFinished() }
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var core: BlackHoleMetalCore? }
}
#elseif os(macOS)
struct BlackHoleMetalRepresentable: NSViewRepresentable {
    let config: BlackHoleRunConfig
    let safeTop: CGFloat
    let sceneImage: CGImage?
    var onFinished: () -> Void

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.layer?.isOpaque = false
        if let core = BlackHoleMetalCore(config: config, safeTop: safeTop, sceneImage: sceneImage, onFinished: onFinished) {
            context.coordinator.core = core
            core.attach(to: view)
        } else {
            DispatchQueue.main.async { onFinished() }
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var core: BlackHoleMetalCore? }
}
#endif

/// Snapshot of the key window for the Metal warp (excludes a view that would cover it).
enum BlackHoleSceneCapture {
    #if os(iOS)
    @MainActor
    static func captureKeyWindow(excluding exclude: UIView? = nil) -> CGImage? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
        guard let window else { return nil }
        let wasHidden = exclude?.isHidden
        exclude?.isHidden = true
        defer { if let wasHidden { exclude?.isHidden = wasHidden } }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return image.cgImage
    }
    #elseif os(macOS)
    @MainActor
    static func captureKeyWindow(excluding exclude: NSView? = nil) -> CGImage? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        let wasHidden = exclude?.isHidden
        exclude?.isHidden = true
        defer { if let wasHidden { exclude?.isHidden = wasHidden } }
        guard let rep = window.contentView?.bitmapImageRepForCachingDisplay(in: window.contentView?.bounds ?? .zero) else {
            return nil
        }
        window.contentView?.cacheDisplay(in: window.contentView?.bounds ?? .zero, to: rep)
        return rep.cgImage
    }
    #endif
}
