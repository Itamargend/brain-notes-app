import CoreGraphics
import Foundation

// MARK: - Credit
//
// Timing and geometry follow the *behaviour* documented in the public README for
// riveauxmia/telegram-black-hole-delete (island/capsule hole, emerge → swallow →
// collapse with a small spring). Path-smear of deleted rows follows the
// stretch-and-suck-in look of public AE demos (Bezier path, head leads tail, snap).
// Values are original to Brain Notes. No code was copied from those sources.

/// Tunable run for one black-hole delete. Pure data — unit tests pin the totals.
struct BlackHoleRunConfig: Equatable, Sendable {
    var holeRadius: CGFloat
    var emergeDuration: Double
    var swallowDuration: Double
    var swallowLead: Double
    var collapseDuration: Double
    var collapseBounce: Double
    var settleDuration: Double
    var pullStrength: Double
    var ringBrightness: Double
    var lensStrength: Double
    var swirl: Double
    var cardCount: Int

    /// Wall-clock length of one run (emerge through settle), matching intensity.durationSeconds.
    var totalDuration: Double {
        let swallowStart = emergeDuration * swallowLead
        let swallowEnd = swallowStart + swallowDuration
        let collapseStart = max(emergeDuration, swallowEnd)
        return collapseStart + collapseDuration + settleDuration
    }

    static func forIntensity(_ intensity: BlackHoleIntensity) -> BlackHoleRunConfig {
        switch intensity {
        case .light:
            // Tuned so totalDuration == 0.50 s. Sharp island expand, slam swallow, spring shut.
            return BlackHoleRunConfig(
                holeRadius: 96,
                emergeDuration: 0.10,
                swallowDuration: 0.26,
                swallowLead: 0.04,
                collapseDuration: 0.12,
                collapseBounce: 0.42,
                settleDuration: 0.116,
                pullStrength: 4.2,
                ringBrightness: 1.65,
                lensStrength: 1.55,
                swirl: 1.05,
                cardCount: 3
            )
        case .full:
            // Tuned so totalDuration == 0.90 s. Aggressive full swallow + spring.
            return BlackHoleRunConfig(
                holeRadius: 118,
                emergeDuration: 0.16,
                swallowDuration: 0.46,
                swallowLead: 0.04,
                collapseDuration: 0.18,
                collapseBounce: 0.48,
                settleDuration: 0.2536,
                pullStrength: 4.8,
                ringBrightness: 1.75,
                lensStrength: 1.7,
                swirl: 1.25,
                cardCount: 8
            )
        }
    }
}

/// Sampled state the Metal renderer feeds each frame.
struct BlackHoleFrameState: Equatable, Sendable {
    var presence: Double
    var swallow: Double
    var bounce: Double
    var holeRadius: CGFloat
    var finished: Bool
}

/// Pure path-smear helpers (mirrored in BlackHole.metal). Unit tests pin head/tail/snap.
enum BlackHoleSmear {
    /// Maximum cards the Metal buffer accepts.
    static let maxCards = 8

    /// Head leads the Bezier; stretch grows then snaps as the head nears the sink.
    static func progress(swallow: Double) -> (head: Double, tail: Double, stretch: Double) {
        let s = min(1, max(0, swallow))
        let head = pow(s, 0.62)
        var stretch = (0.06 as Double) + (0.62 - 0.06) * pow(s, 0.55)
        let snap = smoothstep(0.78, 0.98, head)
        stretch *= (1.0 - 0.94 * snap)
        let tail = max(0.0, head - stretch)
        return (head, tail, stretch)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / max(edge1 - edge0, 1e-9)))
        return t * t * (3 - 2 * t)
    }

    /// Approximate note/folder row frames in point space for the path-smear.
    /// Real selection frames are optional later; these cover the list band so the
    /// scene snapshot’s rows get lifted into Bezier ribbons.
    static func cardRects(count: Int, in size: CGSize, safeTop: CGFloat) -> [CGRect] {
        let n = min(max(count, 0), maxCards)
        guard n > 0, size.width > 0, size.height > 0 else { return [] }
        let insetX: CGFloat = 16
        let rowH: CGFloat = 72
        let gap: CGFloat = 8
        let top = max(safeTop + 56, 96)
        let width = max(40, size.width - insetX * 2)
        var rects: [CGRect] = []
        rects.reserveCapacity(n)
        for i in 0..<n {
            let y = top + CGFloat(i) * (rowH + gap)
            if y + rowH > size.height - 40 { break }
            rects.append(CGRect(x: insetX, y: y, width: width, height: rowH))
        }
        return rects
    }

    /// Seed in 0…1 used to pick left/right arc bias per card.
    static func seed(for index: Int) -> Float {
        let x = Float((index * 47 + 13) % 100) / 100.0
        return x
    }
}

enum BlackHoleTimeline {
    /// Where the hole sits: Dynamic Island centre when the top inset looks like an island device;
    /// otherwise a capsule just above the top of the screen (README note for non-island devices).
    static func holeCenter(in size: CGSize, safeTop: CGFloat, prefersIsland: Bool) -> CGPoint {
        let capsuleHeight: CGFloat = 37
        if prefersIsland, safeTop >= 51 {
            // Island sits in the top safe area; centre of the system capsule.
            return CGPoint(x: size.width * 0.5, y: max(capsuleHeight * 0.55, safeTop - capsuleHeight * 0.55))
        }
        // Grow from a capsule just above the visible screen.
        return CGPoint(x: size.width * 0.5, y: -capsuleHeight * 0.35)
    }

    /// Heuristic: tall top inset on a phone-shaped canvas ⇒ treat as Dynamic Island.
    static func prefersIsland(safeTop: CGFloat, size: CGSize) -> Bool {
        safeTop >= 51 && size.width > 0 && size.height / max(size.width, 1) > 1.4
    }

    /// Evaluate the run at time `t` seconds from start. Step is capped by the caller (≤ 1/30).
    static func state(at t: Double, config: BlackHoleRunConfig) -> BlackHoleFrameState {
        let emergeEnd = config.emergeDuration
        let swallowStart = config.emergeDuration * config.swallowLead
        let swallowEnd = swallowStart + config.swallowDuration
        let collapseStart = max(emergeEnd, swallowEnd)
        let collapseEnd = collapseStart + config.collapseDuration
        let settleEnd = collapseEnd + config.settleDuration

        if t >= settleEnd {
            return BlackHoleFrameState(presence: 0, swallow: 1, bounce: 0, holeRadius: config.holeRadius, finished: true)
        }

        let presence: Double
        if t < emergeEnd {
            let u = easeOutQuint(t / max(emergeEnd, 0.0001))
            presence = u
        } else if t < collapseStart {
            presence = 1
        } else if t < collapseEnd {
            let u = (t - collapseStart) / max(config.collapseDuration, 0.0001)
            presence = 1 - easeInCubic(u)
        } else {
            presence = 0
        }

        let swallow: Double
        if t <= swallowStart {
            swallow = 0
        } else if t >= swallowEnd {
            swallow = 1
        } else {
            swallow = easeInCubic((t - swallowStart) / max(config.swallowDuration, 0.0001))
        }

        // Damped spring bulge after the hole lands back on the capsule.
        let bounce: Double
        if t < collapseEnd {
            bounce = 0
        } else {
            let s = (t - collapseEnd) / max(config.settleDuration, 0.0001)
            bounce = config.collapseBounce * exp(-6.0 * s) * sin(s * .pi * 2.4)
        }

        let radius = config.holeRadius * CGFloat(max(presence, 0.08))
        return BlackHoleFrameState(
            presence: presence,
            swallow: swallow,
            bounce: bounce,
            holeRadius: radius,
            finished: false
        )
    }

    private static func easeOutQuint(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return 1 - pow(1 - t, 5)
    }

    private static func easeInCubic(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * t
    }
}
