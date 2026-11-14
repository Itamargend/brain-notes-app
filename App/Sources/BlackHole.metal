// Brain Notes — original Metal shaders for the black-hole delete effect.
// Behaviour: Dynamic Island pill morph + additive accretion bloom + mild funnel,
// with deleted-row snapshots path-deformed (Bezier smear / head-leads-tail / snap)
// into the hole. Inspired by public Telegram write-ups and AE stretch-and-suck
// demos for *behaviour only*. No shaders or source were copied from
// riveauxmia/telegram-black-hole-delete, Telegram-iOS, or any AE plugin.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct BlackHoleUniforms {
    float2 resolution;
    float2 holeCenter;
    float holeRadius;
    float presence;
    float swallow;
    float bounce;
    float time;
    float ringBrightness;
    float pullStrength;
    float hasScene;
    float lensStrength;
    float swirl;
    float cardCount;   // 0…8
    float _pad0;
};

// x,y,w,h in pixel space + seed in .x of second float4 unused: pack as float4 rect + float seed pad
struct BlackHoleCard {
    float4 rect; // x, y, width, height (pixels, top-left origin matching UV*res)
    float seed;
    float3 _pad;
};

vertex VertexOut blackhole_vertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = pos[vid] * 0.5 + 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

static float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float2 cubicBezier(float t, float2 p0, float2 p1, float2 p2, float2 p3) {
    float u = 1.0 - t;
    float uu = u * u;
    float tt = t * t;
    return uu * u * p0 + 3.0 * uu * t * p1 + 3.0 * u * tt * p2 + tt * t * p3;
}

static float2 cubicBezierDeriv(float t, float2 p0, float2 p1, float2 p2, float2 p3) {
    float u = 1.0 - t;
    return 3.0 * u * u * (p1 - p0) + 6.0 * u * t * (p2 - p1) + 3.0 * t * t * (p3 - p2);
}

/// Head / tail progress along the path. Head leads; stretch grows then snaps shut.
static void smearProgress(float swallow, thread float &head, thread float &tail) {
    float s = saturate(swallow);
    // Violent ease-in near the sink (dirt/vacuum slam).
    head = pow(s, 0.62);
    float stretch = mix(0.06, 0.62, pow(s, 0.55));
    // Snap: once the head is near the hole, the elongated tail catches up fast.
    float snap = smoothstep(0.78, 0.98, head);
    stretch *= (1.0 - 0.94 * snap);
    tail = max(0.0, head - stretch);
}

static void cardControls(float4 rect,
                         float2 hole,
                         float seed,
                         float swirl,
                         thread float2 &p0,
                         thread float2 &p1,
                         thread float2 &p2,
                         thread float2 &p3) {
    float2 center = rect.xy + 0.5 * rect.zw;
    // Start from the card centre; path arcs into the hole with a lateral bulge.
    p0 = center;
    p3 = hole;
    float2 toHole = hole - center;
    float dist = length(toHole);
    float2 dir = dist > 1e-3 ? toHole / dist : float2(0.0, -1.0);
    float2 perp = float2(-dir.y, dir.x);
    float side = (seed < 0.5 ? -1.0 : 1.0) * (0.55 + 0.45 * seed);
    float bulge = dist * (0.28 + 0.22 * swirl);
    p1 = center + dir * dist * 0.28 + perp * bulge * side;
    // Near-hole control twists with swirl for a gentle vortex entry.
    float twist = swirl * 0.55 * side;
    float2 nearDir = float2(cos(atan2(dir.y, dir.x) + twist), sin(atan2(dir.y, dir.x) + twist));
    p2 = hole - nearDir * max(dist * 0.22, 24.0) + perp * bulge * 0.35 * side;
}

/// Inverse path-deform: if pixel `p` sits on the smeared ribbon, return sample UV in the card.
static bool sampleSmearCard(float2 p,
                            BlackHoleCard card,
                            float2 hole,
                            float swallow,
                            float swirl,
                            float2 resolution,
                            thread float2 &outUV,
                            thread float &outAlpha) {
    float4 rect = card.rect;
    if (rect.z < 2.0 || rect.w < 2.0) {
        outAlpha = 0.0;
        return false;
    }
    float head, tail;
    smearProgress(swallow, head, tail);
    if (head <= 0.001) {
        outAlpha = 0.0;
        return false;
    }

    float2 p0, p1, p2, p3;
    cardControls(rect, hole, card.seed, swirl, p0, p1, p2, p3);

    // Closest point on the active curve segment [tail, head].
    float bestT = tail;
    float bestD = 1e9;
    const int STEPS = 18;
    for (int i = 0; i <= STEPS; ++i) {
        float tt = mix(tail, max(head, tail + 1e-4), float(i) / float(STEPS));
        float2 q = cubicBezier(tt, p0, p1, p2, p3);
        float d = distance(p, q);
        if (d < bestD) {
            bestD = d;
            bestT = tt;
        }
    }
    // One refine pass around the best sample.
    float span = max((head - tail) / float(STEPS), 0.002);
    for (int j = -4; j <= 4; ++j) {
        float tt = clamp(bestT + float(j) * span * 0.35, tail, max(head, tail));
        float2 q = cubicBezier(tt, p0, p1, p2, p3);
        float d = distance(p, q);
        if (d < bestD) {
            bestD = d;
            bestT = tt;
        }
    }

    float2 deriv = cubicBezierDeriv(bestT, p0, p1, p2, p3);
    float derivLen = length(deriv);
    float2 tangent = derivLen > 1e-3 ? deriv / derivLen : float2(0.0, -1.0);
    float2 normal = float2(-tangent.y, tangent.x);

    float along = saturate((bestT - tail) / max(head - tail, 1e-4));
    // Width: full card at the trailing clump, taper to a thin tip at the head (comet).
    float baseW = 0.5 * max(rect.z, rect.w);
    float halfW = mix(baseW * 1.05, max(2.5, baseW * 0.08), pow(along, 0.85));
    // Soft edge so the smear looks like a streak, not a hard strip.
    float edge = 1.0 - smoothstep(halfW * 0.72, halfW, bestD);
    if (edge <= 0.001) {
        outAlpha = 0.0;
        return false;
    }

    // Map ribbon coordinates back into the original card:
    // along-path → vertical (top of card = toward hole), across → horizontal.
    float across = clamp(dot(p - cubicBezier(bestT, p0, p1, p2, p3), normal) / max(halfW, 1.0), -1.0, 1.0);
    // Head samples the top of the card (first to enter); tail samples the bottom.
    float localY = mix(1.0, 0.0, along); // 0 top … 1 bottom in Metal UV later flipped via rect
    float localX = across * 0.5 + 0.5;

    float2 cardUV = float2(rect.x + localX * rect.z, rect.y + localY * rect.w) / resolution;
    outUV = cardUV;
    // Tip brightens slightly; body stays opaque until the final snap fade into the hole.
    float tipBoost = mix(1.0, 1.15, along);
    float ingest = smoothstep(0.92, 1.0, head);
    outAlpha = edge * tipBoost * (1.0 - ingest * along);
    return outAlpha > 0.001;
}

fragment float4 blackhole_fragment(VertexOut in [[stage_in]],
                                   constant BlackHoleUniforms &u [[buffer(0)]],
                                   constant BlackHoleCard *cards [[buffer(1)]],
                                   texture2d<float> scene [[texture(0)]],
                                   sampler sceneSampler [[sampler(0)]]) {
    float2 uv = in.uv;
    float2 p = uv * u.resolution;
    float2 toHole = p - u.holeCenter;
    float dist = length(toHole);
    float ang = atan2(toHole.y, toHole.x);

    // Capsule → circle morph (Dynamic Island pill swells into the horizon).
    float restW = 63.0;
    float restH = 18.5;
    float morph = saturate(u.presence);
    float bounceScale = 1.0 + u.bounce;
    float rr = mix(restH, u.holeRadius, morph) * bounceScale;
    float rw = mix(restW, u.holeRadius, morph) * (1.0 + u.bounce * 0.55);
    float2 ep = toHole / max(float2(rw, rr), float2(1.0, 1.0));
    float holeSd = length(ep) - 1.0;
    float holeMask = 1.0 - smoothstep(-0.035, 0.02, holeSd);

    // Mild ambient funnel (neighbors stay mostly calm — priority is the card smear).
    float reach = max(u.holeRadius * 5.5 + u.resolution.y * 0.32, 1.0);
    float near = saturate(1.0 - dist / reach);
    float gravity = u.swallow * u.pullStrength * 0.38
        * (pow(near, 2.8) + 0.55 * exp(-dist / max(u.holeRadius * 0.85, 1.0)));
    gravity = saturate(gravity);

    float twist = u.swirl * u.swallow * 0.55 * pow(near, 1.25);
    float warpedAng = ang + twist;
    float radialStretch = 1.0 + gravity * (1.6 + near * 1.8) * u.lensStrength;
    float sampleDist = dist / radialStretch;
    sampleDist = mix(sampleDist, 0.0, gravity * 0.55);
    float tang = 0.10 * u.swirl * u.swallow * sin(ang * 2.0 + u.time * 1.4) * near;
    float2 sampleP = u.holeCenter + float2(cos(warpedAng + tang), sin(warpedAng + tang)) * sampleDist;
    float lens = u.lensStrength * u.presence * (0.10 + 0.40 * u.swallow) * pow(near, 1.45);
    sampleP = mix(sampleP, u.holeCenter, saturate(lens * 0.35));
    float2 sampleUV = sampleP / u.resolution;

    float4 warped = float4(0.02, 0.02, 0.025, 1.0);
    float4 raw = warped;
    if (u.hasScene > 0.5) {
        warped = scene.sample(sceneSampler, sampleUV);
        raw = scene.sample(sceneSampler, uv);
        if (sampleUV.x < -0.02 || sampleUV.x > 1.02 || sampleUV.y < -0.02 || sampleUV.y > 1.02) {
            warped = float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    float warpMix = saturate(u.presence * 0.85) * 0.55;
    float3 col = mix(raw.rgb, warped.rgb, warpMix);

    // Erase original card footprints so the row looks lifted into the smear.
    int nCards = int(clamp(u.cardCount, 0.0, 8.0));
    if (u.hasScene > 0.5 && u.swallow > 0.02) {
        for (int i = 0; i < 8; ++i) {
            if (i >= nCards) break;
            float4 r = cards[i].rect;
            float2 local = (p - r.xy) / max(r.zw, float2(1.0));
            float inside = (local.x > -0.02 && local.x < 1.02 && local.y > -0.02 && local.y < 1.02) ? 1.0 : 0.0;
            if (inside > 0.5) {
                // Sample wallpaper just outside the row (below) to fill the hole left behind.
                float2 fillUV = float2(uv.x, saturate((r.y + r.w + 6.0) / u.resolution.y));
                float3 fill = scene.sample(sceneSampler, fillUV).rgb;
                float lift = smoothstep(0.0, 0.18, u.swallow);
                col = mix(col, fill, lift);
            }
        }
    }

    // Path-deform smear of each deleted card along its Bezier into the hole.
    if (u.hasScene > 0.5 && u.swallow > 0.001) {
        for (int i = 0; i < 8; ++i) {
            if (i >= nCards) break;
            float2 smearUV;
            float smearA;
            if (sampleSmearCard(p, cards[i], u.holeCenter, u.swallow, u.swirl, u.resolution, smearUV, smearA)) {
                float4 tex = scene.sample(sceneSampler, smearUV);
                // Slight motion streak: mix a second sample lagged along the path tangent feel.
                float3 smearCol = tex.rgb;
                smearCol = mix(smearCol, smearCol * float3(1.08, 0.98, 0.85), 0.25 * u.swallow);
                col = mix(col, smearCol, saturate(smearA));
            }
        }
    }

    // Vignette during climax so the bloom pops.
    float vignette = pow(near, 0.85) * u.swallow * 0.55 * u.presence;
    float corner = length((uv - float2(0.5, 0.55)) * float2(1.15, 1.0));
    vignette = saturate(vignette + corner * 0.28 * u.swallow * u.presence);
    col *= (1.0 - vignette * 0.72);

    col = mix(col, col * float3(1.12, 0.94, 0.78), gravity * 0.4 * near);
    col = mix(col, float3(0.0), holeMask * saturate(u.presence * 1.4));

    // Additive accretion disk.
    float ringDist = abs(length(ep) - 1.0);
    float coreRing = exp(-ringDist * ringDist * 48.0) * u.ringBrightness * saturate(u.presence);
    float midRing = exp(-ringDist * ringDist * 14.0) * 0.70 * u.ringBrightness * saturate(u.presence);
    float outerBloom = exp(-ringDist * ringDist * 4.5) * 0.55 * u.ringBrightness * saturate(u.presence);
    float fibers = 0.50 + 0.50 * sin(ang * 14.0 - u.time * (3.2 + near * 5.5) + dist * 0.02);
    float3 ringColor = float3(1.0, 0.94, 0.55);
    float3 bloomColor = float3(1.0, 0.88, 0.35);
    col += ringColor * (coreRing * fibers + midRing);
    col += bloomColor * outerBloom;

    float sparkBand = exp(-ringDist * ringDist * 90.0) * u.swallow * u.presence;
    float spark = step(0.92, hash21(float2(ang * 6.0 + u.time * 4.0, floor(dist * 0.08)))) * sparkBand;
    col += float3(1.0, 0.95, 0.75) * spark * 1.8;

    float flash = (1.0 - u.presence) * u.swallow * exp(-abs(u.bounce) * 8.0) * 0.35;
    col += float3(1.0, 0.92, 0.7) * flash * holeMask;

    float outAlpha = 1.0;
    if (u.hasScene < 0.5) {
        outAlpha = saturate(0.2 + 0.8 * u.presence);
    }
    return float4(col, outAlpha);
}
