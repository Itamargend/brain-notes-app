// Brain Notes — original Metal shaders for the black-hole delete effect.
// Behaviour inspired by the public write-up for riveauxmia/telegram-black-hole-delete
// (Dynamic Island / top-capsule hole, light ring, cards pulled along an arc and stretched
// near the horizon, collapse with a small spring). No shaders, textures, or source were
// copied from that repository or from Telegram-iOS.

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
    float cardCount;
    float pad0;
    float pad1;
};

vertex VertexOut blackhole_vertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = pos[vid] * 0.5 + 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

static float sdRoundBox(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 blackhole_fragment(VertexOut in [[stage_in]],
                                   constant BlackHoleUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * u.resolution;
    float2 toHole = p - u.holeCenter;
    float dist = length(toHole);
    float ang = atan2(toHole.y, toHole.x);

    float space = smoothstep(u.holeRadius * 3.2, u.holeRadius * 0.9, dist) * u.presence;
    float3 col = float3(0.06, 0.065, 0.08);
    col = mix(col, float3(0.02, 0.02, 0.03), space * 0.75);
    float twist = sin(ang * 3.0 + u.time * 0.9 + dist * 0.01) * 0.04 * u.presence;
    col += twist;

    float listTop = max(u.holeCenter.y + u.holeRadius + 36.0, u.resolution.y * 0.22);
    int n = int(clamp(u.cardCount, 1.0, 12.0));
    for (int i = 0; i < 12; ++i) {
        if (i >= n) break;
        float fi = float(i);
        float2 rest = float2(
            u.resolution.x * (0.50 + 0.14 * sin(fi * 1.91 + 0.4)),
            listTop + fi * 54.0
        );

        float2 delta = u.holeCenter - rest;
        float d0 = max(length(delta), 1.0);
        float2 dir = delta / d0;
        float2 perp = float2(-dir.y, dir.x);
        float arc = sin(u.swallow * 3.14159265) * (28.0 + fi * 3.0);
        float pull = pow(saturate(u.swallow), 0.82);
        float near = saturate(1.0 - d0 / (u.holeRadius * 5.0 + 1.0));
        pull = saturate(pull + near * u.pullStrength * 0.12 * u.swallow);

        float2 pos = mix(rest, u.holeCenter, pull) + perp * arc * (1.0 - pull);
        float stretch = 1.0 + pull * (1.35 + near * u.pullStrength * 0.55);
        float shrink = 1.0 - 0.55 * pull;

        float2 local = p - pos;
        float x = dot(local, float2(dir.y, -dir.x));
        float y = dot(local, dir) / stretch;
        float2 halfSize = float2(78.0 * shrink, 20.0 * stretch * shrink);
        float sd = sdRoundBox(float2(x, y), halfSize, 8.0);
        float alpha = (1.0 - smoothstep(-1.2, 1.8, sd)) * (1.0 - smoothstep(0.72, 1.0, pull));
        float3 card = float3(0.93, 0.94, 0.96);
        if (abs(y + halfSize.y * 0.35) < 2.2 && abs(x) < halfSize.x * 0.72) {
            card = float3(0.25, 0.28, 0.34);
        } else if (abs(y) < 1.6 && abs(x) < halfSize.x * 0.65) {
            card *= 0.82;
        } else if (abs(y - halfSize.y * 0.25) < 1.4 && abs(x) < halfSize.x * 0.55) {
            card *= 0.88;
        }
        card = mix(card, float3(1.0, 0.78, 0.55), near * pull * 0.55);
        col = mix(col, card, alpha * 0.92);
    }

    float restW = 63.0;
    float restH = 18.5;
    float morph = saturate(u.presence);
    float rr = mix(restH, u.holeRadius, morph) * (1.0 + u.bounce);
    float rw = mix(restW, u.holeRadius, morph) * (1.0 + u.bounce * 0.55);
    float2 ep = toHole / max(float2(rw, rr), float2(1.0, 1.0));
    float holeSd = length(ep) - 1.0;
    float holeMask = 1.0 - smoothstep(-0.04, 0.02, holeSd);
    col = mix(col, float3(0.0, 0.0, 0.0), holeMask * saturate(u.presence * 1.25));

    float ringDist = abs(length(ep) - 1.0);
    float ring = exp(-ringDist * ringDist * 90.0) * u.ringBrightness * saturate(u.presence);
    float horizonBoost = saturate(1.0 - dist / (u.holeRadius * 2.5 + 1.0)) * 3.5;
    float fibers = 0.65 + 0.35 * sin(ang * 10.0 + u.time * (2.2 + horizonBoost));
    col += float3(1.0, 0.86, 0.68) * ring * fibers;

    float outAlpha = saturate(0.28 + 0.62 * u.presence);
    return float4(col, outAlpha);
}
