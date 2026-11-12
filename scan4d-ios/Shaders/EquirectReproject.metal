#include <metal_stdlib>
using namespace metal;

// MARK: - Equirectangular → Pinhole (Gnomonic) Reprojection Kernel
//
// Replaces the CPU pixel-by-pixel bilinear sampler in EquirectPrivacyBlur.extractFace()
// and EquirectFaceExport.renderFace(). Each output pixel independently maps to a source
// equirect coordinate — embarrassingly parallel, ideal for GPU.
//
// Convention (matches the Swift callers):
//   lon 0 = equirect center = +Z, lat +90° = +Y
//   Face bases define forward/right/up in world space
//   NDC: U in [-1,1] (left→right), V in [-1,1] (bottom→top)

/// Parameters passed from Swift for each face dispatch.
struct EquirectFaceParams {
    float3 fwd;
    float3 right;
    float3 up;
    uint faceSize;       // output face edge in pixels (square)
    uint equirectWidth;  // source equirect dimensions
    uint equirectHeight;
};

/// Gnomonic reprojection: for each output pixel (gid), compute the world-space direction
/// from the face basis, convert to equirect (lon,lat) → (u,v), and bilinear-sample the
/// source equirect texture.
[[kernel]]
void equirectToFace(uint2 gid [[thread_position_in_grid]],
                    texture2d<half, access::sample> equirect [[texture(0)]],
                    texture2d<half, access::write> face [[texture(1)]],
                    constant EquirectFaceParams &params [[buffer(0)]]) {
    if (gid.x >= params.faceSize || gid.y >= params.faceSize) return;

    float fSize = float(params.faceSize);

    // NDC: pixel center → [-1, 1]
    float ndcU = 2.0f * (float(gid.x) + 0.5f) / fSize - 1.0f;
    float ndcV = 1.0f - 2.0f * (float(gid.y) + 0.5f) / fSize;

    // World-space direction through this pixel (90° FOV pinhole)
    float3 dir = normalize(params.fwd + ndcU * params.right + ndcV * params.up);

    // Direction → equirect UV (longitude wraps, latitude clamps)
    float lat = asin(clamp(dir.y, -1.0f, 1.0f));
    float lon = atan2(dir.x, dir.z);

    // Equirect UV in [0,1] for the sampler (lon=0 maps to center, wraps via repeat)
    float u = (lon + M_PI_F) / (2.0f * M_PI_F);
    float v = (M_PI_F / 2.0f - lat) / M_PI_F;

    // Hardware bilinear sampling: longitude wraps (s), latitude CLAMPS (t) — repeat on t
    // made the up face's pole rows bilinear-blend with the opposite pole's edge row
    // (the CPU sampler clamps rows).
    constexpr sampler texSampler(s_address::repeat, t_address::clamp_to_edge,
                                 filter::linear, coord::normalized);
    half4 color = equirect.sample(texSampler, float2(u, v));

    face.write(half4(color.rgb, 1.0h), gid);
}

/// Variant for cube-face export: same reprojection but with a camera rotation matrix
/// applied (the export faces use rotated camera frames, not axis-aligned face bases).
/// The rotation is passed as 3 column vectors (row-major in the buffer for convenience).
struct EquirectFaceRotatedParams {
    float3 rotCol0;      // rotation matrix column 0
    float3 rotCol1;      // rotation matrix column 1
    float3 rotCol2;      // rotation matrix column 2
    uint faceSize;
    uint equirectWidth;
    uint equirectHeight;
    // Per-scan elevation-registration nuisance (solver: elevation_offset_deg / 180),
    // normalized to the v axis: image content sits this much LOWER than geometry
    // predicts, so sampling shifts down by it. 0 = no correction.
    float vOffsetFrac;
};

[[kernel]]
void equirectToFaceRotated(uint2 gid [[thread_position_in_grid]],
                           texture2d<half, access::sample> equirect [[texture(0)]],
                           texture2d<half, access::write> face [[texture(1)]],
                           constant EquirectFaceRotatedParams &params [[buffer(0)]]) {
    if (gid.x >= params.faceSize || gid.y >= params.faceSize) return;

    float fSize = float(params.faceSize);
    float ndcU = 2.0f * (float(gid.x) + 0.5f) / fSize - 1.0f;
    float ndcV = 1.0f - 2.0f * (float(gid.y) + 0.5f) / fSize;

    // Camera-space ray through the pixel (90° FOV pinhole, looking along -Z)
    float3 camRay = float3(ndcU, ndcV, -1.0f);

    // Apply rotation: multiply by the 3x3 rotation matrix (column vectors)
    float3 rotated = params.rotCol0 * camRay.x + params.rotCol1 * camRay.y + params.rotCol2 * camRay.z;
    rotated = normalize(rotated);

    // Convention match: the Swift caller flips Z for pano-center alignment
    // (camRay → dir = (x, y, -z) in the Swift code). The rotation already encodes
    // this, but we need the same lon = atan2(dir.x, dir.z) convention:
    float3 dir = float3(rotated.x, rotated.y, -rotated.z);

    float lat = asin(clamp(dir.y, -1.0f, 1.0f));
    float lon = atan2(dir.x, dir.z);

    float u = (lon + M_PI_F) / (2.0f * M_PI_F);
    float v = (M_PI_F / 2.0f - lat) / M_PI_F + params.vOffsetFrac;

    constexpr sampler texSampler(s_address::repeat, t_address::clamp_to_edge,
                                 filter::linear, coord::normalized);
    half4 color = equirect.sample(texSampler, float2(u, v));

    face.write(half4(color.rgb, 1.0h), gid);
}
