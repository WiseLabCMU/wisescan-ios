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

    enum Theta {
        static let minFirmwareZ1 = "3.00.1"
        static let minFirmwareX = "2.92.0"
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
        static let registerLegacyScans = "registerLegacyScans"
        static let videoFormatIndex = "videoFormatIndex"             // selected ARKit video format index
        static let captureAudioEnabled = "captureAudioEnabled"       // shutter-click + chime sounds
        static let rigMeasuredDyMeters = "rigMeasuredDyMeters"        // user's tape-measured iPad-camera→360°-lens distance (m); 0 = unmeasured
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
    /// Dev-gated: let legacy scans (saved before scanCaseRaw was persisted) enter retroactive
    /// registration at postprocess. OFF by default — on an existing install every non-oldest
    /// legacy scan would light up "needs postprocess" (gating every old location at update),
    /// and a legacy adjacent-link is indistinguishable from a legacy rescan (false-lock risk).
    static let registerLegacyScans: Bool = false

    // MARK: - Pipeline Constants
    static let faceClusterThresholdMeters: Float = 1.0      // merge distance for person anchors (~body size; points now sample any body part via segmentation, not a head)
    static let faceAnchorMinObservations: Float = 2         // a person anchor must be seen in at least this many frames to be saved (confidence gate; drops one-frame segmentation false positives)
    static let maxFramesInFlight: Int = 2                    // cap on concurrent frame-save encodes; excess frames are dropped to keep retained CVPixelBuffers from starving ARKit's frame pool (VIO loss corrupts the scan)
    static let vioFrameGapTripSeconds: TimeInterval = 1.5    // VIO guard: an ARKit frame-delivery gap this large mid-scan = the session stalled and VIO diverged → halt
    static let vioHardFrameGapTripSeconds: TimeInterval = 4.0 // VIO guard belt: a gap this large trips REGARDLESS of how tracking presents on the recovery frame — covers OS actions (Control Center on iPadOS) that stall delivery without firing sessionWasInterrupted and resume via benign-looking .initializing (7.9s gap → silent SLAM reinit, 2026-07-24 M2 runs). Compute stalls on the marginal iPad top out well under 2s, so 4s is clear of false trips.
    static let meshStartWatchdogSeconds: TimeInterval = 10   // Recording on a LiDAR device with zero ARMeshAnchors for this long AFTER tracking settled = Recon3D is dead for this scan (60fps default-format fallback after RoomPlan's internal reconfigure; Fig err storm, 2026-07-24 runs) → halt via the VIO guard. NOT a live rebuild: re-running the session under active RoomPlan crashed ObjectUnderstanding at save (run 4).
    static let trackingSettleWatchdogSeconds: TimeInterval = 20 // Recording whose tracking NEVER reaches .normal (e.g. started mid-relocalization chase after an idle interruption) has both graduated guards unarmed — if it hasn't settled in this budget the capture is unusable → halt (2026-07-28 A12Z: indefinite degraded limbo, faces=0, no stillness settle).

    // MARK: - 360° Rig (mechanical-prior extrinsic — calibration plan step 1; the solved
    // hand–eye refinement replaces these per rig profile later)
    static let rigRodHeightMeters: Float = 1.0     // 360° camera height above the phone along WORLD up (ARKit is gravity-aligned; Theta zenith correction keeps the pano level, so the prior needs only position + yaw)
    static let rigYawOffsetDegrees: Float = 0      // pano-center (camera-body forward) yaw relative to the phone's horizontal forward; 0 = lenses aligned with the phone
    static let equirectFaceSizeMax = 2048          // cube-face edge cap (native density is equirectWidth/4; 11K Theta X stills would yield 2752 — capped for JPEG size/memory)
    static let equirectFaceDecodeMax = 8192        // staged-equirect decode cap for face sampling (8192×4096 RGBA ≈ 134 MB transient, per-still pooled; width/4 already saturates the face cap)

    // MARK: - 360° Rig Calibration (markerless mesh-edge solver — see docs/design/still-source-360.md)
    static let calibrationStillCount = 3                               // stills captured at distinct positions before the solver runs
    static let calibrationMeshRadiusMeters: Float = 3.0                // radius around each phone position for mesh edge extraction
    static let calibrationMeshVertexMinimum = 500                      // minimum vertex count within radius for a reliable solve (environment quality gate)
    static let calibrationMinMeshEdges = 500                           // HARD gate at capture: fewer extracted mesh edges than this → reject the position (run6: three 0-edge stills sailed through to a guaranteed-failed solve)
    static let calibrationMinCoverageDeg: Float = 90                   // HARD gate at capture: yaw span of mesh edges around the position. run9 diagnostics: mesh confined to one ~60° wedge → 4-DOF solve is ambiguous (yaw slides along the wedge, dy/pitch trade off) no matter how many edges the wedge holds
    static let calibrationElevationCutoffDeg: Float = -45              // calibration cost (solve AND spot-check) ignores everything below this elevation: the bottom band holds the rod/tripod and usually the operator — the only content that moves WITH the rig, i.e. systematic attractors (runs 8-10 pulled params toward it). -90 disables
    static let calibrationMinStillsForSolve = 3                        // live sufficiency meter + Process-step solve floor: fewer equirects than this → poses fall back to prior geometry
    static let calibrationMinSpreadMeters: Float = 1.0                 // live sufficiency meter: max pairwise still-position distance below this = weak baseline for the Process-step solve
    static let calibrationResidualGreenPx: Float = 1.4                 // RMS reprojection error (equirect px, 512-wide) ≤ this → green. Behavior-preserving √ of the old mean-squared 2.0
    static let calibrationResidualYellowPx: Float = 2.2                // ≤ this → yellow (marginal); above → red (suggest re-do). √5.0
    static let calibrationMaxIterations = 150                          // Nelder-Mead iteration cap (device solves converge in 57-97; 500 let Debug-build postprocess solves run 60-70 s)
    // Physical solve bounds, anchored to the MECHANICAL prior (the rig's ground truth).
    // run8 (2026-07-30): with a near-flat chamfer cost surface in cluttered rooms, the
    // unbounded solver accepted dy=4.4 m / yaw=−240° at residuals indistinguishable
    // from plausible poses. A monopod rig cannot physically be outside these ranges.
    static let calibrationBoundDyM: Float = 0.3                        // rod height half-range (m) around the anchor when the user hasn't MEASURED the rig. The chamfer cost has a systematic +dy pull (dense image-edge band above the elevation cut attracts the sparse projected mesh downward → camera up; 360post4: solved 1.299 vs tape-measured 0.787), so an unmeasured box stays tight to limit the damage — a measured rig uses ±calibrationMeasuredDyHalfM instead
    static let calibrationMeasuredDyHalfM: Float = 0.15                // dy half-range around the USER-MEASURED rig height (Settings → 360° rig) — the measurement is ground truth; the window only absorbs clamp/tape slop
    static let calibrationBoundLateralM: Float = 0.3                   // lateral offset half-range (m) around 0
    static let calibrationBoundYawDeg: Float = 45                      // yaw half-range (deg) around EACH coarse-scan start (yaw is solved globally: the 360° cam screws onto the rod at an arbitrary rotation, so a full-circle coarse scan picks the basin and local bounds keep Nelder-Mead inside it)
    static let calibrationBoundPitchDeg: Float = 10                    // pitch-residual half-range (deg) around 0 (zenith correction should leave only small error)
    static let calibrationConvergenceTolerance: Float = 1e-5           // cost-range convergence threshold
    static let calibrationEdgeDetectionWidth = 512                     // downsampled equirect width for Sobel edge detection
    static let calibrationDriftWarnMultiplier: Float = 1.4             // first-still spot-check: warn if live residual > stored × this. RMS space — ≡ the old 2.0× on squared values (√2)
    static let calibrationDriftWarnFloorPx: Float = 1.7                // don't warn if the absolute live residual is below this (avoids noise on tight calibrations). √3.0
    static let calibrationMaxEdgesPerInput = 1200                      // subsample mesh edges per input to cap solver time (2000 → 1200 after 360post1: per-eval cost dominates the postprocess solve)
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
    static let colorizationOcclusionToleranceMM: Float = 50.0 // tighter mm tolerance used during colorization to cull backface/occluded samples (lower = more aggressive culling, but ARKit mesh noise can reject valid samples)
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
    // Equirect cube-map face direction colors (mesh preview frustum markers)
    static let equirectMarkerRadius: Float = 0.12                      // m — 360° still sphere marker radius in the mesh preview
    static let equirectFrontColor  = SIMD4<Float>(0.2, 0.85, 1.0, 1.0) // cyan  — forward face
    static let equirectRightColor  = SIMD4<Float>(0.3, 0.9, 0.4, 1.0)  // green — right face
    static let equirectBackColor   = SIMD4<Float>(1.0, 0.6, 0.15, 1.0) // orange — back face
    static let equirectLeftColor   = SIMD4<Float>(0.85, 0.3, 0.85, 1.0) // magenta — left face
    static let equirectUpColor     = SIMD4<Float>(0.95, 0.95, 0.95, 1.0) // white — up face

    // MARK: - Space Analysis Constants
    static let analysisAmbientLightAlertThreshold: CGFloat = 250  // lux below which lighting is "Very Low" (alert tier — RGB nearly useless)
    static let analysisAmbientLightWarnThreshold: CGFloat = 500   // lux below which lighting is "Dim" (warning tier — reduced quality)
    static let analysisTimeoutSeconds: TimeInterval = 30          // fallback timeout if 360° not reached
    static let analysisYawCompletionDeg: Float = 330              // yaw coverage (degrees) to count as "360°" (allow slight gap)
    static let analysisYawMaxFillDeg = 45                         // max per-frame yaw delta credited as swept rotation (beyond = tracking snap, credit nothing)

    // MARK: - 360° Still Source (Theta OSC spike — feat/still-source-360)
    static let thetaCaptureTimeout: TimeInterval = 20            // max wait for a takePicture command to reach "done"
    static let thetaStatusPollInterval: TimeInterval = 0.4       // /osc/commands/status poll cadence while a capture is inProgress
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

/// Four-tier toggle for capture-pose frustum markers in the mesh preview.
/// Mirrors `SemanticViewMode`'s cycle-button pattern; defaults to hidden so the preview
/// stays clean until the user opts in. The `.equirectFaces` tier is skipped for scans
/// without 360° stills (controlled by `next(hasEquirects:)`).
enum KeyframeMarkerMode: String, CaseIterable {
    /// No capture markers.
    case none
    /// Sharp still (keyframe) capture poses only.
    case stills
    /// 360° equirect sphere markers (one translucent sphere + forward arrow per still).
    case equirectFaces
    /// Motion (sweep) frame capture poses only.
    case motion
    /// Everything at once.
    case all

    /// SF Symbol name for the toolbar button.
    var iconName: String {
        switch self {
        case .none:          return "camera.metering.none"
        case .stills:        return "camera.metering.partial"
        case .equirectFaces: return "pano"
        case .motion:        return "camera.metering.center.weighted"
        case .all:           return "camera.metering.matrix"
        }
    }

    /// Advance to the next mode, skipping `.equirectFaces` if no equirect data exists.
    func next(hasEquirects: Bool) -> KeyframeMarkerMode {
        switch self {
        case .none:          return .stills
        case .stills:        return hasEquirects ? .equirectFaces : .motion
        case .equirectFaces: return .motion
        case .motion:        return .all
        case .all:           return .none
        }
    }

    var showStills: Bool { self == .stills || self == .all }
    var showMotion: Bool { self == .motion || self == .all }
    var showEquirectFaces: Bool { self == .equirectFaces || self == .all }
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

