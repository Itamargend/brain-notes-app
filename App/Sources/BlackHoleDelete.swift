import BrainNotesKit
import SwiftUI

// MARK: - Credit
//
// Inspired by the Telegram-style “black hole” delete effect popularized in apps and demos
// such as riveauxmia/telegram-black-hole-delete. This file is an original Brain Notes
// implementation written from scratch: no shaders, particle code, or structure was copied
// from that repository, Telegram-iOS, Inferno, Codelaby, or any other third-party source.

/// How strong the delete swirl is.
///
/// Product rule (also in STATUS.md):
/// - **light** — one note (~0.5 s). Milder so everyday deletes don’t tire.
/// - **full** — a folder wipe or several notes at once (count ≥ 2), ~0.9 s.
enum BlackHoleIntensity: Equatable, Sendable {
    case light
    case full

    /// One path → light; two or more → full.
    static func forPathCount(_ count: Int) -> BlackHoleIntensity {
        count >= 2 ? .full : .light
    }

    /// Seconds the swirl (or Reduce Motion fade) runs.
    func durationSeconds(reduceMotion: Bool) -> Double {
        if reduceMotion { return 0.28 }
        switch self {
        case .light: return 0.50
        case .full: return 0.90
        }
    }

    var particleCount: Int {
        switch self {
        case .light: return 28
        case .full: return 72
        }
    }

    /// How many full rotations particles make as they fall in.
    var swirlTurns: Double {
        switch self {
        case .light: return 0.85
        case .full: return 2.15
        }
    }
}

/// One note’s path and text, taken before the store delete so Undo can put it back.
struct DeletedNoteSnapshot: Equatable, Sendable {
    var path: String
    var text: String
}

/// Pure helpers the tests pin down; the overlay and AppModel call these.
enum BlackHoleDeleteLogic {
    static func intensity(forPathCount count: Int) -> BlackHoleIntensity {
        .forPathCount(count)
    }

    /// Builds the undo payload; empty texts are kept so a blank note can still return.
    static func snapshots(paths: [String], texts: [String]) -> [DeletedNoteSnapshot] {
        zip(paths, texts).map { DeletedNoteSnapshot(path: $0.0, text: $0.1) }
    }

    /// Undo window after the swirl finishes and the store has deleted.
    static let undoSeconds: Double = 5
}

/// What RootView draws while a black-hole delete is in flight or undoable.
enum BlackHoleUIState: Equatable {
    case swirling(intensity: BlackHoleIntensity, count: Int)
    case undo(count: Int)
}

// MARK: - Overlay host

/// Full-screen swirl, then a short Undo chip. Driven by `AppModel.blackHole`.
struct BlackHoleOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if case let .swirling(intensity, _)? = app.blackHole {
                BlackHoleSwirlView(intensity: intensity, reduceMotion: reduceMotion) {
                    Task { await app.blackHoleAnimationDidFinish() }
                }
                .transition(.opacity)
                .zIndex(2)
            }
            if case let .undo(count)? = app.blackHole {
                VStack {
                    Spacer().allowsHitTesting(false)
                    BlackHoleUndoBanner(count: count) {
                        Task { await app.undoBlackHoleDelete() }
                    } dismiss: {
                        app.dismissBlackHoleUndo()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.blackHole.map(Self.phaseKey))
    }

    private static func phaseKey(_ state: BlackHoleUIState) -> String {
        switch state {
        case .swirling: return "swirl"
        case .undo: return "undo"
        }
    }
}

/// Transient “Deleted” / “Deleted N notes” with Undo.
struct BlackHoleUndoBanner: View {
    let count: Int
    var undo: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button("Undo", action: undo)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("delete.undo")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("delete.undo.banner")
    }

    private var label: String {
        count <= 1 ? "Deleted" : "Deleted \(count) notes"
    }
}

// MARK: - Swirl (original Canvas)

/// Spiral particles into a dark point. Reduce Motion skips the swirl for a short fade.
struct BlackHoleSwirlView: View {
    let intensity: BlackHoleIntensity
    let reduceMotion: Bool
    var onFinished: () -> Void

    @State private var progress: CGFloat = 0
    @State private var finished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 30 : 1.0 / 60, paused: finished)) { timeline in
            let t = Double(progress)
            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.48)
                let maxR = hypot(size.width, size.height) * 0.55

                if reduceMotion {
                    drawReduceMotion(context: context, size: size, center: center, t: t)
                } else {
                    drawSwirl(context: context, size: size, center: center, maxR: maxR, t: t)
                }
            }
        }
        .background(Color.black.opacity(0.42 + 0.38 * Double(progress)))
        .ignoresSafeArea()
        .onAppear { run() }
    }

    private func run() {
        let seconds = intensity.durationSeconds(reduceMotion: reduceMotion)
        withAnimation(.easeIn(duration: seconds)) {
            progress = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !finished else { return }
            finished = true
            onFinished()
        }
    }

    private func drawReduceMotion(context: GraphicsContext, size: CGSize, center: CGPoint, t: Double) {
        let scale = 1.0 - 0.18 * t
        let opacity = 1.0 - t
        var hole = context
        hole.opacity = opacity
        let side = min(size.width, size.height) * 0.55 * scale
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        hole.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.85)))
    }

    private func drawSwirl(context: GraphicsContext, size: CGSize, center: CGPoint, maxR: Double, t: Double) {
        // Ease so the last third snaps inward.
        let ease = t * t * (3 - 2 * t)
        let holeR = max(2.0, 28.0 * (1.0 - ease) + 2.0)
        var hole = context
        hole.addFilter(.blur(radius: 6 + 10 * ease))
        hole.fill(
            Path(ellipseIn: CGRect(x: center.x - holeR, y: center.y - holeR, width: holeR * 2, height: holeR * 2)),
            with: .color(.black)
        )

        let count = intensity.particleCount
        let turns = intensity.swirlTurns
        // Golden-angle spacing so particles don’t clump on the same ray.
        let golden = 2.399963229728653
        for i in 0..<count {
            let seed = Double(i)
            let startAngle = seed * golden
            let startR = maxR * (0.35 + 0.65 * ((seed * 0.618).truncatingRemainder(dividingBy: 1)))
            let localT = min(1.0, ease * (0.75 + 0.25 * ((seed * 1.37).truncatingRemainder(dividingBy: 1))))
            let r = startR * pow(1.0 - localT, 1.35)
            let angle = startAngle + turns * .pi * 2 * localT
            let x = center.x + CGFloat(r * cos(angle))
            let y = center.y + CGFloat(r * sin(angle))
            let sizeDot = max(0.6, (4.5 - 3.5 * localT) * (intensity == .full ? 1.15 : 0.95))
            var particle = context
            particle.opacity = max(0, 1.0 - localT * 1.05)
            let rect = CGRect(x: x - sizeDot / 2, y: y - sizeDot / 2, width: sizeDot, height: sizeDot)
            let shade = i % 3 == 0 ? Color.purple.opacity(0.75) : Color.white.opacity(0.7)
            particle.fill(Path(ellipseIn: rect), with: .color(shade))
        }

        // Soft vignette rings that collapse.
        for ring in 0..<3 {
            let frac = Double(ring + 1) / 4.0
            let rr = maxR * (1.0 - ease) * (1.0 - frac * 0.25) + holeR
            var stroke = context
            stroke.opacity = 0.18 * (1.0 - ease)
            stroke.stroke(
                Path(ellipseIn: CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)),
                with: .color(.white.opacity(0.35)),
                lineWidth: 1
            )
        }
    }
}
