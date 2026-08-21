#include <metal_stdlib>
using namespace metal;

// ──────────────────────────────────────────────────────────────────────────────
// VertexColorProject.metal
//
// GPU compute kernel that projects mesh vertices into a camera frame, performs
// depth occlusion testing, person-mask exclusion, and samples the color image.
// For each vertex it outputs (R, G, B, weight); weight == 0 means "not visible
// in this frame". The CPU accumulates the per-frame GPU results into a top-K
// observation buffer and reduces to a weighted median.
// ──────────────────────────────────────────────────────────────────────────────

struct VertexColorParams {
    float4x4 world2Cam;          // world-to-camera 4×4
    float    camX;               // camera position X in world space
    float    camY;               // camera position Y
    float    camZ;               // camera position Z
    float    fx;                 // focal length x (scaled for downsample)
    float    fy;                 // focal length y
    float    cx;                 // principal point x
    float    cy;                 // principal point y
    int      imgW;               // full-res image width
    int      imgH;               // full-res image height
    int      depthW;             // depth image width (0 if no depth)
    int      depthH;             // depth image height
    int      maskW;              // person mask width (0 if no mask)
    int      maskH;              // person mask height
    float    distFloor;          // min distance for inverse-square weight
    float    occlusionMM;        // occlusion tolerance in mm
    float    frameWeight;        // keyframe sharpness bonus multiplier
    uint     vertexCount;        // total vertices
    int      downscaleFactor;    // image downsample factor
    uint     hasDepth;           // 1 if depth texture is valid, 0 otherwise
    uint     hasMask;            // 1 if mask texture is valid, 0 otherwise
    float    occlusionFrac;      // distance-proportional occlusion tolerance (0 = fixed occlusionMM only)
    float    edgeSpreadFrac;     // reject if 3×3 depth spread > frac × depth (0 disables)
    float    backfaceDotMin;     // reject if signed n·v below this (-1 disables)
    uint     depthIsRaster;      // 1 when depth was RASTERIZED from the mesh (cube faces), 0 for sensor depth
    float    occlusionGradedMult; // admit past-tolerance samples out to this multiple, fading to 0 (0 = hard reject)
    float    occlusionGradedFloor;// minimum weight multiplier for an admitted marginal sample
};

// Per-vertex output: packed (r, g, b, _) + weight
struct VertexColorResult {
    uchar4 rgba;                 // r, g, b, 0
    float  weight;               // quality weight (0 = not visible)
};

kernel void vertexColorProject(
    device const float4          *vertices  [[buffer(0)]],
    device const float4          *normals   [[buffer(1)]],
    constant VertexColorParams   &params    [[buffer(2)]],
    device VertexColorResult     *results   [[buffer(3)]],
    texture2d<half, access::sample>   colorTex [[texture(0)]],
    texture2d<ushort, access::read>    depthTex [[texture(1)]],
    texture2d<half, access::sample>    maskTex  [[texture(2)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid >= params.vertexCount) return;

    // Default: not visible
    results[tid].rgba = uchar4(0);
    results[tid].weight = 0.0;

    float3 vtx = vertices[tid].xyz;
    float4 worldPos = float4(vtx.x, vtx.y, vtx.z, 1.0);
    float4 camPos = params.world2Cam * worldPos;

    // Must be in front of camera (z < 0 in ARKit convention)
    if (camPos.z >= 0.0) return;

    // Project using intrinsics
    float invZ = -1.0 / camPos.z;
    int px = int(params.fx * camPos.x * invZ + params.cx);
    int py = int(params.cy - params.fy * camPos.y * invZ);

    // Downscaled image bounds
    int scaledW = params.imgW / params.downscaleFactor;
    int scaledH = params.imgH / params.downscaleFactor;
    if (px < 0 || px >= scaledW || py < 0 || py >= scaledH) return;

    // Texture dimensions (actual rendered texture size)
    int texW = int(colorTex.get_width());
    int texH = int(colorTex.get_height());
    if (px >= texW || py >= texH) return;

    // FRUSTUM WITNESS. From here the vertex is inside this frame's image — whatever
    // happens next (occlusion, person mask, backface) is a REJECTION, not a coverage
    // gap. The alpha channel of the packed color is otherwise unused (always 0), so this
    // costs nothing and lets the accumulator split "never seen by any frame" from "seen
    // and always rejected" — the difference between needing more sweep and needing a
    // looser test.
    results[tid].rgba.w = 1;

    // Multiplier applied to this observation's weight by the occlusion test: 1 = cleanly
    // visible, between 0 and 1 = past tolerance but admitted at reduced confidence.
    float occlusionConfidence = 1.0;

    // Depth occlusion test
    if (params.hasDepth != 0 && params.depthW > 0) {
        int dpx = px * params.downscaleFactor * params.depthW / max(params.imgW, 1);
        int dpy = py * params.downscaleFactor * params.depthH / max(params.imgH, 1);
        if (dpx >= 0 && dpx < params.depthW && dpy >= 0 && dpy < params.depthH) {
            // Read 16-bit depth directly (R16Uint → ushort in millimeters)
            ushort depthRaw = depthTex.read(uint2(dpx, dpy)).r;
            float depthMM = float(depthRaw);
            float expectedMM = -camPos.z * 1000.0;

            // depth == 0 has OPPOSITE meanings for the two depth sources. Sensor depth:
            // the LiDAR returned nothing here, so we cannot tell occluded from visible —
            // skip. Rasterized depth: no mesh lies along this ray, so nothing can be
            // occluding — pass. Treating a raster hole as sensor no-data painted every
            // mesh gap gray on the cube-face path.
            if (depthMM == 0.0 && params.depthIsRaster == 0) {
                results[tid].rgba.g = 5;   // REASON_DEPTH_NODATA
                return;
            }

            if (depthMM > 0.0) {
            // Rasterized depth is a hard-edged z-buffer of the very mesh being colored, so
            // a vertex on a silhouette lands a sub-pixel on the far side of its own edge and
            // self-occludes. Compare against the 3×3 MAX rather than the center sample.
            if (params.depthIsRaster != 0) {
                float dMax3 = depthMM;
                for (int sy = dpy - 1; sy <= dpy + 1; ++sy) {
                    for (int sx = dpx - 1; sx <= dpx + 1; ++sx) {
                        if (sx < 0 || sx >= params.depthW || sy < 0 || sy >= params.depthH) continue;
                        dMax3 = max(dMax3, float(depthTex.read(uint2(sx, sy)).r));
                    }
                }
                depthMM = dMax3;
            }

            // Occluded if expected distance exceeds stored depth + tolerance.
            // Tolerance scales with range (LiDAR error grows with distance) with a
            // near-field floor, so close occluders no longer bleed through 50 mm.
            float tolMM = max(params.occlusionMM, params.occlusionFrac * depthMM);
            if (expectedMM > depthMM + tolMM) {
                float excess = (expectedMM - depthMM - tolMM) / max(tolMM, 1.0);
                // GRADED, not binary. Inside the graded band the sample is admitted with a
                // weight that fades to the floor — it loses to any clean observation of the
                // same vertex (the reduce is a WEIGHTED median) but beats leaving the vertex
                // gray. Past the band it is real geometry in the way: hard reject.
                if (excess < params.occlusionGradedMult) {
                    float fade = 1.0 - (excess / params.occlusionGradedMult);
                    occlusionConfidence = max(params.occlusionGradedFloor, fade);
                } else {
                    // REJECTION DIAGNOSTIC. weight stays 0 so this is never colored, which
                    // frees r/g/b — the accumulator only reads them when weight > 0. r
                    // carries how far past tolerance we were in sixteenths of a tolerance
                    // width; g names the reason.
                    results[tid].rgba.r = uchar(clamp(excess * 16.0, 0.0, 255.0));
                    results[tid].rgba.g = 1;   // REASON_OCCLUSION
                    return;
                }
            }

            // Silhouette guard: near a depth discontinuity the coarse depth raster and
            // the color raster disagree about which side of the edge a pixel is on, so
            // foreground color bakes onto background vertices. Reject observations whose
            // 3×3 depth neighborhood spans more than edgeSpreadFrac × depth.
            if (params.edgeSpreadFrac > 0.0) {
                float dMin = depthMM, dMax = depthMM;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        int sx = dpx + dx, sy = dpy + dy;
                        if (sx < 0 || sx >= params.depthW || sy < 0 || sy >= params.depthH) continue;
                        float dn = float(depthTex.read(uint2(sx, sy)).r);
                        if (dn == 0.0) continue;   // no-data neighbors are not a discontinuity
                        dMin = min(dMin, dn);
                        dMax = max(dMax, dn);
                    }
                }
                if (dMax - dMin > params.edgeSpreadFrac * depthMM) return;
            }
            }
        }
    }

    // Person-mask exclusion (3×3 neighborhood check)
    if (params.hasMask != 0 && params.maskW > 0) {
        int mpx = px * params.downscaleFactor * params.maskW / max(params.imgW, 1);
        int mpy = py * params.downscaleFactor * params.maskH / max(params.imgH, 1);
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int sx = mpx + dx, sy = mpy + dy;
                if (sx >= 0 && sx < params.maskW && sy >= 0 && sy < params.maskH) {
                    half maskVal = maskTex.read(uint2(sx, sy)).r;
                    if (maskVal > 0.0h) {        // person detected
                        results[tid].rgba.g = 2; // REASON_PERSON_MASK
                        return;
                    }
                }
            }
        }
    }

    // Quality weight: view angle × inverse-square distance × frame weight
    float3 camWorldPos = float3(params.camX, params.camY, params.camZ);
    float3 toCam = camWorldPos - vtx;
    float dist = length(toCam);
    if (dist <= 0.0) return;

    float3 viewDir = toCam / dist;
    float3 normal = normals[tid].xyz;
    // Back-face rejection: a vertex whose normal points away from the camera is being
    // seen THROUGH its own surface (e.g. a tabletop's color landing on the underside) —
    // and abs() used to give it full head-on weight. backfaceDotMin = -1 restores that.
    float dotNV = dot(normal, viewDir);
    if (dotNV < params.backfaceDotMin) {
        results[tid].rgba.g = 3;   // REASON_BACKFACE
        return;
    }
    float angleWeight = abs(dotNV);                       // 1 = head-on, 0 = grazing
    float clampedDist = max(dist, params.distFloor);
    float distWeight = 1.0 / (clampedDist * clampedDist); // inverse-square
    float w = angleWeight * distWeight * params.frameWeight * occlusionConfidence;
    if (w <= 1e-6) {
        results[tid].rgba.g = 4;   // REASON_WEIGHT_FLOOR (grazing/far to the point of nothing)
        return;
    }

    // Sample color from downsampled image texture (nearest-neighbor, matching CPU path)
    constexpr sampler nearestSampler(filter::nearest);
    float2 uv = float2((float(px) + 0.5) / float(texW),
                        (float(py) + 0.5) / float(texH));
    half4 color = colorTex.sample(nearestSampler, uv);

    // Alpha doubles as provenance: 1 = cleanly visible, 2 = admitted by the graded
    // occlusion band. Both mean "in frustum", so the coverage split still works, and the
    // accumulator can report how many vertices only exist because of grading.
    results[tid].rgba = uchar4(uchar(color.r * 255.0h),
                                uchar(color.g * 255.0h),
                                uchar(color.b * 255.0h),
                                occlusionConfidence < 1.0 ? 2 : 1);
    results[tid].weight = w;
}
