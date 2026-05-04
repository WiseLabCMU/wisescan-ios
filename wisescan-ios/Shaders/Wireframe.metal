// ============================================================================
// Wireframe.metal — RealityKit Surface Shader for barycentric wireframe rendering
// ============================================================================
//
// STATUS: CURRENTLY UNUSED — kept for reference / future iOS compatibility.
//
// This shader works correctly in isolation, but CustomMaterial is fundamentally
// incompatible with RealityKit's AR video compositing pipeline as of iOS 18.x.
//
// CRASH DETAILS:
//   -[MTLDebugRenderCommandEncoder validateCommonDrawErrors:]:6001:
//   failed assertion 'Draw Errors Validation
//   Fragment Function(realitykit::fsSurfaceMeshShadowCasterProgrammableBlending):
//   missing Buffer binding at index 25 for videoRuntimeFunctionConstants[0].'
//
// ROOT CAUSE:
//   CustomMaterial triggers RealityKit's "programmable blending" shadow caster path
//   (fsSurfaceMeshShadowCasterProgrammableBlending). This internal pipeline requires
//   a videoRuntimeFunctionConstants buffer at index 25 for AR camera passthrough
//   compositing. CustomMaterial's shader doesn't provide this buffer, causing a
//   Metal validation assertion failure.
//
//   This crash occurs regardless of blending mode (.opaque or .transparent) and
//   regardless of whether personSegmentationWithDepth is enabled. The bug is in
//   RealityKit's internal render graph — any CustomMaterial in an ARView triggers it.
//
// WORKAROUND:
//   Ghost mesh wireframe is rendered using procedural geometry (thin 3D quads for
//   each unique edge) with standard opaque UnlitMaterial. See MeshParser.swift
//   generateWireframeMeshResource(). Active scan wireframe uses RealityKit's built-in
//   .showSceneUnderstanding debug option.
//
// FUTURE PATH — ARSCNView Migration (Option 2):
//   SceneKit's ARSCNView does NOT have this compositing bug. SCNShadable /
//   SCNProgram supports custom Metal fragment shaders in AR mode without crashing.
//   MeshPreviewView.swift already uses SceneKit (SCNView) successfully with custom
//   rendering.
//
//   Migration would involve:
//   1. Replace ARView (RealityKit) with ARSCNView (SceneKit) in ARCoverageView.swift
//   2. Use SCNProgram with this Metal shader for wireframe rendering on both
//      ghost and active meshes
//   3. Convert ARMeshAnchor geometry to SCNGeometry instead of MeshResource
//   4. Convert AnchorEntity usage to SCNNode with SCNMatrix4 transforms
//   5. Replace .showSceneUnderstanding with custom SCNNode wireframe overlays
//   6. Update session delegate from ARSessionDelegate to ARSCNViewDelegate
//
//   Benefits: Full shader control, per-mesh color, true wireframe for both active
//   and ghost meshes, no compositing crashes.
//   Risk: Significant refactor of ARCoverageView rendering backend.
//
// If Apple fixes the RealityKit bug in a future iOS release, this shader can be
// re-enabled directly by using CustomMaterial in ARCoverageView.
// ============================================================================

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

[[visible]]
void wireframeSurface(realitykit::surface_parameters params) {
    // uv0 will contain the barycentric coordinates (u, v) assigned during un-indexing
    float2 uv = params.geometry().uv0();
    
    // The third barycentric coordinate w = 1.0 - u - v
    float3 barycentric = float3(uv.x, uv.y, 1.0 - uv.x - uv.y);
    
    // Find the minimum distance to an edge
    float minDist = min(barycentric.x, min(barycentric.y, barycentric.z));
    
    // Thickness threshold for the wireframe lines
    float edgeWidth = 0.03;
    
    if (minDist < edgeWidth) {
        // We are on an edge; render the line
        // We read custom_value() to get the color, or default to a color.
        // In RealityKit, custom_value is a float4 passed from Swift.
        half4 color = half4(params.uniforms().custom_parameter());
        if (color.a == 0.0) {
            // Default to green if no custom value is set
            color = half4(0.0, 1.0, 0.0, 1.0);
        }
        
        params.surface().set_base_color(color.rgb);
        params.surface().set_opacity(color.a);
    } else {
        // Inside the triangle; make it fully transparent by discarding
        discard_fragment();
    }
}
