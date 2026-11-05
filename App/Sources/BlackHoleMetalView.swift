import Metal
import MetalKit
import QuartzCore
import CoreGraphics
import SwiftUI

// MARK: - Credit
//
// Metal host for Brain Notes' original black-hole delete. Behaviour inspired by the
// public riveauxmia/telegram-black-hole-delete write-up; implementation and shaders are ours.

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
    var cardCount: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

#if os(iOS)
typealias BlackHolePlatformView = UIView
#elseif os(macOS)
typealias BlackHolePlatformView = NSView
#endif

final class BlackHoleMetalCore: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var start = CACurrentMediaTime()
    private var elapsed: Double = 0
    private var lastTick = CACurrentMediaTime()
    private var didFinish = false
    private let config: BlackHoleRunConfig
    private let safeTop: CGFloat
    private let onFinished: () -> Void

    init?(config: BlackHoleRunConfig, safeTop: CGFloat, onFinished: @escaping () -> Void) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.config = config
        self.safeTop = safeTop
        self.onFinished = onFinished
        super.init()
        pipeline = Self.makePipeline(device: device)
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
        // Cap step at 1/30 so a hitch does not jump the motion (README behaviour note).
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
            cardCount: Float(config.cardCount)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<BlackHoleGPUUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlackHoleGPUUniforms>.stride, index: 0)
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
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: desc)
    }
}

#if os(iOS)
struct BlackHoleMetalRepresentable: UIViewRepresentable {
    let config: BlackHoleRunConfig
    let safeTop: CGFloat
    var onFinished: () -> Void

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        if let core = BlackHoleMetalCore(config: config, safeTop: safeTop, onFinished: onFinished) {
            context.coordinator.core = core
            core.attach(to: view)
        } else {
            // Metal unavailable: finish immediately so delete still completes.
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
    var onFinished: () -> Void

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.layer?.isOpaque = false
        if let core = BlackHoleMetalCore(config: config, safeTop: safeTop, onFinished: onFinished) {
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
