#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

struct PointCloudUniforms {
    float4x4 cameraTransform;
    float3x3 intrinsics;
    float2 depthRes;
    float2 cameraRes;
    uint useSegmentation;
};

// YCbCr to RGB conversion constants (BT.601 full-range)
constant float4x4 ycbcrToRGBTransform = float4x4(
    float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
    float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
    float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
    float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
);

// Vertex layout: [px, py, pz, u, v] = 5 floats = 20 bytes per vertex.
// Colors are written to a separate texture (LowLevelTexture) and sampled
// via UV by UnlitMaterial — avoids CustomMaterial which crashes with
// RealityKit's AR video compositing pipeline.
constant uint FLOATS_PER_VERTEX = 5;

void writeVertex(device float* raw, uint vertexIndex, float3 pos, float2 uv) {
    uint offset = vertexIndex * FLOATS_PER_VERTEX;
    raw[offset + 0] = pos.x;
    raw[offset + 1] = pos.y;
    raw[offset + 2] = pos.z;
    raw[offset + 3] = uv.x;
    raw[offset + 4] = uv.y;
}

[[kernel]]
void projectPointCloud(uint2 id [[thread_position_in_grid]],
                       texture2d<float, access::read> depthTexture [[texture(0)]],
                       texture2d<float, access::sample> imageYTexture [[texture(1)]],
                       texture2d<float, access::sample> imageCbCrTexture [[texture(2)]],
                       texture2d<float, access::sample> segTexture [[texture(3)]],
                       texture2d<float, access::write> colorOutput [[texture(4)]],
                       texture2d<uint, access::read> confidenceTexture [[texture(5)]],
                       device float* vertices [[buffer(0)]],
                       constant PointCloudUniforms& uniforms [[buffer(1)]]) {

    uint depthW = depthTexture.get_width();
    uint depthH = depthTexture.get_height();

    if (id.x >= depthW || id.y >= depthH) {
        return;
    }

    // Each depth pixel produces 4 vertices (a billboard quad)
    uint pixelIndex = id.y * depthW + id.x;
    uint baseVertex = pixelIndex * 4;
    float depth = depthTexture.read(id).r;

    // UV for sampling camera image (matches depth map landscape-left orientation)
    float2 cameraUV = float2((float(id.x) + 0.5) / float(depthW),
                             (float(id.y) + 0.5) / float(depthH));

    // UV for vertex → color texture mapping.
    // RealityKit uses OpenGL convention (UV origin at bottom-left) but Metal
    // writes textures with origin at top-left. Flip V to correct this.
    // In landscape-left space this V-flip becomes a horizontal flip in portrait.
    float2 vertexUV = float2(cameraUV.x, 1.0 - cameraUV.y);

    // Zero out all 4 vertices for invalid depth
    float3 zero_pos = float3(0, 0, 0);
    float2 zero_uv = float2(0, 0);

    if (isnan(depth) || depth <= 0.0 || depth > 5.0) {
        colorOutput.write(float4(0, 0, 0, 0), id);
        writeVertex(vertices, baseVertex + 0, zero_pos, zero_uv);
        writeVertex(vertices, baseVertex + 1, zero_pos, zero_uv);
        writeVertex(vertices, baseVertex + 2, zero_pos, zero_uv);
        writeVertex(vertices, baseVertex + 3, zero_pos, zero_uv);
        return;
    }

    // Confidence filter: 0=Low, 1=Medium, 2=High. Only keep High confidence.
    uint conf = confidenceTexture.read(id).r;
    if (conf < 2) {
        colorOutput.write(float4(0, 0, 0, 0), id);
        writeVertex(vertices, baseVertex + 0, zero_pos, zero_uv);
        writeVertex(vertices, baseVertex + 1, zero_pos, zero_uv);
        writeVertex(vertices, baseVertex + 2, zero_pos, zero_uv);
        writeVertex(vertices, baseVertex + 3, zero_pos, zero_uv);
        return;
    }

    // Both depth map and camera image are in landscape-left native sensor orientation.
    // No rotation needed — sample camera at the same UV as depth.

    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Check segmentation (privacy filter)
    if (uniforms.useSegmentation > 0) {
        float segValue = segTexture.sample(s, cameraUV).r;
        if (segValue > 0.5) {
            colorOutput.write(float4(0, 0, 0, 0), id);
            writeVertex(vertices, baseVertex + 0, zero_pos, zero_uv);
            writeVertex(vertices, baseVertex + 1, zero_pos, zero_uv);
            writeVertex(vertices, baseVertex + 2, zero_pos, zero_uv);
            writeVertex(vertices, baseVertex + 3, zero_pos, zero_uv);
            return;
        }
    }

    // Sample YCbCr camera image and convert to RGB (BT.601 full-range)
    float y = imageYTexture.sample(s, cameraUV).r;
    float2 cbcr = imageCbCrTexture.sample(s, cameraUV).rg;

    float4 ycbcr = float4(y, cbcr.x, cbcr.y, 1.0);
    float4 rgb = ycbcrToRGBTransform * ycbcr;
    // Clamp — YCbCr→RGB can produce out-of-range values at color extremes
    rgb = clamp(rgb, 0.0, 1.0);

    // Write color to the output texture (sampled by UnlitMaterial via UV)
    colorOutput.write(float4(rgb.rgb, 1.0), id);

    // Calculate 3D position from depth and intrinsics
    float x = (float(id.x) - uniforms.intrinsics[2][0]) * depth / uniforms.intrinsics[0][0];
    float y_pos = (float(id.y) - uniforms.intrinsics[2][1]) * depth / uniforms.intrinsics[1][1];

    // ARKit camera space: X=right, Y=up, Z=backward (towards user)
    // Image coords: X=right, Y=down → invert Y, negate Z
    float3 cameraSpacePosition = float3(x, -y_pos, -depth);

    // Transform to world space
    float4 worldSpacePosition = uniforms.cameraTransform * float4(cameraSpacePosition, 1.0);
    float3 center = worldSpacePosition.xyz;

    // Billboard quad: scale size with depth for consistent visual density
    float halfSize = clamp(depth * 0.004, 0.0015, 0.008);

    // Camera right and up vectors for screen-facing billboards
    float3 camRight = float3(uniforms.cameraTransform[0][0],
                             uniforms.cameraTransform[0][1],
                             uniforms.cameraTransform[0][2]);
    float3 camUp = float3(uniforms.cameraTransform[1][0],
                          uniforms.cameraTransform[1][1],
                          uniforms.cameraTransform[1][2]);

    // Emit 4 vertices of a screen-facing quad: BL, BR, TL, TR
    // All 4 vertices share the same vertexUV — they sample one texel from the color texture
    writeVertex(vertices, baseVertex + 0, center + (-camRight - camUp) * halfSize, vertexUV);
    writeVertex(vertices, baseVertex + 1, center + ( camRight - camUp) * halfSize, vertexUV);
    writeVertex(vertices, baseVertex + 2, center + (-camRight + camUp) * halfSize, vertexUV);
    writeVertex(vertices, baseVertex + 3, center + ( camRight + camUp) * halfSize, vertexUV);
}
