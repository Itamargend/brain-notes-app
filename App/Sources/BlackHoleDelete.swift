import BrainNotesKit
import SwiftUI

// MARK: - Credit
//
// Inspired by the Telegram-style “black hole” delete behaviour documented publicly for
// riveauxmia/telegram-black-hole-delete (Dynamic Island / top-capsule hole, light ring,
// full-scene warp into an island hole with a bright ring, collapse with a small spring).
// Brain Notes ships an original Metal + Swift implementation: no shaders, textures,
// particle code, or structure was copied from that repository, Telegram-iOS, Inferno,
// Codelaby, or any other third-party source.

/// How strong the delete animation is.
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

    /// Seconds the Metal run (or Reduce Motion fade) lasts.
    func durationSeconds(reduceMotion: Bool) -> Double {
        if reduceMotion { return 0.28 }
        return BlackHoleRunConfig.forIntensity(self).totalDuration
    }

    /// Legacy strand count (timeline still pins light < full); the shader warps a real scene snapshot.
    var cardCount: Int {
        BlackHoleRunConfig.forIntensity(self).cardCount
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

    /// Undo window after the animation finishes and the store has deleted.
    static let undoSeconds: Double = 5
}

/// What RootView draws while a black-hole delete is in flight or undoable.
enum BlackHoleUIState: Equatable {
    case swirling(intensity: BlackHoleIntensity, count: Int)
    case undo(count: Int)
}

// MARK: - Overlay host

/// Full-screen Metal black hole, then a short Undo chip. Driven by `AppModel.blackHole`.
struct BlackHoleOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if case let .swirling(intensity, _)? = app.blackHole {
                BlackHoleEffectView(intensity: intensity, reduceMotion: reduceMotion) {
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

// MARK: - Effect (Metal, or Reduce Motion fade)

/// Metal black-hole when motion is allowed; a short fade when Reduce Motion is on.
struct BlackHoleEffectView: View {
    let intensity: BlackHoleIntensity
    let reduceMotion: Bool
    var onFinished: () -> Void

    @State private var fade: CGFloat = 0
    @State private var finished = false
    @State private var sceneImage: CGImage?
    @State private var didCapture = false

    var body: some View {
        Group {
            if reduceMotion {
                reduceMotionFade
            } else {
                metalLayer
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var metalLayer: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            Group {
                if didCapture {
                    BlackHoleMetalRepresentable(
                        config: .forIntensity(intensity),
                        safeTop: safeTop,
                        sceneImage: sceneImage,
                        onFinished: finishOnce
                    )
                } else {
                    // Capture once with no Metal layer on top, then mount the warp.
                    Color.clear
                        .onAppear {
                            sceneImage = BlackHoleSceneCapture.captureKeyWindow()
                            didCapture = true
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reduceMotionFade: some View {
        ZStack {
            Color.black.opacity(0.35 + 0.4 * Double(fade))
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: 120 * (1.0 - 0.2 * fade), height: 120 * (1.0 - 0.2 * fade))
                .opacity(1.0 - Double(fade))
        }
        .onAppear {
            let seconds = intensity.durationSeconds(reduceMotion: true)
            withAnimation(.easeIn(duration: seconds)) { fade = 1 }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                finishOnce()
            }
        }
    }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        onFinished()
    }
}
