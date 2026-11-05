// Brain Notes — original Metal shaders for the black-hole delete effect.
// Behaviour inspired by the public Telegram / riveauxmia write-up (Dynamic Island hole,
// bright accretion ring, full-scene pinch/twirl, spaghettification). No shaders or source
// were copied from that repository or from Telegram-iOS.

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

fragment float4 blackhole_fragment(VertexOut in [[stage_in]],
                                   constant BlackHoleUniforms &u [[buffer(0)]],
                                   texture2d<float> scene [[texture(0)]],
                                   sampler sceneSampler [[sampler(0)]]) {
    float2 uv = in.uv;
    float2 p = uv * u.resolution;
    float2 toHole = p - u.holeCenter;
    float dist = length(toHole);
    float2 dir = dist > 1e-3 ? toHole / dist : float2(0.0, 1.0);

    // Aggressive gravity: exponential near the horizon, softer farther out.
    float reach = max(u.holeRadius * 5.5 + u.resolution.y * 0.35, 1.0);
    float near = saturate(1.0 - dist / reach);
    float gravity = u.swallow * u.pullStrength * (pow(near, 2.2) + 0.55 * exp(-dist / max(u.holeRadius * 0.9, 1.0)));
    gravity = saturate(gravity);

    // Twirl stronger close to the hole.
    float twist = u.swallow * 0.85 * pow(near, 1.4);
    float ang = atan2(toHole.y, toHole.x) + twist;

    // Spaghettification: radial stretch — tops nearer the hole pull in faster.
    float stretch = 1.0 + gravity * (2.6 + near * 2.0);
    float sampleDist = dist / stretch;
    sampleDist = mix(sampleDist, 0.0, gravity * 0.78);
    float2 sampleP = u.holeCenter + float2(cos(ang), sin(ang)) * sampleDist;

    float2 sampleUV = sampleP / u.resolution;
    float4 warped = float4(0.04, 0.04, 0.05, 1.0);
    float4 raw = warped;
    if (u.hasScene > 0.5) {
        warped = scene.sample(sceneSampler, sampleUV);
        raw = scene.sample(sceneSampler, uv);
        // Outside the texture, fall back to near-black so the warp edge stays clean.
        if (sampleUV.x < 0.0 || sampleUV.x > 1.0 || sampleUV.y < 0.0 || sampleUV.y > 1.0) {
            warped = float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    float warpMix = saturate(u.presence * 1.35);
    float3 col = mix(raw.rgb, warped.rgb, warpMix);

    // Capsule → circle morph from the island / top edge.
    float restW = 63.0;
    float restH = 18.5;
    float morph = saturate(u.presence);
    float rr = mix(restH, u.holeRadius, morph) * (1.0 + u.bounce);
    float rw = mix(restW, u.holeRadius, morph) * (1.0 + u.bounce * 0.55);
    float2 ep = toHole / max(float2(rw, rr), float2(1.0, 1.0));
    float holeSd = length(ep) - 1.0;
    float holeMask = 1.0 - smoothstep(-0.05, 0.02, holeSd);
    col = mix(col, float3(0.0, 0.0, 0.0), holeMask * saturate(u.presence * 1.35));

    // Bright white–yellow accretion disk with additive bleed into the UI.
    float ringDist = abs(length(ep) - 1.0);
    float ring = exp(-ringDist * ringDist * 70.0) * u.ringBrightness * saturate(u.presence);
    float outerGlow = exp(-ringDist * ringDist * 12.0) * 0.45 * u.ringBrightness * saturate(u.presence);
    float fibers = 0.55 + 0.45 * sin(ang * 12.0 + u.time * (2.6 + near * 4.0));
    float3 ringColor = float3(1.0, 0.92, 0.62);
    col += ringColor * (ring * fibers + outerGlow);

    // Horizon darkening just outside the disk.
    float shade = saturate(1.0 - dist / (u.holeRadius * 2.8 + 1.0)) * u.swallow * 0.35;
    col *= (1.0 - shade * 0.55);

    float outAlpha = mix(0.0, 1.0, saturate(u.presence * 1.5));
    if (u.hasScene > 0.5) {
        outAlpha = mix(1.0, 1.0, warpMix); // cover the live UI with the warped snapshot
        outAlpha = max(outAlpha, holeMask * u.presence);
    }
    return float4(col, max(outAlpha, ring * 0.85 + outerGlow));
}
