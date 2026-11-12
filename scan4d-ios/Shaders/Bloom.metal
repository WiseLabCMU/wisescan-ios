#include <metal_stdlib>
using namespace metal;

// MARK: - Bloom Post-Processing Kernels
//
// Two-pass bloom for RealityKit ARView.renderCallbacks.postProcess:
//   Pass 1: bloomThresholdAndBlurH — threshold bright pixels + horizontal Gaussian blur
//   Pass 2: bloomBlurVAndComposite — vertical Gaussian blur + additive composite
//
// The bloom only affects non-black pixels (point cloud), leaving the black
// background untouched. This creates a "glowing point cloud" aesthetic.

// 9-tap Gaussian weights (sigma ≈ 2.0)
constant float gaussWeights[9] = {
    0.028532, 0.067234, 0.124009, 0.179044, 0.20236,
    0.179044, 0.124009, 0.067234, 0.028532
};

// Offset from center for each tap
constant int gaussOffsets[9] = { -4, -3, -2, -1, 0, 1, 2, 3, 4 };

/// Pass 1: Extract bright pixels and blur horizontally, at HALF resolution.
/// Bloom is a low-frequency effect, so the expensive threshold + horizontal-blur
/// pass runs over a half-res intermediate (¼ the threads). The source is sampled
/// (bilinear) and the blur offsets step in full-res texels, so the glow spread
/// matches the previous full-res version. `dest` is the half-res intermediate.
[[kernel]]
void bloomThresholdAndBlurH(uint2 gid [[thread_position_in_grid]],
                             texture2d<half, access::sample> source [[texture(0)]],
                             texture2d<half, access::write> dest [[texture(1)]]) {
    uint dw = dest.get_width();   // half-res
    uint dh = dest.get_height();
    if (gid.x >= dw || gid.y >= dh) return;

    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Luminance threshold: only bloom visible point-cloud pixels (not black bg).
    const half threshold = 0.03h;

    // This half-res texel's center in normalized [0,1] (maps onto the full-res source).
    float2 uv = (float2(gid) + 0.5) / float2(dw, dh);
    // Step in full-res texels so the blur spread is unchanged from the full-res path.
    float stepX = 1.0 / float(source.get_width());

    half4 result = half4(0.0h);
    for (int i = 0; i < 9; i++) {
        float sx = uv.x + float(gaussOffsets[i]) * 3.0 * stepX;  // *3 for a subtle halo
        half4 smp = source.sample(s, float2(sx, uv.y));

        // Luminance check: only include bright-enough pixels in bloom
        half lum = dot(smp.rgb, half3(0.299h, 0.587h, 0.114h));
        if (lum < threshold) {
            smp = half4(0.0h);
        }

        result += smp * half(gaussWeights[i]);
    }

    dest.write(result, gid);
}

/// Pass 2: Vertical blur + additive composite back onto the original, at FULL resolution.
/// Samples the half-res horizontally-blurred intermediate (bilinear upsample), blurs
/// vertically, then adds the result to the original source with a configurable intensity.
[[kernel]]
void bloomBlurVAndComposite(uint2 gid [[thread_position_in_grid]],
                             texture2d<half, access::read> source [[texture(0)]],
                             texture2d<half, access::sample> blurredH [[texture(1)]],
                             texture2d<half, access::write> dest [[texture(2)]]) {
    uint width = source.get_width();
    uint height = source.get_height();
    if (gid.x >= width || gid.y >= height) return;

    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Vertical blur of the half-res horizontally-blurred texture (sampled/upsampled).
    float2 uv = (float2(gid) + 0.5) / float2(width, height);
    float stepY = 1.0 / float(height);  // full-res spread, matching the horizontal pass

    half4 bloomColor = half4(0.0h);
    for (int i = 0; i < 9; i++) {
        float sy = uv.y + float(gaussOffsets[i]) * 3.0 * stepY;  // *3 matching horizontal
        bloomColor += blurredH.sample(s, float2(uv.x, sy)) * half(gaussWeights[i]);
    }

    // Bloom intensity — how much glow to add
    const half intensity = 0.5h;

    // Read original pixel
    half4 original = source.read(gid);

    // Additive composite: original + bloom * intensity
    // Clamp to prevent oversaturation
    half4 result = half4(
        min(original.rgb + bloomColor.rgb * intensity, half3(1.0h)),
        original.a
    );

    dest.write(result, gid);
}
