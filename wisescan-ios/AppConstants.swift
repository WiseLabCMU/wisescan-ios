import Foundation
import CoreGraphics
import ARKit
import RoomPlan
import SwiftUI

/// Centralized repository for UI constants, app defaults, and magic numbers
/// to ensure unified aesthetics and layout calculations across the app.
enum AppConstants {
    enum CaptureMode: String, CaseIterable {
        case ar = "AR"
        case vr = "VR"
    }

    enum UI {
        // Picture-in-Picture Wearable Stream Overlay
        static let pipWidth: CGFloat = 100
        static let pipHeight: CGFloat = 150
        static let pipCornerRadius: CGFloat = 12
        static let pipBorderWidth: CGFloat = 2
        static let pipPaddingX: CGFloat = 16
        static let pipPaddingY: CGFloat = 80 // To clear the REC indicator safely
    }

    // MARK: - AppStorage Keys
    enum Key {
        static let uploadURL = "uploadURL"
        static let rawOverlapMax = "rawOverlapMax"
        static let rawRejectBlur = "rawRejectBlur"
        static let developerMode = "developerMode"
        static let mockIMU = "mockIMU"
        static let mockCameraImages = "mockCameraImages"
        static let mockDepthMaps = "mockDepthMaps"
        static let privacyFilter = "privacyFilter"
        static let mockWearable = "mockWearable"
        static let selectedExportFormat = "selectedExportFormat"
        static let activeMeshColor = "activeMeshColor"
        static let ghostMeshColor = "ghostMeshColor"
        static let metaWearablesFPS = "metaWearablesFPS"
        static let metaWearablesPermissionGranted = "metaWearablesPermissionGranted"
        static let captureMode = "captureMode"
        static let hideLivePoints = "hideLivePoints"
        static let perfDiagnostics = "perfDiagnostics"
        static let pauseVRCompute = "pauseVRCompute"
        static let vrBloomEnabled = "vrBloomEnabled"
        static let semanticLabeling = "semanticLabeling"
        static let memDiagForceReclaim = "memDiagForceReclaim"
        static let meshClassifier = "meshClassifier"
        static let scanCoachingEnabled = "scanCoachingEnabled"
        static let colorizeOnPostprocess = "colorizeOnPostprocess"
        static let registerLegacyScans = "registerLegacyScans"
        static let videoFormatIndex = "videoFormatIndex"             // selected ARKit video format index
        static let captureAudioEnabled = "captureAudioEnabled"       // shutter-click + chime sounds
        static let gpuColorize = "gpuColorize"                        // Developer Mode: GPU vertex-color projection (A/B vs CPU path)
        static let keyframeWeightBonus = "keyframeWeightBonus"        // Developer Mode: keyframe weight bonus in colorization (A/B vs equal still/sweep weighting)
    }

    // MARK: - Default Values
    static var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    static var uploadURL: String {
        isTestFlight ? "https://wiselambda4.lan.cmu.edu/wisescan-uploads/" : ""
    }
    static let overlapMax: Double = 60.0                           // 60%: fewer redundant motion frames now that sharp stills carry texture detail (photogrammetry overlap rule of thumb)
    static let rejectBlur: Bool = true
    static let developerMode: Bool = false
    static let mockIMU: Bool = false
    static let mockCameraImages: Bool = false
    static let mockDepthMaps: Bool = false
    static let privacyFilter: Bool = true
    static let mockWearable: Bool = false
    static let selectedExportFormat = "Scan4D" // ExportFormat.scan4d.rawValue
    static let activeMeshColor: String = "Green"
    static let ghostMeshColor: String = "Magenta"
    static let metaWearablesFPS: Double = 7.0
    static let captureMode: String = CaptureMode.ar.rawValue
    static let hideLivePoints: Bool = false
    static let perfDiagnostics: Bool = false   // Developer Mode: emit OSLog/signpost perf diagnostics
    static let pauseVRCompute: Bool = false     // Developer Mode: skip the entire VR GPU pipeline (isolation test)
    static let vrBloomEnabled: Bool = false     // Developer Mode: VR point-cloud bloom post-process (off by default — device A/B found it unmissed with live points visible; helps most when Hide Live Points is on)
    static let semanticLabeling: Bool = true    // Developer Mode: disable entire RoomPlan pipeline to reduce memory
    /// Developer Mode, OFF by default even in dev. When on, [MemDiag] teardown brackets call
    /// `malloc_zone_pressure_relief` before measuring footprint, forcing the allocator to return
    /// free-list pages to the OS so a teardown free-delta reflects actually-reclaimed memory rather
    /// than pages malloc is still caching. Expensive (walks every zone + decommits) — flip on only for
    /// an attribution session, never leave it on. Doesn't reclaim Metal/GPU buffers (those free on
    /// RealityKit's schedule), so the delta is a floor on what a subsystem releases.
    static let memDiagForceReclaim: Bool = false
    /// Use `.meshWithClassification` scene reconstruction instead of plain `.mesh`. Default ON:
    /// benched 2026-07 (same room, on vs off, AR and VR modes) at no measurable CPU delta and
    /// ~70–100 MB memory — affordable, and the per-face labels are what lets us split wall vs
    /// non-wall geometry (plane registration ghost, decimated rescan reference). The toggle remains
    /// in Developer Mode so the A/B stays re-runnable; each run stamps meshClassifier=on/off at
    /// RECORD-START. Varies ONLY the ARKit classifier — RoomPlan (semanticLabeling) is independent.
    static let meshClassifier: Bool = true
    /// DECISION 3: RoomBuilder no longer runs at save (the 2026-07-13 large hot scan starved its
    /// 3 s data-wait and the scan saved with no room/proxy/registration). It runs at POST-PROCESS
    /// from the persisted CapturedRoomData sidecar, on a cool device. This is the postprocess-time
    /// backstop only — generous, since nothing user-blocking waits on it (a wedged RoomBuilder
    /// shouldn't hang the postprocess queue forever).
    static let roomBuilderTimeoutSeconds: TimeInterval = 120
    /// Grace period after a save completes before declaring a scan "bad" (no room data): RoomPlan's
    /// didEndWith normally delivers CapturedRoomData within a second of Stop, but on a thermally
    /// throttled device it can land many seconds late — the sidecar is written whenever it arrives,
    /// so the bad-scan check just needs to wait out the realistic tail before warning the user to
    /// redo the scan (while they're still standing in the room).
    static let roomDataBadScanGraceSeconds: TimeInterval = 30
    /// Colorize as part of Post-process (production setting, default ON). Off = structural-only
    /// postprocess (room/registration/proxy — fast); coloring can still be run later (re-running
    /// Post-process picks up whatever is pending).
    static let colorizeOnPostprocess: Bool = true
    /// Dev-gated: let legacy scans (saved before scanCaseRaw was persisted) enter retroactive
    /// registration at postprocess. OFF by default — on an existing install every non-oldest
    /// legacy scan would light up "needs postprocess" (gating every old location at update),
    /// and a legacy adjacent-link is indistinguishable from a legacy rescan (false-lock risk).
    static let registerLegacyScans: Bool = false
    /// Developer Mode A/B toggle for the GPU vertex-color projection path (default ON —
    /// production uses the GPU). OFF forces the CPU reference implementation so a suspected
    /// GPU-path artifact (occlusion bleed-through, mask misses) can be isolated on the SAME
    /// scan in the SAME viewer: recolor once per setting and compare. The depth/occlusion
    /// semantics of the two paths are meant to be identical — a visual difference here is a
    /// GPU-path bug by definition.
    static let gpuColorize: Bool = true
    /// Developer Mode A/B toggle for the keyframe weight bonus in colorization (default ON —
    /// production gives sharp stillness keyframes a ×colorizationKeyframeWeight vote in the
    /// weighted median). OFF weights stills and sweep frames EQUALLY: recolor the same scan
    /// once per setting to see whether the bonus amplifies edge bleed (a close keyframe's
    /// silhouette-straddling samples get the bonus AND the 1/d² boost) or, conversely,
    /// whether equal weighting lets blurry sweep colors mush crisp keyframe surfaces.
    static let keyframeWeightBonus: Bool = true

    // MARK: - Pipeline Constants
    static let faceClusterThresholdMeters: Float = 1.0      // merge distance for person anchors (~body size; points now sample any body part via segmentation, not a head)
    static let faceAnchorMinObservations: Float = 2         // a person anchor must be seen in at least this many frames to be saved (confidence gate; drops one-frame segmentation false positives)
    static let maxFramesInFlight: Int = 2                    // cap on concurrent frame-save encodes; excess frames are dropped to keep retained CVPixelBuffers from starving ARKit's frame pool (VIO loss corrupts the scan)
    static let vioFrameGapTripSeconds: TimeInterval = 1.5    // VIO guard: an ARKit frame-delivery gap this large mid-scan = the session stalled and VIO diverged → halt
    static let vioHardFrameGapTripSeconds: TimeInterval = 4.0 // VIO guard belt: a gap this large trips REGARDLESS of how tracking presents on the recovery frame — covers OS actions (Control Center on iPadOS) that stall delivery without firing sessionWasInterrupted and resume via benign-looking .initializing (7.9s gap → silent SLAM reinit, 2026-07-24 M2 runs). Compute stalls on the marginal iPad top out well under 2s, so 4s is clear of false trips.
    static let meshStartWatchdogSeconds: TimeInterval = 10   // Recording on a LiDAR device with zero ARMeshAnchors for this long = Recon3D is dead for this scan (60fps default-format fallback after RoomPlan's internal reconfigure; Fig err storm, 2026-07-24 runs) → halt via the VIO guard. NOT a live rebuild: re-running the session under active RoomPlan crashed ObjectUnderstanding at save (run 4).
    static let vioDegradedTripSeconds: TimeInterval = 2.5    // VIO guard: tracking continuously degraded (limited/relocalizing/unavailable) this long mid-scan → halt
    static let voxelDecayInterval: TimeInterval = 0.5        // VR: min seconds between 350K-voxel confidence-decay passes; throttled off every-integration so the voxelQueue can't back up (drove multi-second stalls)
    static let arIdleTeardownSeconds: TimeInterval = 60      // battery: seconds on a non-capture tab before pausing the AR session (camera/sensors off); resumed on return. Long enough that rapid successive scans stay warm.
    static let liveMeshCueVertexThreshold: Int = 500        // "move the camera to start the live mesh" cue shows until this many NEW vertices are captured since recording began (baseline-relative so it also fires in relocalized ghost/stitch flows where the mesh count starts high)
    static let relocalizationTimeoutSeconds: TimeInterval = 30 // rescan relocalization watchdog: if tracking is still `.relocalizing` (never reaches `.normal`) this long after the prompt appears, surface the "having trouble" guidance + escape UX. Generous: clean rooms settle in 3-9 s but rough/feature-poor rooms legitimately take up to ~43 s, and the panel is non-blocking (auto-dismisses if relocalization then succeeds), so it rescues the forever-hang (self-similar/feature-poor spaces, false loop-closure) without cutting off a slow-but-working settle.
    static let overlapBaseThreshold: Float = 0.15            // movement threshold base for frame capture
    static let overlapMinThreshold: Float = 0.01             // minimum movement threshold
    static let maxColorizationFrames: Int = 150              // max sampled frames for vertex coloring
    static let captureIntegrityMinFrames: Int = 4            // min captured frames before judging modality completeness (too few to be meaningful below this)
    static let captureIntegrityMinFraction: Double = 0.5     // a modality (depth/confidence) present in fewer than this fraction of frames = grossly incomplete capture → warn the user
    static let jpegCompressionQuality: CGFloat = 0.85        // JPEG quality for captured frames
    static let blurWarningTimeout: TimeInterval = 1.5        // seconds before blur warning auto-dismisses
    static let consecutiveBlurThreshold: Int = 5             // blurred frames before warning triggers
    static let motionBlurVelocity: Float = 0.5               // m/s threshold for motion blur detection
    static let privacyBlurVisionScale: CGFloat = 0.5         // downscale factor for the Vision person-seg FALLBACK input (saved-frame privacy blur). Smaller = faster but coarser mask; raise toward 1.0 if person coverage leaks at edges. Only the (rare) fallback uses Vision — ARKit's stencil path is unaffected.
    static let depthOcclusionToleranceMM: Float = 150.0      // mm tolerance for depth occlusion test
    static let colorizationMaxObservations: Int = 12         // max per-vertex observations kept (top-N by quality) for the weighted-median colorizer
    static let colorizationMinDistanceM: Float = 0.3         // distance floor (m) for the inverse-square distance weight, so very close frames don't dominate
    // ── Colorization anti-bleed tuning ──────────────────────────────────────────
    // Effective occlusion tolerance = max(ToleranceMM, ToleranceFrac × depth). The old fixed
    // 50 mm was thicker than a tabletop (near-field bleed-through) yet tight vs LiDAR noise
    // at range. To bisect a knob's effect, set it to its listed "disable" value and recolor.
    static let colorizationOcclusionToleranceMM: Float = 25.0 // FLOOR (mm) of the depth-occlusion tolerance (lower = more aggressive culling near-field; ARKit mesh noise can reject valid samples)
    static let colorizationOcclusionToleranceFrac: Float = 0.03 // distance-proportional tolerance (LiDAR error grows with range): 3% ⇒ 30 mm @1 m, 120 mm @4 m. 0 disables (fixed floor only)
    static let colorizationDepthEdgeMaxSpreadFrac: Float = 0.15 // reject observations whose 3×3 depth neighborhood spans > frac × depth — they straddle a silhouette, where the coarse 256×192 depth and the color raster disagree (the main bleed source). 0 disables
    static let colorizationBackfaceDotMin: Float = 0.0        // reject observations with signed n·v below this — a back-facing vertex is seen THROUGH its own surface (e.g. tabletop color baking onto the underside). -1 disables (legacy abs() behavior)
    static let thumbnailMaxWidth: CGFloat = 800              // max width for scan thumbnails
    static let thumbnailJpegQuality: CGFloat = 0.6           // JPEG quality for thumbnails
    static let stabilizationPollIntervalMs: Int = 200         // ms between tracking-state polls after session reset
    static let stabilizationMaxPolls: Int = 25                // max polls before timeout (total = interval × polls)
    static let semanticThrottleInterval: TimeInterval = 0.5   // min seconds between classification outline rebuilds per anchor
    static let surfaceOutlineLiftDistance: Float = 0.06       // meters surface outlines are lifted toward the camera to draw on top of the co-planar scan mesh (must clear ARKit mesh noise)

    // MARK: - ScanCoach Constants
    static let coachEvaluationInterval: TimeInterval = 1.0    // seconds between ScanCoach rule evaluations (~1Hz)
    static let guidanceCooldownSeconds: TimeInterval = 30.0   // min seconds before a GUIDANCE tip re-shows
    static let infoCooldownSeconds: TimeInterval = 60.0       // min seconds before an INFO tip re-shows
    static let warningAutoDismissSeconds: TimeInterval = 8.0   // WARNING tips auto-dismiss after this duration (or when resolved)
    static let guidanceAutoDismissSeconds: TimeInterval = 6.0  // GUIDANCE tips auto-dismiss after this duration
    static let infoAutoDismissSeconds: TimeInterval = 5.0      // INFO tips auto-dismiss after this duration
    static let earlyScanThresholdSeconds: TimeInterval = 30.0  // first N seconds considered "early scan" for pattern tips
    static let coachMaxDismissCount: Int = 2                   // after this many manual dismissals, tip won't re-show for the session
    static let scanCoachingEnabled: Bool = true                // default for the scan coaching toggle
    static let captureAudioEnabled: Bool = true                // default for shutter-click + chime sounds

    // MARK: - Capture Quality Constants
    static let motionBlurAngularVelocity: Float = 0.5          // rad/s (~30°/s) — rotational velocity above which frames are rejected as blurry
    static let stillnessTranslationalThreshold: Float = 0.02   // m/s — translational velocity below this = "still"
    static let stillnessAngularThreshold: Float = 0.1          // rad/s — rotational velocity below this = "still"
    static let stillnessDurationRequired: TimeInterval = 0.3   // seconds device must be still before counting as "sharp" capture
    static let hiResCaptureTimeoutSeconds: TimeInterval = 5.0  // watchdog: re-request if a hi-res completion never arrives
    static let hiResMaxFailures: Int = 3                       // consecutive hi-res failures before latching stream-frame fallback
    static let keyframeSharpnessFloor: Float = 20.0            // Laplacian variance below this = grossly blurred still → retry (conservative: plain walls still pass on sensor noise)
    static let keyframeSharpnessStride: Int = 4                // sample every Nth luma pixel when measuring sharpness (~760K samples on a 12MP still)
    static let keyframeMaxRetries: Int = 2                     // blurred-still retries per stillness period before accepting the best we got
    static let stillnessHapticIntensity: CGFloat = 0.6         // soft haptic strength on entering confirmed stillness
    static let captureFlashOpacity: Double = 0.5               // peak opacity of the white shutter flash on keyframe capture
    static let captureFlashDuration: TimeInterval = 0.35       // fade-out duration of the shutter flash
    static let photoCoverageMaxDistance: Float = 4.0           // m — max distance a keyframe photo credibly captures texture detail
    static let photoTintColor = SIMD4<Float>(1.0, 0.72, 0.2, 1.0) // amber overlay marking depth-covered-but-unphotographed mesh
    static let photoTintAlpha: CGFloat = 0.28                  // opacity of the amber "depth only" tint
    static let photoTintInflation: Float = 0.004               // m — tint mesh inflation along normals (avoids z-fighting the occlusion fill)
    static let photoTintRebuildInterval: TimeInterval = 1.0    // s — reuse the previous tint mesh for rebuilds inside this window (main-thread MeshResource.generate is the costliest rebuild step)
    static let vrPhotoTintBlend: Float = 0.4                   // fraction of photoTintColor blended into VR voxels not yet photo-covered (VR analog of the AR amber tint)
    static let photoCoverageVoxelSize: Float = 0.25            // m — photo-coverage grid cell size (coarse: coverage tracking, not geometry)
    static let photoCoverageDepthStride: Int = 2               // sample every Nth depth pixel when stamping coverage (256×192 / 2 ≈ 12K samples)
    static let photoCoverageAnchorFraction: Double = 0.5       // fraction of an anchor's mesh voxels that must be photo-covered to clear its amber tint
    static let photoCoverageDebtMinVoxels: Int = 40            // min mesh voxels before the coverage-debt coach tip can fire (too little geometry below this)
    static let photoCoverageDebtFraction: Double = 0.3         // coach nudges "pause for photos" while photo coverage is below this fraction of mesh
    static let photoCoverageStandpointCell: Float = 0.5        // m — camera-position quantization for the per-voxel standpoint (parallax) mask
    static let stillOverlapMinStills: Int = 3                  // stills required before overlap/parallax coaching can fire (too little signal below this)
    static let stillOverlapFloor: Double = 0.4                 // coach nudges "overlap your photos" while mean still-to-still overlap is below this (photogrammetry target ~0.6)
    static let stillParallaxDiversityFloor: Double = 0.15      // coach nudges "step sideways" while under this fraction of photo-covered voxels has ≥2 standpoints
    static let keyframeFrustumDepth: Float = 0.25             // m — length of the still-capture frustum wedge in the preview
    static let keyframeStillColor = SIMD4<Float>(0.2, 0.85, 1.0, 1.0)  // cyan — sharp still (keyframe) capture markers
    static let keyframeMotionColor = SIMD4<Float>(1.0, 0.6, 0.15, 1.0) // amber — motion (sweep) frame markers
    static let keyframeApexSize: Float = 0.04                 // m — solid cube marking the exact still-capture position
    static let keyframeMotionScale: Float = 0.6              // motion-frame wedges drawn smaller than stills (many of them; reduce clutter)
    static let colorizationKeyframeWeight: Float = 3.0         // vertex-color weight bonus for sharp stillness keyframes vs sweep frames

    // MARK: - Space Analysis Constants
    static let analysisAmbientLightAlertThreshold: CGFloat = 250  // lux below which lighting is "Very Low" (alert tier — RGB nearly useless)
    static let analysisAmbientLightWarnThreshold: CGFloat = 500   // lux below which lighting is "Dim" (warning tier — reduced quality)
    static let analysisTimeoutSeconds: TimeInterval = 30          // fallback timeout if 360° not reached
    static let analysisYawCompletionDeg: Float = 330              // yaw coverage (degrees) to count as "360°" (allow slight gap)
    static let analysisYawMaxFillDeg = 45                         // max per-frame yaw delta credited as swept rotation (beyond = tracking snap, credit nothing)
}

// MARK: - Semantic View Mode

/// Controls what is visible in the 3D mesh preview and combined mesh views.
/// Cycles through states via a single toolbar button tap.
enum SemanticViewMode: String, CaseIterable {
    /// Mesh geometry only — no semantic overlays.
    case meshOnly
    /// Mesh geometry with wireframe semantic outlines overlaid.
    case meshWithOutlines
    /// Semantic boxes only (no mesh) — filled at 75% opacity with wireframe edges. "Floor plan" mode.
    case semanticOnly

    /// SF Symbol name for the toolbar button.
    var iconName: String {
        switch self {
        case .meshOnly:        return "cube"
        case .meshWithOutlines: return "cube.fill"
        case .semanticOnly:    return "square.3.layers.3d"
        }
    }

    /// Advance to the next mode in the cycle.
    var next: SemanticViewMode {
        switch self {
        case .meshOnly:        return .meshWithOutlines
        case .meshWithOutlines: return .semanticOnly
        case .semanticOnly:    return .meshOnly
        }
    }

    var showMesh: Bool { self != .semanticOnly }
    var showOutlines: Bool { self != .meshOnly }
    var showFills: Bool { self == .semanticOnly }
}

/// Three-tier toggle for still/motion capture-pose frustum markers in the mesh preview.
/// Mirrors `SemanticViewMode`'s cycle-button pattern; defaults to hidden so the preview
/// stays clean until the user opts in.
enum KeyframeMarkerMode: String, CaseIterable {
    /// No capture markers.
    case none
    /// Sharp still (keyframe) capture poses only.
    case stills
    /// Still + motion (sweep) frame capture poses.
    case stillsAndMotion

    /// SF Symbol name for the toolbar button.
    var iconName: String {
        switch self {
        case .none:            return "camera.metering.none"
        case .stills:          return "camera.metering.partial"
        case .stillsAndMotion: return "camera.metering.matrix"
        }
    }

    /// Advance to the next mode in the cycle.
    var next: KeyframeMarkerMode {
        switch self {
        case .none:            return .stills
        case .stills:          return .stillsAndMotion
        case .stillsAndMotion: return .none
        }
    }

    var showStills: Bool { self != .none }
    var showMotion: Bool { self == .stillsAndMotion }
}

/// Which GEOMETRY the mesh preview draws — an axis ORTHOGONAL to `SemanticViewMode` (which
/// picks the overlay composition over whatever geometry is showing). Kept separate rather than
/// folded in as a 4th `SemanticViewMode` case for three reasons: `SemanticViewMode` is shared
/// with `CombinedMeshView`, which has no proxy (it draws N scans' mesh.obj) and would gain a
/// dead cycle stop; `showMesh`/`showOutlines`/`showFills` answer "what overlay", so a source
/// case would have to hardcode one arbitrary overlay combination; and proxy availability is
/// runtime-conditional, which a pure `next` cycle can't express. As separate axes you get the
/// product (source × overlay) rather than one hardcoded combination.
///
/// NOTE the source axis only bites in the two mesh-showing modes (`.meshOnly`,
/// `.meshWithOutlines`) — `.semanticOnly` has `showMesh == false`, so both geometries are hidden
/// and the toggle is a no-op there. `showFills` is true ONLY in that mode, so fills can never
/// coexist with either mesh; drawing RoomPlan's floor quad OVER the proxy geometry (the direct
/// way to see how far a floor quad overruns the mesh faces it stands in for) would need a
/// mesh+fills mode, which `SemanticViewMode` does not currently have.
///
/// Used by BOTH the single-scan previewer and `CombinedMeshView` — each holds its own source state
/// (they're independent views), and in both it stays a separate axis rather than a
/// `SemanticViewMode` case, for the reasons above. In the combined render the proxy's clean
/// RoomPlan wall quads are what make a join's coplanarity judgable, where lumpy mesh can't be
/// eyeballed; there, maps lacking a proxy fall back to their full mesh (see `ProxyAvailability`).
enum MeshSourceMode: String, CaseIterable {
    /// The full captured mesh (`mesh.obj`) — the untouched save/export artifact.
    case full
    /// The ghost proxy (`mesh_proxy.obj`) — RoomPlan quads standing in for covered walls/floors,
    /// lumpy mesh kept for content. The artifact the rescan ghost actually aligns against, which
    /// otherwise has no inspection surface outside a live rescan session.
    case proxy
    /// The dynamic/content mesh (`mesh_dynamic.obj`) — content faces only, no walls, floors,
    /// ceilings, or RoomPlan quads. The "4D" artifact: everything that isn't fixed room
    /// infrastructure, so scrubbing across rescans shows only what changed between visits.
    case dynamic

    /// SF Symbol name for the toolbar button. Deliberately NOT a cube/layers glyph: it sits next
    /// to `SemanticViewMode`'s `cube`/`cube.fill`/`square.3.layers.3d` cycle, and a same-family
    /// silhouette read as another overlay control. A pyramid stays in "geometry" semantics (this
    /// button is about the model) while being unmistakable at toolbar size. The dynamic mode uses
    /// a shippingbox to convey "contents/movable stuff" — visually distinct from the pyramid pair.
    var iconName: String {
        switch self {
        case .full:    return "pyramid"
        case .proxy:   return "pyramid.fill"
        case .dynamic: return "shippingbox"
        }
    }

    /// Advance to the next mode in the cycle: full → proxy → dynamic → full.
    var next: MeshSourceMode {
        switch self {
        case .full:    return .proxy
        case .proxy:   return .dynamic
        case .dynamic: return .full
        }
    }

    /// Short tag for the preview title note — the proxy looks legitimately holey (floor/ceiling
    /// faces are dropped by design), so viewing it must never be mistaken for a broken scan.
    var titleTag: String? {
        switch self {
        case .full:    return nil
        case .proxy:   return "proxy"
        case .dynamic: return "dynamic"
        }
    }

    /// VoiceOver label for the toolbar toggle — describes the NEXT mode it will switch to.
    var accessibilityLabel: String {
        switch self {
        case .full:    return "Show ghost proxy mesh"
        case .proxy:   return "Show dynamic content mesh"
        case .dynamic: return "Show full mesh"
        }
    }
}


// MARK: - Semantic Classification

/// Semantic display classes for AR/VR overlays, HUD, and preview rendering.
/// This is a **display-level** superset covering both ARKit `ARMeshClassification` and
/// RoomPlan categories. Fine-grained sub-categories (e.g., "sofa", "bathtub") are preserved
/// in `roomplan.json`; these display classes control visualization grouping and color.
enum SemanticClass: String, CaseIterable, Codable {
    case none, wall, floor, ceiling, table, seat, door, window, fixture

    /// Brief description of what this class covers (for the user-guide color legend).
    var classDescription: String {
        switch self {
        case .none:    return ""
        case .wall:    return "Walls and partitions"
        case .floor:   return "Floor surfaces"
        case .ceiling: return "Not yet supported by RoomPlan"
        case .table:   return "Tables and desks"
        case .seat:    return "Chairs, sofas, and beds"
        case .door:    return "Doors, openings, and entryways"
        case .window:  return "Windows"
        case .fixture: return "Appliances, stairs, and fixtures"
        }
    }

    /// Fixed color palette for classification outlines.
    var color: SIMD4<Float> {
        switch self {
        case .none:    return .zero                              // Hidden (no outline rendered)
        case .wall:    return SIMD4<Float>(0.2, 0.4, 1.0, 1.0)  // Blue
        case .floor:   return SIMD4<Float>(1.0, 0.6, 0.2, 1.0)  // Orange
        case .ceiling: return SIMD4<Float>(0.6, 0.6, 0.6, 1.0)  // Light Gray
        case .table:   return SIMD4<Float>(1.0, 0.9, 0.2, 1.0)  // Yellow
        case .seat:    return SIMD4<Float>(1.0, 0.2, 0.2, 1.0)  // Red
        case .door:    return SIMD4<Float>(0.0, 0.9, 0.9, 1.0)  // Cyan
        case .window:  return SIMD4<Float>(1.0, 1.0, 1.0, 1.0)  // White
        case .fixture: return SIMD4<Float>(0.7, 0.3, 0.9, 1.0)  // Purple
        }
    }

    /// SwiftUI color for HUD display and legend.
    var swiftUIDisplayColor: Color {
        let rgba = color
        return Color(red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z))
    }

    /// Map from RoomPlan Surface.Category to SemanticClass.
    static func from(_ surfaceCategory: CapturedRoom.Surface.Category) -> SemanticClass {
        switch surfaceCategory {
        case .wall:              return .wall
        case .floor:             return .floor
        case .door(isOpen: _):   return .door
        case .window:            return .window
        case .opening:           return .door    // openings treated as door-like for rendering
        @unknown default:    return .none
        }
    }

    /// Map from RoomPlan Object.Category to SemanticClass.
    static func from(_ objectCategory: CapturedRoom.Object.Category) -> SemanticClass {
        switch objectCategory {
        case .table:                       return .table
        case .chair:                       return .seat
        case .sofa:                        return .seat
        case .bed:                         return .seat
        case .storage, .refrigerator,
             .stove, .sink, .washerDryer,
             .dishwasher, .oven,
             .fireplace, .television,
             .bathtub, .toilet, .stairs:   return .fixture
        @unknown default:                  return .none
        }
    }

    /// Map from string object category (as stored in roomplan.json) to SemanticClass.
    static func fromObjectCategory(_ category: String) -> SemanticClass {
        switch category {
        case "table":                                       return .table
        case "chair", "sofa", "bed":                        return .seat
        case "storage", "refrigerator", "stove", "sink",
             "washer_dryer", "dishwasher", "oven",
             "fireplace", "television", "bathtub", "toilet",
             "stairs":                                      return .fixture
        default:                                            return .none
        }
    }

    /// Map from string surface category (as stored in roomplan.json) to SemanticClass.
    static func fromSurfaceCategory(_ category: String) -> SemanticClass {
        switch category {
        case "wall":             return .wall
        case "floor":            return .floor
        case "door", "opening":  return .door    // openings treated as door-like for rendering
        case "window":           return .window
        default:                 return .none
        }
    }
}

extension String {
    var toSIMD4Color: SIMD4<Float> {
        switch self.lowercased() {
        case "red": return SIMD4<Float>(1, 0, 0, 1)
        case "green": return SIMD4<Float>(0, 1, 0, 1)
        case "blue": return SIMD4<Float>(0, 0, 1, 1)
        case "yellow": return SIMD4<Float>(1, 1, 0, 1)
        case "cyan": return SIMD4<Float>(0, 1, 1, 1)
        case "magenta": return SIMD4<Float>(1, 0, 1, 1)
        case "white": return SIMD4<Float>(1, 1, 1, 1)
        case "gray": return SIMD4<Float>(0.5, 0.5, 0.5, 1)
        case "black": return SIMD4<Float>(0, 0, 0, 1)
        default: return SIMD4<Float>(0, 1, 0, 1)
        }
    }
}

