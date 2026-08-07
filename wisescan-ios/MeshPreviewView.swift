import SwiftUI
import SwiftData
import SceneKit
import Combine

/// Wrapper that overlays 2D privacy markers on the SceneKit mesh preview.
/// Face anchor 3D positions are projected to screen coordinates each frame.
struct MeshPreviewContainer: View {
    var location: ScanLocation?
    var meshFileURL: URL?
    var colorsFileURL: URL?
    var scanDirectoryURL: URL?
    /// Scan name for the preview title (nil hides the title row).
    var scanName: String?
    /// Whether the high-quality photo colorize has run. Drives the color-state note:
    /// false = fast normals-shaded placeholder (colors not final).
    var isColored: Bool = false

    @StateObject private var markerState = MarkerProjectionState()
    @State private var isUpdating = false
    @State private var isViewerReady = false
    @State private var semanticViewMode: SemanticViewMode = .meshOnly
    @State private var showPrivacyMarkers = true
    @State private var detectedClasses: [SemanticClass] = []
    @State private var hasPrivacyMarkers = false
    @State private var isMeshLoaded = false
    @State private var keyframeMarkerMode: KeyframeMarkerMode = .none
    @State private var sceneBox = SceneViewBox()
    @State private var hasKeyframeMarkers = false
    @State private var hasEquirects = false
    @State private var showSetPoseConfirm = false
    /// Which geometry is drawn (full mesh vs ghost proxy) — orthogonal to `semanticViewMode`.
    @State private var meshSourceMode: MeshSourceMode = .full
    /// Set by the viewer once it knows the proxy artifact actually parsed (same pattern as
    /// `hasPrivacyMarkers`/`hasKeyframeMarkers`) — a file-existence check would offer the toggle
    /// for a proxy that then fails to build.
    @State private var hasProxyMesh = false
    /// True once the dynamic mesh artifact parsed — gates the source-mode toggle alongside proxy.
    @State private var hasDynamicMesh = false
    /// Canonical frame from the location's ORIGINAL scan (see `canonicalRoomFrame`), resolved
    /// before the viewer mounts so all of a location's scans preview through an identical view.
    @State private var canonicalFrame: (center: SIMD3<Float>, span: Float)?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            if isViewerReady {
                // The SceneKit view and the projected privacy markers share ONE coordinate
                // space and both bleed under the safe area, so the markers stay aligned with
                // SceneKit's projectPoint output. The title/legend live outside this and
                // respect the safe area (see below).
                ZStack {
                    MeshPreviewView(
                        meshFileURL: meshFileURL,
                        colorsFileURL: colorsFileURL,
                        scanDirectoryURL: scanDirectoryURL,
                        frameCenter: canonicalFrame?.center,
                        frameSpan: canonicalFrame?.span,
                        initialPoseMatrix: location?.imagingPoseMatrix,
                        markerState: markerState,
                        isMeshLoaded: $isMeshLoaded,
                        semanticViewMode: $semanticViewMode,
                        detectedClasses: $detectedClasses,
                        hasPrivacyMarkers: $hasPrivacyMarkers,
                        keyframeMarkerMode: $keyframeMarkerMode,
                        hasKeyframeMarkers: $hasKeyframeMarkers,
                        hasEquirects: $hasEquirects,
                        sceneBox: sceneBox,
                        meshSourceMode: $meshSourceMode,
                        hasProxyMesh: $hasProxyMesh,
                        hasDynamicMesh: $hasDynamicMesh
                    )

                    // 2D overlay icons projected from 3D face anchor positions
                    if showPrivacyMarkers {
                        ForEach(markerState.screenPositions.indices, id: \.self) { i in
                            let pos = markerState.screenPositions[i]
                            if pos.isVisible {
                                Image(systemName: "eye.slash.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.red)
                                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                                    .position(x: pos.point.x, y: pos.point.y)
                            }
                        }
                    }
                }
                .ignoresSafeArea()

                // Bottom-left legend (semantic classes + privacy + capture markers)
                let showSemanticLegend = detectedClasses.count > 0 && semanticViewMode != .meshOnly
                let showPrivacyLegend = hasPrivacyMarkers && showPrivacyMarkers
                let showStillsLegend = keyframeMarkerMode.showStills && hasKeyframeMarkers
                let showEquirectLegend = keyframeMarkerMode.showEquirectFaces && hasEquirects
                if showSemanticLegend || showPrivacyLegend || showStillsLegend || showEquirectLegend {
                    VStack(alignment: .leading, spacing: 4) {
                        if showSemanticLegend {
                            ForEach(detectedClasses, id: \.rawValue) { cls in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(cls.swiftUIDisplayColor)
                                        .frame(width: 10, height: 10)
                                    Text(cls.rawValue.capitalized)
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        if showPrivacyLegend {
                            HStack(spacing: 6) {
                                Image(systemName: "eye.slash.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                                Text("Privacy")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                            }
                        }
                        if showStillsLegend {
                            captureLegendRow(color: AppConstants.keyframeStillColor, label: "Stills")
                            if keyframeMarkerMode.showMotion {
                                captureLegendRow(color: AppConstants.keyframeMotionColor, label: "Motion")
                            }
                        }
                        if showEquirectLegend {
                            equirectLegendRow
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
                }
            }

            // Show loading indicator until mesh is fully parsed and rendered.
            // Full-bleed opaque cover (ignores the safe area) so no default background
            // shows through at the screen edges during load.
            if !isMeshLoaded {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.7)))
                        .scaleEffect(1.5)
                    Text("Loading Mesh...")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.15))
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if isUpdating {
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Updating Previews...")
                        .foregroundColor(.white)
                        .font(.caption)
                }
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(12)
            }

            // Title + preview-state note — small, centered. This layer respects the safe
            // area, and inside a NavigationView the top safe-area inset already includes the
            // nav bar, so top-alignment sits just BELOW the toolbar buttons and clear of the
            // Dynamic Island / camera array. Last in the ZStack so it stays legible over both
            // the mesh and the loading screen.
            if let scanName = scanName {
                previewTitle(scanName: scanName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            if hasPrivacyMarkers {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showPrivacyMarkers.toggle()
                    } label: {
                        Image(systemName: showPrivacyMarkers ? "eye.slash.fill" : "eye.slash")
                            .foregroundColor(showPrivacyMarkers ? .red : .gray)
                    }
                }
            }
            if !detectedClasses.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        semanticViewMode = semanticViewMode.next
                    } label: {
                        Image(systemName: semanticViewMode.iconName)
                    }
                }
            }
            if hasKeyframeMarkers {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        keyframeMarkerMode = keyframeMarkerMode.next(hasEquirects: hasEquirects)
                    } label: {
                        Image(systemName: keyframeMarkerMode.iconName)
                            .foregroundColor(keyframeMarkerMode == .none ? .gray : .cyan)
                    }
                }
            }
            if hasProxyMesh || hasDynamicMesh {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        meshSourceMode = meshSourceMode.next
                    } label: {
                        Image(systemName: meshSourceMode.iconName)
                            .foregroundColor(meshSourceMode == .full ? .gray : .yellow)
                    }
                    .accessibilityLabel(meshSourceMode.accessibilityLabel)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                // Pinch zoom-out is capped by the default camera controller; this steps
                // the camera back 40% per tap so tall marker spheres etc. stay reachable.
                Button { sceneBox.zoomOut() } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(!isMeshLoaded)
            }
            if location != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Icon-only to keep the trailing bar uncrowded alongside the privacy/
                    // semantic/keyframe toggles. A confirmation dialog names the action for
                    // sighted users; the accessibility label names it for VoiceOver.
                    Button {
                        showSetPoseConfirm = true
                    } label: {
                        Image(systemName: "camera.viewfinder")
                    }
                    .accessibilityLabel("Set Default Pose")
                    .disabled(isUpdating || !isMeshLoaded)
                }
            }
        }
        .confirmationDialog("Set Default Pose", isPresented: $showSetPoseConfirm, titleVisibility: .visible) {
            Button("Set Default Pose") { savePoseAndUpdate() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Save the current view angle as this location's default preview pose, then regenerate every scan's thumbnail from this viewpoint.")
        }
        .onAppear {
            // Defer the heavy OBJ parsing to ensure the fullScreenCover animation completes smoothly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Resolve the location's canonical frame from its ORIGINAL (earliest) scan before
                // mounting the viewer — every generation then renders at the same offset/zoom and
                // cross-scan misalignment reads true. Tiny JSON decode; fine on main.
                if let original = location?.scans.min(by: CapturedScan.canonicalOrder) {
                    canonicalFrame = MeshPreviewView.canonicalRoomFrame(scanDirectoryURL: original.scanDirectory)
                }
                isViewerReady = true
            }
        }
    }

    /// Centered preview title: "Location · Scan" plus a preview-state note. The note flags
    /// that this is the on-device mesh preview, not the final render, and whether its colors
    /// are the fast normals-shaded placeholder (amber) or the photo colorize (green).
    private func previewTitle(scanName: String) -> some View {
        let heading = [location?.name, scanName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return VStack(spacing: 2) {
            if !heading.isEmpty {
                Text(heading)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Proxy/dynamic take over the note: their colors are never the photo colorize
            // (colors.bin is aligned to mesh.obj's vertices, which both compact), and their
            // dropped faces are by design — say so rather than let it read as a bad scan.
            if meshSourceMode == .dynamic {
                Text("Preview · dynamic · content only, no walls/floor/ceiling")
                    .font(.caption2)
                    .foregroundColor(.yellow)
            } else if let tag = meshSourceMode.titleTag {
                Text("Preview · \(tag) · height shading, faces dropped by design")
                    .font(.caption2)
                    .foregroundColor(.yellow)
            } else {
                Text(isColored ? "Preview · colored mesh" : "Preview · shading only, colors not final")
                    .font(.caption2)
                    .foregroundColor(isColored ? .green : .orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.3), radius: 2)
        .padding(.horizontal, 60) // keep clear of leading/trailing toolbar buttons
    }

    private var equirectLegendRow: some View {
        HStack(spacing: 6) {
            let accent = AppConstants.equirectFrontColor
            Circle()
                .fill(Color(red: Double(accent.x), green: Double(accent.y), blue: Double(accent.z)))
                .frame(width: 8, height: 8)
            Text("360° stills (arrow = front)").font(.caption2).foregroundColor(.white)
        }
    }

    /// One legend row for a capture-marker group (colored square + label).
    private func captureLegendRow(color: SIMD4<Float>, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption2)
                .foregroundColor(.white)
        }
    }

    private func savePoseAndUpdate() {
        guard let location = location, let pose = markerState.currentPoseMatrix() else { return }
        location.imagingPoseMatrix = pose
        try? modelContext.save()
        isUpdating = true

        Task {
            let scans = location.scans
            // Same canonical frame the interactive viewer centered with when the pose was saved —
            // every scan's thumbnail then shows the identical view (nil → legacy bbox centering).
            let frameCenter = canonicalFrame?.center
            for scan in scans {
                // Ensure mesh exists
                guard FileManager.default.fileExists(atPath: scan.meshFileURL.path) else { continue }
                if let img = await Task.detached(priority: .userInitiated, operation: {
                    MeshPreviewView.generateSnapshot(meshURL: scan.meshFileURL, colorsURL: scan.colorsFileURL,
                                                     poseMatrix: pose, frameCenter: frameCenter)
                }).value, let data = img.jpegData(compressionQuality: 0.8) {
                    try? data.write(to: scan.modelPreviewURL)
                }
            }
            await MainActor.run {
                location.updatedAt = Date()
                isUpdating = false
            }
        }
    }
}

/// Published state for projected 2D marker positions.
class MarkerProjectionState: ObservableObject {
    struct MarkerScreenPos: Equatable {
        var point: CGPoint
        var isVisible: Bool
    }

    @Published var screenPositions: [MarkerScreenPos] = []

    /// 3D anchor positions in scene-local coordinates (with center offset applied)
    var anchorPositions: [SCNVector3] = []
    /// Reference to the SCNView for projection
    weak var scnView: SCNView?
    /// Tracks whether the last update had no markers, so the common (no-marker) case
    /// doesn't dispatch to main or republish on every rendered frame.
    private var lastWasEmpty = false

    func updateProjections() {
        guard let scnView = scnView else { return }

        // Common case: no privacy markers. Clear once, then do nothing per frame.
        // (updateProjections is called from the SceneKit render thread on every frame.)
        if anchorPositions.isEmpty {
            if lastWasEmpty { return }
            lastWasEmpty = true
            DispatchQueue.main.async { self.screenPositions = [] }
            return
        }
        lastWasEmpty = false

        DispatchQueue.main.async {
            guard scnView.pointOfView != nil else { return }
            var newPositions: [MarkerScreenPos] = []
            let boundsWidth = scnView.bounds.width
            let boundsHeight = scnView.bounds.height
            for anchor in self.anchorPositions {
                let projected = scnView.projectPoint(anchor)
                let screenPoint = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                let visible = projected.z > 0 && projected.z < 1
                    && screenPoint.x >= 0 && screenPoint.x <= boundsWidth
                    && screenPoint.y >= 0 && screenPoint.y <= boundsHeight
                newPositions.append(MarkerScreenPos(point: screenPoint, isVisible: visible))
            }
            // Skip the publish (and SwiftUI re-render) when nothing moved on screen.
            if newPositions != self.screenPositions {
                self.screenPositions = newPositions
            }
        }
    }

    func currentPoseMatrix() -> [Float]? {
        guard let transform = scnView?.pointOfView?.transform else { return nil }
        return [
            transform.m11, transform.m12, transform.m13, transform.m14,
            transform.m21, transform.m22, transform.m23, transform.m24,
            transform.m31, transform.m32, transform.m33, transform.m34,
            transform.m41, transform.m42, transform.m43, transform.m44
        ]
    }
}

/// Renders a 3D preview of captured OBJ mesh data using SceneKit.
/// Bridges the SwiftUI toolbar to the live SCNView for programmatic camera moves:
/// the default camera controller caps pinch zoom-out (widening the scene bounds did
/// NOT lift it — device-tested), so the toolbar offers an explicit step-back instead.
final class SceneViewBox {
    weak var view: SCNView?

    /// Dolly the point of view 40% farther from the origin-centered model. Works on the
    /// interactive camera clone too (allowsCameraControl), so it composes with gestures.
    func zoomOut() {
        guard let pov = view?.pointOfView else { return }
        pov.position = SCNVector3(pov.position.x * 1.4,
                                  pov.position.y * 1.4,
                                  pov.position.z * 1.4)
    }
}

struct MeshPreviewView: UIViewRepresentable {
    var meshFileURL: URL?
    var colorsFileURL: URL?
    var scanDirectoryURL: URL?
    /// Canonical preview frame (center + span) shared by every scan of a location — derived from
    /// the ORIGINAL scan's RoomPlan room, not this mesh's own bounding box. With it, all of a
    /// location's scans render at the same offset/rotation/zoom, so flipping between previews
    /// shows TRUE residual misalignment (the 4D shared-coordinate-space contract). nil falls back
    /// to per-mesh bbox centering (scans with no location / pre-RoomPlan scans).
    var frameCenter: SIMD3<Float>?
    var frameSpan: Float?
    /// The location's user-set default pose ("Set Default Pose" → `location.imagingPoseMatrix`),
    /// in scene coordinates (world − frameCenter). When set, it overrides the stock camera as the
    /// initial view. Per-LOCATION, and the canonical frame makes scene coords identical across a
    /// location's scans — so rescans still line up under a user-specified default, same as the
    /// stock one. (User can still orbit freely; this is only the starting view.)
    var initialPoseMatrix: [Float]?
    var markerState: MarkerProjectionState
    @Binding var isMeshLoaded: Bool
    @Binding var semanticViewMode: SemanticViewMode
    @Binding var detectedClasses: [SemanticClass]
    @Binding var hasPrivacyMarkers: Bool
    @Binding var keyframeMarkerMode: KeyframeMarkerMode
    @Binding var hasKeyframeMarkers: Bool
    @Binding var hasEquirects: Bool
    let sceneBox: SceneViewBox
    @Binding var meshSourceMode: MeshSourceMode
    @Binding var hasProxyMesh: Bool
    @Binding var hasDynamicMesh: Bool

    /// The ghost proxy artifact for a scan directory, if present — scan-dir top level then
    /// `raw_data/` (the same two-candidate resolution the metadata/roomplan readers use, since
    /// `writeBoth` mirrors the proxy into both).
    static func proxyMeshURL(scanDirectoryURL: URL?) -> URL? {
        guard let dir = scanDirectoryURL else { return nil }
        let candidates = [
            dir.appendingPathComponent("mesh_proxy.obj"),
            dir.appendingPathComponent("raw_data").appendingPathComponent("mesh_proxy.obj")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The dynamic mesh artifact for a scan directory, if present — same two-candidate resolution
    /// as `proxyMeshURL`.
    static func dynamicMeshURL(scanDirectoryURL: URL?) -> URL? {
        guard let dir = scanDirectoryURL else { return nil }
        let candidates = [
            dir.appendingPathComponent("mesh_dynamic.obj"),
            dir.appendingPathComponent("raw_data").appendingPathComponent("mesh_dynamic.obj")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Mesh visibility across BOTH axes: `SemanticViewMode` decides whether any geometry shows,
    /// `MeshSourceMode` decides which one. Falls back to the full mesh when the requested
    /// alternate never built, so the view can never end up empty.
    private func applyMeshVisibility(_ coordinator: Coordinator) {
        let showMesh = semanticViewMode.showMesh
        // Fall back to .full when the requested source's node doesn't exist.
        let source: MeshSourceMode
        switch meshSourceMode {
        case .proxy   where coordinator.proxyMeshNode != nil:   source = .proxy
        case .dynamic where coordinator.dynamicMeshNode != nil: source = .dynamic
        default: source = .full
        }
        coordinator.meshNode?.isHidden        = !(showMesh && source == .full)
        coordinator.proxyMeshNode?.isHidden   = !(showMesh && source == .proxy)
        coordinator.dynamicMeshNode?.isHidden = !(showMesh && source == .dynamic)
    }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        sceneBox.view = scnView
        scnView.backgroundColor = UIColor(white: 0.15, alpha: 1.0) // charcoal background
        scnView.allowsCameraControl = true // user can rotate/zoom
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scnView.scene = scene
        scnView.delegate = context.coordinator

        // Lighting setup for better visibility
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = UIColor(white: 0.4, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        let directionalLight = SCNNode()
        directionalLight.light = SCNLight()
        directionalLight.light?.type = .directional
        directionalLight.light?.color = UIColor(white: 0.8, alpha: 1.0)
        directionalLight.light?.castsShadow = true
        directionalLight.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(directionalLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.color = UIColor(white: 0.3, alpha: 1.0)
        fillLight.eulerAngles = SCNVector3(Float.pi / 4, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fillLight)

        let rigProfile = RigProfile.load()

        // Dispatch to background queue for loading files and parsing OBJ
        DispatchQueue.global(qos: .userInitiated).async { [rigProfile] in
            var meshData: Data?
            var colorsData: Data?

            if let meshURL = meshFileURL {
                meshData = try? Data(contentsOf: meshURL)
            }
            if let colorsURL = colorsFileURL {
                colorsData = try? Data(contentsOf: colorsURL)
            }

            // Ghost proxy, loaded alongside so the source toggle is instant and keeps the
            // camera (the alternative — reloading on switch — would tear down the SCNView).
            // Frame-consistent with mesh.obj by construction (ScanPostprocessor rebuilds it
            // whenever a late registration moves the mesh), so it needs no separate transform.
            // NO vertex colors: colors.bin is per-vertex against mesh.obj and the proxy compacts
            // vertices + appends quad corners, so it renders height-shaded instead.
            var proxyGeometry: SCNGeometry?
            if let proxyURL = Self.proxyMeshURL(scanDirectoryURL: self.scanDirectoryURL),
               let proxyData = try? Data(contentsOf: proxyURL) {
                proxyGeometry = Self.buildGeometry(from: proxyData, vertexColors: nil)?.0
            }

            // Dynamic mesh (content only, no infrastructure) — same loading pattern as proxy.
            var dynamicGeometry: SCNGeometry?
            if let dynamicURL = Self.dynamicMeshURL(scanDirectoryURL: self.scanDirectoryURL),
               let dynamicData = try? Data(contentsOf: dynamicURL) {
                dynamicGeometry = Self.buildGeometry(from: dynamicData, vertexColors: nil)?.0
            }

            var faceAnchors: [SCNVector3] = []
            if let scanDir = self.scanDirectoryURL {
                // Check both raw_data/ subdirectory and scan root (mirrors export logic)
                let candidates = [
                    scanDir.appendingPathComponent("raw_data").appendingPathComponent("scan4d_metadata.json"),
                    scanDir.appendingPathComponent("scan4d_metadata.json")
                ]
                for jsonURL in candidates {
                    if let data = try? Data(contentsOf: jsonURL),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let anchors = dict["face_anchors"] as? [[String: NSNumber]] {
                        for a in anchors {
                            if let x = a["x"]?.floatValue,
                               let y = a["y"]?.floatValue,
                               let z = a["z"]?.floatValue {
                                faceAnchors.append(SCNVector3(x, y, z))
                            }
                        }
                        break // found it, stop searching
                    }
                }
            }

            if let md = meshData, let (geometry, _) = Self.buildGeometry(from: md, vertexColors: colorsData) {
                // Build semantic outlines from RoomPlan data (roomplan.json)
                let semanticOutlines = Self.buildRoomPlanOutlines(
                    scanDirectoryURL: self.scanDirectoryURL
                )

                // Build still + motion capture-pose frustum markers from the saved poses
                // (transforms.json). Derived entirely from existing raw data — no capture-time
                // cost, and built here off-main (JSON parse + node flattening) so the one-time
                // preview attach on main stays cheap. The three-tier mode toggles visibility.
                let markerNodes = Self.buildKeyframeMarkerNodes(scanDirectoryURL: self.scanDirectoryURL, rigProfile: rigProfile)

                DispatchQueue.main.async {
                    let node = SCNNode(geometry: geometry)
                    node.name = "mesh"

                    // Center the model: on the location's canonical frame when provided (every
                    // scan of the location gets the SAME shift, so cross-scan offset is honest),
                    // else on this mesh's own bbox (legacy single-scan behaviour).
                    let (minBound, maxBound) = node.boundingBox
                    let center = frameCenter.map { SCNVector3($0.x, $0.y, $0.z) } ?? SCNVector3(
                        (minBound.x + maxBound.x) / 2,
                        (minBound.y + maxBound.y) / 2,
                        (minBound.z + maxBound.z) / 2
                    )
                    node.position = SCNVector3(-center.x, -center.y, -center.z)

                    // Store face anchor positions for 2D projection (offset by center)
                    // Anchors are in the node's local space, which is shifted by -center
                    // projectPoint needs world-space coords, so final = anchor - center
                    self.markerState.anchorPositions = faceAnchors.map { a in
                        SCNVector3(a.x - center.x, a.y - center.y, a.z - center.z)
                    }
                    self.markerState.scnView = scnView
                    self.hasPrivacyMarkers = !faceAnchors.isEmpty

                    // Wrap in a parent to keep centering clean
                    let containerNode = SCNNode()
                    containerNode.addChildNode(node)

                    // Proxy rides the SAME center as the full mesh (not its own bbox) — they're
                    // in one frame, so a shared offset keeps them coincident and toggling shows
                    // true differences rather than a re-centering shift.
                    var proxyNode: SCNNode?
                    if let proxyGeometry {
                        let pNode = SCNNode(geometry: proxyGeometry)
                        pNode.name = "proxyMesh"
                        pNode.position = SCNVector3(-center.x, -center.y, -center.z)
                        containerNode.addChildNode(pNode)
                        proxyNode = pNode
                    }
                    self.hasProxyMesh = proxyNode != nil

                    // Dynamic mesh rides the same center as full + proxy.
                    var dynamicNode: SCNNode?
                    if let dynamicGeometry {
                        let dNode = SCNNode(geometry: dynamicGeometry)
                        dNode.name = "dynamicMesh"
                        dNode.position = SCNVector3(-center.x, -center.y, -center.z)
                        containerNode.addChildNode(dNode)
                        dynamicNode = dNode
                    }
                    self.hasDynamicMesh = dynamicNode != nil

                    // Add semantic classification outlines + fills (same center offset as mesh)
                    if let outlines = semanticOutlines {
                        let semanticsNode = SCNNode()
                        semanticsNode.name = "semantics"
                        let fillsNode = SCNNode()
                        fillsNode.name = "semanticFills"
                        for outline in outlines.outlineNodes {
                            let wireNode = SCNNode(geometry: outline.geometry)
                            wireNode.position = SCNVector3(-center.x, -center.y, -center.z)
                            semanticsNode.addChildNode(wireNode)

                            let fNode = SCNNode(geometry: outline.fillGeometry)
                            fNode.position = SCNVector3(-center.x, -center.y, -center.z)
                            fillsNode.addChildNode(fNode)
                        }
                        containerNode.addChildNode(semanticsNode)
                        containerNode.addChildNode(fillsNode)
                        self.detectedClasses = outlines.detectedClasses
                    }

                    // Attach the pre-built still + motion capture-pose markers (same world
                    // frame as the mesh; the centering offset is applied here).
                    self.attachKeyframeMarkers(
                        markerNodes, to: containerNode, coordinator: context.coordinator, center: center
                    )

                    scene.rootNode.addChildNode(containerNode)
                    context.coordinator.meshNode = node
                    context.coordinator.proxyMeshNode = proxyNode
                    context.coordinator.dynamicMeshNode = dynamicNode
                    context.coordinator.semanticsNode = scene.rootNode
                        .childNode(withName: "semantics", recursively: true)
                    context.coordinator.semanticFillsNode = scene.rootNode
                        .childNode(withName: "semanticFills", recursively: true)

                    // Apply initial visibility based on the current mode
                    let mode = self.semanticViewMode
                    self.applyMeshVisibility(context.coordinator)
                    context.coordinator.semanticsNode?.isHidden = !mode.showOutlines
                    context.coordinator.semanticFillsNode?.isHidden = !mode.showFills

                    // Position camera from the canonical span when provided (fixed zoom across
                    // a location's scans; the angle below is already fixed), else this model's size.
                    let size = SCNVector3(
                        maxBound.x - minBound.x,
                        maxBound.y - minBound.y,
                        maxBound.z - minBound.z
                    )
                    let maxDimension = frameSpan ?? max(size.x, max(size.y, size.z))

                    let cameraNode = SCNNode()
                    cameraNode.camera = SCNCamera()
                    cameraNode.camera?.automaticallyAdjustsZRange = true
                    if let matrix = initialPoseMatrix, matrix.count == 16 {
                        // User-set default pose (same matrix the thumbnails render with).
                        cameraNode.transform = SCNMatrix4(
                            m11: matrix[0], m12: matrix[1], m13: matrix[2], m14: matrix[3],
                            m21: matrix[4], m22: matrix[5], m23: matrix[6], m24: matrix[7],
                            m31: matrix[8], m32: matrix[9], m33: matrix[10], m34: matrix[11],
                            m41: matrix[12], m42: matrix[13], m43: matrix[14], m44: matrix[15]
                        )
                    } else {
                        cameraNode.position = SCNVector3(0, maxDimension * 0.3, maxDimension * 0.4)
                        cameraNode.look(at: SCNVector3Zero)
                    }
                    scene.rootNode.addChildNode(cameraNode)

                    // Signal that mesh is ready
                    self.isMeshLoaded = true
                }
            }
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let mode = semanticViewMode
        applyMeshVisibility(context.coordinator)
        context.coordinator.semanticsNode?.isHidden = !mode.showOutlines
        context.coordinator.semanticFillsNode?.isHidden = !mode.showFills
        context.coordinator.keyframeStillsNode?.isHidden = !keyframeMarkerMode.showStills
        context.coordinator.keyframeMotionNode?.isHidden = !keyframeMarkerMode.showMotion
        context.coordinator.equirectFacesNode?.isHidden = !keyframeMarkerMode.showEquirectFaces
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(markerState: markerState)
    }

    class Coordinator: NSObject, SCNSceneRendererDelegate {
        let markerState: MarkerProjectionState
        /// Reference to the mesh geometry node for toggling visibility.
        weak var meshNode: SCNNode?
        /// Reference to the ghost-proxy geometry node; nil when no proxy artifact parsed.
        weak var proxyMeshNode: SCNNode?
        /// Reference to the dynamic (content-only) geometry node; nil when no dynamic artifact parsed.
        weak var dynamicMeshNode: SCNNode?
        /// Reference to the semantics outline (wireframe) node for toggling visibility.
        weak var semanticsNode: SCNNode?
        /// Reference to the semantics fill (translucent faces) node for toggling visibility.
        weak var semanticFillsNode: SCNNode?
        /// Reference to the still (keyframe) capture-marker container for toggling visibility.
        weak var keyframeStillsNode: SCNNode?
        /// Reference to the motion (sweep) capture-marker container for toggling visibility.
        weak var keyframeMotionNode: SCNNode?
        /// Reference to the equirect cube-face frustum container for toggling visibility.
        weak var equirectFacesNode: SCNNode?

        init(markerState: MarkerProjectionState) {
            self.markerState = markerState
        }

        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            markerState.updateProjections()
        }
    }

    /// Parses OBJ data and creates geometry with vertex colors (camera-sampled or height-based fallback).
    ///
    /// `heightRange` overrides the height ramp's normalization: pass a range shared across several
    /// meshes (with each one's `heightTransform`) so one color means one height across all of them,
    /// instead of each mesh normalizing to its own extent. Both nil = this mesh's own local extent,
    /// which is what a single-mesh preview wants.
    nonisolated static func buildGeometry(from data: Data, vertexColors: Data?,
                                          heightRange: (min: Float, max: Float)? = nil,
                                          heightTransform: simd_float4x4? = nil) -> (SCNGeometry, Int)? {
        guard let parsed = MeshParser.parseOBJ(from: data) else { return nil }

        let vertices: [SCNVector3] = parsed.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        var indices: [UInt32] = []
        for face in parsed.faces {
            indices.append(contentsOf: [face.0, face.1, face.2])
        }

        let minY: Float, maxY: Float
        if let heightRange {
            (minY, maxY) = (heightRange.min, heightRange.max)
        } else {
            var lo: Float = .greatestFiniteMagnitude
            var hi: Float = -.greatestFiniteMagnitude
            for v in parsed.vertices {
                lo = min(lo, v.y)
                hi = max(hi, v.y)
            }
            (minY, maxY) = (lo, hi)
        }

        guard !vertices.isEmpty && !indices.isEmpty else { return nil }

        // Use camera colors if available, otherwise height gradient
        var colors: [SIMD4<Float>]
        var hasCameraColors = false
        if let colorData = vertexColors {
            let count = colorData.count / MemoryLayout<SIMD4<Float>>.stride
            if count == vertices.count {
                colors = [SIMD4<Float>](repeating: .zero, count: count)
                _ = colors.withUnsafeMutableBytes { ptr in
                    colorData.copyBytes(to: ptr)
                }
                hasCameraColors = true
            } else {
                // Count mismatch — fall back to gradient
                colors = heightGradientColors(vertices: vertices, minY: minY, maxY: maxY,
                                              transform: heightTransform)
            }
        } else {
            colors = heightGradientColors(vertices: vertices, minY: minY, maxY: maxY)
        }
        // Subdivide mesh for smoother vertex color interpolation
        // Each triangle → 4 sub-triangles via edge midpoints
        var subVertices = vertices
        var subColors = colors
        var subIndices = [UInt32]()
        // Cache: sorted edge pair → midpoint vertex index
        var edgeMidpoints: [UInt64: UInt32] = [:]

        func midpointIndex(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key: UInt64 = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if let existing = edgeMidpoints[key] { return existing }
            let va = subVertices[Int(a)]
            let vb = subVertices[Int(b)]
            let mid = SCNVector3((va.x + vb.x) / 2, (va.y + vb.y) / 2, (va.z + vb.z) / 2)
            let ca = subColors[Int(a)]
            let cb = subColors[Int(b)]
            let midColor = (ca + cb) / 2
            let idx = UInt32(subVertices.count)
            subVertices.append(mid)
            subColors.append(midColor)
            edgeMidpoints[key] = idx
            return idx
        }

        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            let ab = midpointIndex(a, b)
            let bc = midpointIndex(b, c)
            let ca = midpointIndex(c, a)
            // 4 sub-triangles
            subIndices.append(contentsOf: [a, ab, ca])
            subIndices.append(contentsOf: [ab, b, bc])
            subIndices.append(contentsOf: [ca, bc, c])
            subIndices.append(contentsOf: [ab, bc, ca])
        }

        // Use subdivided data for rendering
        let finalVertices = subVertices
        let finalColors = subColors
        let finalIndices = subIndices

        // Compute face normals and accumulate per-vertex for smooth shading
        var vertexNormals = [SIMD3<Float>](repeating: .zero, count: finalVertices.count)
        for i in stride(from: 0, to: finalIndices.count, by: 3) {
            let i0 = Int(finalIndices[i])
            let i1 = Int(finalIndices[i + 1])
            let i2 = Int(finalIndices[i + 2])
            guard i0 < finalVertices.count, i1 < finalVertices.count, i2 < finalVertices.count else { continue }

            let v0 = SIMD3<Float>(finalVertices[i0].x, finalVertices[i0].y, finalVertices[i0].z)
            let v1 = SIMD3<Float>(finalVertices[i1].x, finalVertices[i1].y, finalVertices[i1].z)
            let v2 = SIMD3<Float>(finalVertices[i2].x, finalVertices[i2].y, finalVertices[i2].z)

            let normal = simd_normalize(simd_cross(v1 - v0, v2 - v0))
            vertexNormals[i0] += normal
            vertexNormals[i1] += normal
            vertexNormals[i2] += normal
        }
        // Normalize
        let normals = vertexNormals.map { simd_normalize($0) }
            .map { SCNVector3($0.x, $0.y, $0.z) }

        let vertexSource = SCNGeometrySource(vertices: finalVertices)
        let normalSource = SCNGeometrySource(normals: normals)

        // Color source
        let colorData = Data(bytes: finalColors, count: finalColors.count * MemoryLayout<SIMD4<Float>>.stride)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: finalColors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        let indexData = Data(bytes: finalIndices, count: finalIndices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: finalIndices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource], elements: [element])

        let material = SCNMaterial()
        if hasCameraColors {
            // Unlit rendering for camera colors — show actual sampled colors
            material.lightingModel = .constant
        } else {
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.6
            material.metalness.contents = 0.1
        }
        material.diffuse.contents = UIColor.white // vertex colors will modulate
        material.isDoubleSided = false // Single-sided so you can see into rooms
        geometry.materials = [material]

        return (geometry, vertices.count)
    }


    /// Five evenly-spaced stops across the FULL spectrum: blue (lowest) → cyan → green → yellow →
    /// red (highest). The previous ramp pinned red to 0 and clamped the other two channels
    /// (`g = min(1.5t, 1)`, `b = max(1 - 1.5t, 0.2)`), so it swept only blue→cyan→green AND went
    /// completely FLAT above t ≈ 0.667 — the top third of every range had zero height
    /// discrimination (a whole upper flight of a stairwell rendered as one green).
    ///
    /// `transform` lifts each vertex into the space `minY`/`maxY` are expressed in. The combined
    /// render passes each map's stitch placement so every map shares ONE world-Y ramp; without it
    /// each map colors in its own local frame and a map placed a floor up repeats the ground
    /// floor's colors. Geometry stays local either way — the node transform still does the placing.
    /// nil = vertices are already in the range's space.
    nonisolated static func heightGradientColors(vertices: [SCNVector3], minY: Float, maxY: Float,
                                                 transform: simd_float4x4? = nil) -> [SIMD4<Float>] {
        let stops: [SIMD3<Float>] = [
            SIMD3(0, 0, 1),   // blue   — lowest
            SIMD3(0, 1, 1),   // cyan
            SIMD3(0, 1, 0),   // green
            SIMD3(1, 1, 0),   // yellow
            SIMD3(1, 0, 0)    // red    — highest
        ]
        let yRange = maxY - minY
        let lastSegment = stops.count - 2
        return vertices.map { v in
            let y = transform.map { ($0 * SIMD4<Float>(v.x, v.y, v.z, 1)).y } ?? v.y
            let t = yRange > 0 ? min(max((y - minY) / yRange, 0), 1) : 0.5
            let scaled = t * Float(stops.count - 1)
            let i = min(Int(scaled), lastSegment)
            let c = stops[i] + (stops[i + 1] - stops[i]) * (scaled - Float(i))
            return SIMD4<Float>(c.x, c.y, c.z, 1.0)
        }
    }

    /// World-Y extent of a parsed mesh under an optional placement transform — the per-map input
    /// to a SHARED height ramp across several placed meshes. nil for an empty mesh.
    nonisolated static func worldHeightRange(parsed: MeshParser.OBJData,
                                             transform: simd_float4x4?) -> (min: Float, max: Float)? {
        guard !parsed.vertices.isEmpty else { return nil }
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for v in parsed.vertices {
            let y = transform.map { ($0 * SIMD4<Float>(v.x, v.y, v.z, 1)).y } ?? v.y
            lo = min(lo, y); hi = max(hi, y)
        }
        return (lo, hi)
    }

    /// Generates a 2D snapshot of the mesh using an offscreen renderer. Pass the location's
    /// canonical `frameCenter` alongside a saved `poseMatrix` — the pose is expressed in scene
    /// coords (world − frameCenter), so all of a location's thumbnails must center identically
    /// for one pose to mean the same view across rescans.
    nonisolated static func generateSnapshot(meshURL: URL, colorsURL: URL?, poseMatrix: [Float]? = nil,
                                             frameCenter: SIMD3<Float>? = nil) -> UIImage? {
        guard let meshData = try? Data(contentsOf: meshURL) else { return nil }
        let colorsData = colorsURL.flatMap { try? Data(contentsOf: $0) }
        guard let (geometry, _) = buildGeometry(from: meshData, vertexColors: colorsData) else { return nil }

        let node = SCNNode(geometry: geometry)
        let (minBound, maxBound) = node.boundingBox
        let center = frameCenter.map { SCNVector3($0.x, $0.y, $0.z) }
            ?? SCNVector3((minBound.x + maxBound.x) / 2, (minBound.y + maxBound.y) / 2, (minBound.z + maxBound.z) / 2)
        node.position = SCNVector3(-center.x, -center.y, -center.z)

        let containerNode = SCNNode()
        containerNode.addChildNode(node)

        let scene = SCNScene()
        scene.background.contents = UIColor.black
        scene.rootNode.addChildNode(containerNode)

        // Lighting
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = UIColor(white: 0.4, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        let directionalLight = SCNNode()
        directionalLight.light = SCNLight()
        directionalLight.light?.type = .directional
        directionalLight.light?.color = UIColor(white: 0.8, alpha: 1.0)
        directionalLight.light?.castsShadow = true
        directionalLight.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(directionalLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.color = UIColor(white: 0.3, alpha: 1.0)
        fillLight.eulerAngles = SCNVector3(Float.pi / 4, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fillLight)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true

        if let matrix = poseMatrix, matrix.count == 16 {
            let m = SCNMatrix4(
                m11: matrix[0], m12: matrix[1], m13: matrix[2], m14: matrix[3],
                m21: matrix[4], m22: matrix[5], m23: matrix[6], m24: matrix[7],
                m31: matrix[8], m32: matrix[9], m33: matrix[10], m34: matrix[11],
                m41: matrix[12], m42: matrix[13], m43: matrix[14], m44: matrix[15]
            )
            cameraNode.transform = m
        } else {
            let size = SCNVector3(maxBound.x - minBound.x, maxBound.y - minBound.y, maxBound.z - minBound.z)
            let maxDimension = max(size.x, max(size.y, size.z))
            cameraNode.position = SCNVector3(0, maxDimension * 0.3, maxDimension * 0.4)
            cameraNode.look(at: SCNVector3Zero)
        }
        scene.rootNode.addChildNode(cameraNode)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false

        let size = CGSize(width: 512, height: 512)
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }


    // MARK: - Semantic Outline Result

    // MARK: - Canonical preview frame

    /// The canonical preview frame for a location: AABB center + max dimension of the given
    /// scan's RoomPlan SURFACES (walls/floor — the stable structure; objects move between
    /// generations and would wobble the frame). Callers pass the location's ORIGINAL scan's
    /// directory so every generation previews through the identical view. Anchoring on the
    /// original ROOM's center (a fixed landmark of the canonical frame) rather than raw world
    /// (0,0,0) keeps the room framed on-screen — world origin is wherever the session started.
    /// nil when no roomplan.json exists (pre-RoomPlan scans) → caller falls back to bbox centering.
    nonisolated static func canonicalRoomFrame(scanDirectoryURL: URL?) -> (center: SIMD3<Float>, span: Float)? {
        guard let scanDir = scanDirectoryURL else { return nil }
        // Prefer the scan-root copy (matches artifactURL / registration / export); the raw_data/
        // mirror is only a fallback — it can momentarily lag the top-level copy while registration
        // rewrites the frame at postprocess, so reading it first risks canonical-mesh/raw-outline.
        let candidates = [
            scanDir.appendingPathComponent("roomplan.json"),
            scanDir.appendingPathComponent("raw_data").appendingPathComponent("roomplan.json")
        ]
        var exportData: RoomPlanExportData?
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(RoomPlanExportData.self, from: data) {
                exportData = decoded
                break
            }
        }
        guard let roomData = exportData, !roomData.surfaces.isEmpty else { return nil }

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        // Only the STABLE architecture (walls + floor) frames the canonical view, per the rationale
        // above — doors/windows/openings can be intermittently detected between builds and would
        // shift the AABB; furniture objects aren't in `surfaces`. Fall back to all surfaces for a
        // degenerate wall-less room so it still yields the same frame it did before.
        let framing = roomData.surfaces.filter { $0.category == "wall" || $0.category == "floor" }
        for surface in (framing.isEmpty ? roomData.surfaces : framing) {
            let dims = SIMD3<Float>(surface.dimensions.width, surface.dimensions.height, surface.dimensions.depth)
            let transform = reconstructMatrix(from: surface.transform)
            for c in orientedBoxCorners(dimensions: dims, transform: transform) {
                let p = SIMD3<Float>(c.x, c.y, c.z)
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        let size = hi - lo
        let span = max(size.x, max(size.y, size.z))
        guard span > 0.5 else { return nil } // degenerate room → not a usable frame
        return ((lo + hi) / 2, span)
    }

    /// Canonical frame center for a location — from its ORIGINAL (earliest) scan's RoomPlan room
    /// (see `canonicalRoomFrame`). Every snapshot rendered with the location's `imagingPoseMatrix`
    /// must center on this (the pose is expressed in world − center coords) or the same pose shows
    /// a different view per scan. Call where the SwiftData model is safe to touch (alongside
    /// reading `imagingPoseMatrix`) and pass the value into background snapshot work.
    static func canonicalFrameCenter(for location: ScanLocation?) -> SIMD3<Float>? {
        guard let original = location?.scans.min(by: CapturedScan.canonicalOrder) else { return nil }
        return canonicalRoomFrame(scanDirectoryURL: original.scanDirectory)?.center
    }

    /// Result from building semantic outlines: SceneKit geometry nodes + detected class list.
    struct SemanticOutlineResult {
        struct OutlineNode {
            let geometry: SCNGeometry       // wireframe edges (.line)
            let fillGeometry: SCNGeometry   // filled box faces (.triangles, 75% opacity)
        }
        let outlineNodes: [OutlineNode]
        let detectedClasses: [SemanticClass]
    }

    // MARK: - RoomPlan Outline Rendering

    /// Parses `roomplan.json` from the scan directory and generates oriented wireframe boxes
    /// for each surface and object. Unlike the legacy AABB approach, these boxes use the actual
    /// transform (rotation + position) from RoomPlan, producing accurate outlines.
    nonisolated static func buildRoomPlanOutlines(
        scanDirectoryURL: URL?
    ) -> SemanticOutlineResult? {
        guard let scanDir = scanDirectoryURL else { return nil }

        // Find roomplan.json — prefer the scan-root copy (matches artifactURL / registration /
        // export); the raw_data/ mirror is only a fallback (it can lag the top-level copy during a
        // registration frame-rewrite at postprocess).
        let candidates = [
            scanDir.appendingPathComponent("roomplan.json"),
            scanDir.appendingPathComponent("raw_data").appendingPathComponent("roomplan.json")
        ]
        var exportData: RoomPlanExportData?
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(RoomPlanExportData.self, from: data) {
                exportData = decoded
                break
            }
        }
        guard let roomData = exportData else { return nil }

        var outlineNodes: [SemanticOutlineResult.OutlineNode] = []
        var detectedSet = Set<SemanticClass>()

        // Build outlines for surfaces
        for surface in roomData.surfaces {
            let cls = SemanticClass.fromSurfaceCategory(surface.category)
            guard cls != .none else { continue }
            detectedSet.insert(cls)

            let dims = SIMD3<Float>(surface.dimensions.width, surface.dimensions.height, surface.dimensions.depth)
            let transform = reconstructMatrix(from: surface.transform)
            let wireframe = buildOrientedBoxLineGeometry(
                dimensions: dims, transform: transform, color: cls.color
            )
            // Mitigate z-fighting by lowering opacity for co-planar features
            let opacity: CGFloat = (cls == .door || cls == .window) ? 0.3 : 0.75
            let fill = buildOrientedBoxFillGeometry(
                dimensions: dims, transform: transform, color: cls.color, opacity: opacity
            )
            outlineNodes.append(SemanticOutlineResult.OutlineNode(geometry: wireframe, fillGeometry: fill))
        }

        // Build outlines for objects
        for object in roomData.objects {
            let cls = SemanticClass.fromObjectCategory(object.category)
            guard cls != .none else { continue }
            detectedSet.insert(cls)

            let dims = SIMD3<Float>(object.dimensions.width, object.dimensions.height, object.dimensions.depth)
            let transform = reconstructMatrix(from: object.transform)
            let wireframe = buildOrientedBoxLineGeometry(
                dimensions: dims, transform: transform, color: cls.color
            )
            let fill = buildOrientedBoxFillGeometry(
                dimensions: dims, transform: transform, color: cls.color, opacity: 0.75
            )
            outlineNodes.append(SemanticOutlineResult.OutlineNode(geometry: wireframe, fillGeometry: fill))
        }

        guard !outlineNodes.isEmpty else { return nil }
        let detectedClasses = SemanticClass.allCases.filter { detectedSet.contains($0) && $0 != .none }
        return SemanticOutlineResult(outlineNodes: outlineNodes, detectedClasses: detectedClasses)
    }

    /// Builds a SceneKit line geometry for an oriented bounding box (12 edges).
    /// Unlike `buildBoxLineGeometry` (axis-aligned), this applies the full 4×4 transform
    /// to produce correctly rotated outlines matching RoomPlan's detections.
    private nonisolated static func buildOrientedBoxLineGeometry(
        dimensions: SIMD3<Float>,
        transform: simd_float4x4,
        color: SIMD4<Float>
    ) -> SCNGeometry {
        let corners = orientedBoxCorners(dimensions: dimensions, transform: transform)

        let edgeIndices: [UInt32] = [
            0, 1, 1, 2, 2, 3, 3, 0,
            4, 5, 5, 6, 6, 7, 7, 4,
            0, 4, 1, 5, 2, 6, 3, 7
        ]

        let vertexSource = SCNGeometrySource(vertices: corners)
        let indexData = Data(bytes: edgeIndices, count: edgeIndices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .line,
            primitiveCount: 12,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(
            red: CGFloat(color.x), green: CGFloat(color.y),
            blue: CGFloat(color.z), alpha: 1.0
        )
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    /// Builds a SceneKit triangle geometry for an oriented bounding box (6 faces, 12 triangles).
    /// Used in "semantic only" / floor plan mode with translucent fills.
    private nonisolated static func buildOrientedBoxFillGeometry(
        dimensions: SIMD3<Float>,
        transform: simd_float4x4,
        color: SIMD4<Float>,
        opacity: CGFloat
    ) -> SCNGeometry {
        let corners = orientedBoxCorners(dimensions: dimensions, transform: transform)

        // 6 faces × 2 triangles × 3 vertices = 36 indices
        // Face winding: counter-clockwise when viewed from outside
        let faceIndices: [UInt32] = [
            // bottom (y-) 0,1,2,3
            0, 2, 1, 0, 3, 2,
            // top (y+) 4,5,6,7
            4, 5, 6, 4, 6, 7,
            // front (z+) 3,2,6,7
            3, 7, 6, 3, 6, 2,
            // back (z-) 0,1,5,4
            0, 1, 5, 0, 5, 4,
            // left (x-) 0,3,7,4
            0, 4, 7, 0, 7, 3,
            // right (x+) 1,2,6,5
            1, 2, 6, 1, 6, 5
        ]

        let vertexSource = SCNGeometrySource(vertices: corners)
        let indexData = Data(bytes: faceIndices, count: faceIndices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: 12,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(
            red: CGFloat(color.x), green: CGFloat(color.y),
            blue: CGFloat(color.z), alpha: opacity
        )
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        geometry.materials = [material]
        return geometry
    }

    /// Compute the 8 world-space corners of an oriented bounding box (shared by line + fill builders).
    private nonisolated static func orientedBoxCorners(
        dimensions: SIMD3<Float>, transform: simd_float4x4
    ) -> [SCNVector3] {
        let hx = dimensions.x / 2
        let hy = dimensions.y / 2
        let hz = dimensions.z / 2

        let localCorners: [SIMD4<Float>] = [
            SIMD4(-hx, -hy, -hz, 1), SIMD4( hx, -hy, -hz, 1),
            SIMD4( hx, -hy,  hz, 1), SIMD4(-hx, -hy,  hz, 1),
            SIMD4(-hx,  hy, -hz, 1), SIMD4( hx,  hy, -hz, 1),
            SIMD4( hx,  hy,  hz, 1), SIMD4(-hx,  hy,  hz, 1)
        ]

        return localCorners.map { lc in
            let wc = transform * lc
            return SCNVector3(wc.x, wc.y, wc.z)
        }
    }

    /// Reconstruct a simd_float4x4 from a 16-element column-major float array.
    private nonisolated static func reconstructMatrix(from flat: [Float]) -> simd_float4x4 {
        guard flat.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (
            SIMD4(flat[0], flat[1], flat[2], flat[3]),
            SIMD4(flat[4], flat[5], flat[6], flat[7]),
            SIMD4(flat[8], flat[9], flat[10], flat[11]),
            SIMD4(flat[12], flat[13], flat[14], flat[15])
        ))
    }
}

#Preview {
    // scanName/isColored exercise the title caption over the loading screen (a real
    // mesh file would be needed to render actual geometry).
    NavigationView {
        MeshPreviewContainer(scanName: "Sample Scan", isColored: false)
    }
}
