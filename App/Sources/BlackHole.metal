// Brain Notes — original Metal shaders for the black-hole delete effect.
// Behaviour inspired by Telegram / public write-ups (island morph, additive accretion
// bloom, full-canvas funnel, radial spaghettification, snap+spring). No shaders, textures,
// or source were copied from riveauxmia/telegram-black-hole-delete or Telegram-iOS.

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

fragment float4 blackhole_fragment(VertexOut in [[stage_in]],
                                   constant BlackHoleUniforms &u [[buffer(0)]],
                                   texture2d<float> scene [[texture(0)]],
                                   sampler sceneSampler [[sampler(0)]]) {
    float2 uv = in.uv;
    float2 p = uv * u.resolution;
    float2 toHole = p - u.holeCenter;
    float dist = length(toHole);
    float2 dir = dist > 1e-3 ? toHole / dist : float2(0.0, 1.0);
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

    // Exponential gravity: soft far away, slams near the horizon.
    float reach = max(u.holeRadius * 6.5 + u.resolution.y * 0.42, 1.0);
    float near = saturate(1.0 - dist / reach);
    float gravity = u.swallow * u.pullStrength
        * (pow(near, 2.6) + 0.85 * exp(-dist / max(u.holeRadius * 0.72, 1.0)));
    gravity = saturate(gravity);

    // Twirl / spiral displacement (funnel).
    float twist = u.swirl * u.swallow * pow(near, 1.15);
    float warpedAng = ang + twist;

    // True radial stretch (spaghettification): compress sample distance along the
    // radial axis much harder than tangentially — tops near the hole stretch first.
    float radialStretch = 1.0 + gravity * (3.4 + near * 3.8) * u.lensStrength;
    float sampleDist = dist / radialStretch;
    sampleDist = mix(sampleDist, 0.0, gravity * 0.88);

    // Tangential bend toward the funnel curvature.
    float tang = 0.18 * u.swirl * u.swallow * sin(ang * 2.0 + u.time * 1.4) * near;
    float2 sampleP = u.holeCenter + float2(cos(warpedAng + tang), sin(warpedAng + tang)) * sampleDist;

    // Extra lens pull of the whole canvas into the well.
    float lens = u.lensStrength * u.presence * (0.22 + 0.78 * u.swallow) * pow(near, 1.35);
    sampleP = mix(sampleP, u.holeCenter, saturate(lens * 0.55));

    float2 sampleUV = sampleP / u.resolution;
    float4 warped = float4(0.02, 0.02, 0.025, 1.0);
    float4 raw = warped;
    if (u.hasScene > 0.5) {
        // Slight multi-tap blur near the horizon (heat / dissolve).
        float blurPx = gravity * (2.0 + near * 10.0);
        float2 texel = blurPx / max(u.resolution, float2(1.0));
        warped = scene.sample(sceneSampler, sampleUV);
        if (blurPx > 0.4) {
            warped *= 0.4;
            warped += 0.15 * scene.sample(sceneSampler, sampleUV + float2(texel.x, 0.0));
            warped += 0.15 * scene.sample(sceneSampler, sampleUV - float2(texel.x, 0.0));
            warped += 0.15 * scene.sample(sceneSampler, sampleUV + float2(0.0, texel.y));
            warped += 0.15 * scene.sample(sceneSampler, sampleUV - float2(0.0, texel.y));
        }
        raw = scene.sample(sceneSampler, uv);
        if (sampleUV.x < -0.02 || sampleUV.x > 1.02 || sampleUV.y < -0.02 || sampleUV.y > 1.02) {
            warped = float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    float warpMix = saturate(u.presence * 1.45);
    float3 col = mix(raw.rgb, warped.rgb, warpMix);

    // Space shade / vignette so the bloom pops (darkens corners + bottom during climax).
    float vignette = pow(near, 0.85) * u.swallow * 0.72 * u.presence;
    float corner = length((uv - float2(0.5, 0.55)) * float2(1.15, 1.0));
    vignette = saturate(vignette + corner * 0.35 * u.swallow * u.presence);
    col *= (1.0 - vignette * 0.78);

    // Heat tint approaching the horizon.
    col = mix(col, col * float3(1.15, 0.92, 0.72), gravity * 0.55 * near);

    // Pitch-black event horizon (razor-sharp inner edge).
    col = mix(col, float3(0.0), holeMask * saturate(u.presence * 1.4));

    // Additive accretion disk: thick bright band + soft outer bloom + spinning fibers.
    float ringDist = abs(length(ep) - 1.0);
    float coreRing = exp(-ringDist * ringDist * 48.0) * u.ringBrightness * saturate(u.presence);
    float midRing = exp(-ringDist * ringDist * 14.0) * 0.70 * u.ringBrightness * saturate(u.presence);
    float outerBloom = exp(-ringDist * ringDist * 4.5) * 0.55 * u.ringBrightness * saturate(u.presence);
    float fibers = 0.50 + 0.50 * sin(ang * 14.0 - u.time * (3.2 + near * 5.5) + dist * 0.02);
    float3 ringColor = float3(1.0, 0.94, 0.55);
    float3 bloomColor = float3(1.0, 0.88, 0.35);
    col += ringColor * (coreRing * fibers + midRing);
    col += bloomColor * outerBloom;

    // Orbiting spark streaks along the accretion spiral.
    float sparkBand = exp(-ringDist * ringDist * 90.0) * u.swallow * u.presence;
    float spark = step(0.92, hash21(float2(ang * 6.0 + u.time * 4.0, floor(dist * 0.08)))) * sparkBand;
    col += float3(1.0, 0.95, 0.75) * spark * 1.8;

    // Collapse flash when presence drops while swallow is done.
    float flash = (1.0 - u.presence) * u.swallow * exp(-abs(u.bounce) * 8.0) * 0.35;
    col += float3(1.0, 0.92, 0.7) * flash * holeMask;

    float outAlpha = 1.0;
    if (u.hasScene < 0.5) {
        outAlpha = saturate(0.2 + 0.8 * u.presence);
    }
    return float4(col, outAlpha);
}
