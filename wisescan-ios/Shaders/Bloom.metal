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

/// Pass 1: Extract bright pixels and blur horizontally.
/// Reads from the source color texture, writes to an intermediate texture.
/// Pixels below the luminance threshold are discarded (set to black).
[[kernel]]
void bloomThresholdAndBlurH(uint2 gid [[thread_position_in_grid]],
                             texture2d<half, access::read> source [[texture(0)]],
                             texture2d<half, access::write> dest [[texture(1)]]) {
    uint width = source.get_width();
    uint height = source.get_height();
    if (gid.x >= width || gid.y >= height) return;

    // Luminance threshold: only bloom pixels that are visible point cloud
    // (not black background). Threshold of 0.05 catches colored points
    // while excluding pure black.
    const half threshold = 0.03h;

    half4 result = half4(0.0h);

    for (int i = 0; i < 9; i++) {
        int sx = int(gid.x) + gaussOffsets[i] * 3;  // *3 for subtle halo on high-res display
        sx = clamp(sx, 0, int(width) - 1);

        half4 sample = source.read(uint2(sx, gid.y));

        // Luminance check: only include bright-enough pixels in bloom
        half lum = dot(sample.rgb, half3(0.299h, 0.587h, 0.114h));
        if (lum < threshold) {
            sample = half4(0.0h);
        }

        result += sample * half(gaussWeights[i]);
    }

    dest.write(result, gid);
}

/// Pass 2: Vertical blur + additive composite back onto the original.
/// Reads the horizontally-blurred intermediate texture, blurs vertically,
/// then adds the result to the original source with a configurable intensity.
[[kernel]]
void bloomBlurVAndComposite(uint2 gid [[thread_position_in_grid]],
                             texture2d<half, access::read> source [[texture(0)]],
                             texture2d<half, access::read> blurredH [[texture(1)]],
                             texture2d<half, access::write> dest [[texture(2)]]) {
    uint width = source.get_width();
    uint height = source.get_height();
    if (gid.x >= width || gid.y >= height) return;

    // Vertical blur of the horizontally-blurred texture
    half4 bloomColor = half4(0.0h);
    for (int i = 0; i < 9; i++) {
        int sy = int(gid.y) + gaussOffsets[i] * 3;  // *3 matching horizontal
        sy = clamp(sy, 0, int(height) - 1);
        bloomColor += blurredH.read(uint2(gid.x, sy)) * half(gaussWeights[i]);
    }

    // Bloom intensity — how much glow to add (high for testing, tune down later)
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
