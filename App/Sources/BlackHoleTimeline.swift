import CoreGraphics
import Foundation

// MARK: - Credit
//
// Timing and geometry follow the *behaviour* documented in the public README for
// riveauxmia/telegram-black-hole-delete (island/capsule hole, emerge → swallow →
// collapse with a small spring). Values are original to Brain Notes and scaled to our
// light (~0.5 s) / full (~0.9 s) product rule. No code was copied from that repository.

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
            // Tuned so totalDuration == 0.50 s.
            return BlackHoleRunConfig(
                holeRadius: 72,
                emergeDuration: 0.18,
                swallowDuration: 0.30,
                swallowLead: 0.10,
                collapseDuration: 0.10,
                collapseBounce: 0.28,
                settleDuration: 0.082,
                pullStrength: 2.4,
                ringBrightness: 0.95,
                cardCount: 3
            )
        case .full:
            // Tuned so totalDuration == 0.90 s.
            return BlackHoleRunConfig(
                holeRadius: 90,
                emergeDuration: 0.32,
                swallowDuration: 0.52,
                swallowLead: 0.10,
                collapseDuration: 0.20,
                collapseBounce: 0.35,
                settleDuration: 0.148,
                pullStrength: 3.0,
                ringBrightness: 1.05,
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
            let u = easeOutCubic(t / max(emergeEnd, 0.0001))
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
            swallow = easeInOut((t - swallowStart) / max(config.swallowDuration, 0.0001))
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

    private static func easeOutCubic(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return 1 - pow(1 - t, 3)
    }

    private static func easeInCubic(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * t
    }

    private static func easeInOut(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}
