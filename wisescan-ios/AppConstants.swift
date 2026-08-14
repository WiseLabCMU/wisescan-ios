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
        static let rigMeasuredDyMeters = "rigMeasuredDyMeters"        // user's tape-measured iPad-camera→360°-lens distance — ALWAYS persisted in METERS (UI may display/accept imperial); 0 = unmeasured
        static let rigHeightUnitImperial = "rigHeightUnitImperial"    // display/entry unit preference for the rig height field (false = metric)
        static let colorizeFrom360Faces = "colorizeFrom360Faces"      // Developer Mode: color the preview mesh from 360° cube faces instead of keyframes (pose-accuracy probe)
        static let gpuColorize = "gpuColorize"                        // Developer Mode: GPU vertex-color projection (A/B vs CPU path)
        static let keyframeWeightBonus = "keyframeWeightBonus"        // Developer Mode: keyframe weight bonus in colorization (A/B vs equal still/sweep weighting)
        static let robustColorMedian = "robustColorMedian"            // Developer Mode: consensus vector-median color reduce (A/B vs legacy per-channel median)
        static let keepCameraOriginals = "keepCameraOriginals"        // Developer Mode: skip the security-P1 sweep that deletes each 360° still from the camera after verified transfer
        static let thetaBLESerial = "thetaBLESerial"                  // 8-digit serial of the paired camera (BLE identity + factory password)
        static let thetaBLEPeripheralID = "thetaBLEPeripheralID"      // CBPeripheral identifier for scan-free reconnects
        static let thetaCameraProfiles = "thetaCameraProfiles"
        /// Longest EXIF exposure observed per camera model ("thetaObservedExposure.<model>"),
        /// learned from downloaded stills — widens the sway window in dim rooms.
        static let thetaObservedExposurePrefix = "thetaObservedExposure"        // JSON roster of known cameras (multi-camera: X for texture, Z1 for low light — switch per collection)
        static let thetaSSID = "thetaSSID"                            // stored camera Wi-Fi SSID for one-tap join (NEHotspotConfiguration)
        static let thetaPassphrase = "thetaPassphrase"                // stored camera Wi-Fi passphrase. TODO(security P2): move to Keychain + default-credential warning — see design doc Security section
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
    /// Developer Mode A/B (default OFF — production coloring). ON colors the preview
    /// mesh EXCLUSIVELY from cube faces cut from the scan's 360° stills at their BAKED
    /// poses (keyframe/motion frames excluded), turning the colorizer into a
    /// measurement instrument for cube-face pose quality: misplaced color on the mesh
    /// reads back pose error directly. Face frames carry no depth, so occlusion is off
    /// in this mode — bleed-through is expected and not the signal being judged.
    static let colorizeFrom360Faces: Bool = false
    /// Developer Mode, debugging only: keep 360° originals on the camera after verified
    /// transfer. Default OFF = the security-P1 sweep deletes them — raw equirects capture
    /// bystanders in every direction, and the camera (open AP, factory password = serial
    /// digits, unauthenticated OSC API) is the weakest place to leave them.
    static let keepCameraOriginals: Bool = false
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
    /// Developer Mode A/B toggle for the colorize REDUCE step (default ON — production
    /// candidate). ON resolves each vertex by weighted vector consensus: pick the stored
    /// observation most agreeing with the others, then average only its color cluster, so
    /// minority bleed colors are EXCLUDED from the result instead of merely out-voted —
    /// and the answer is always a color that was actually seen (per-channel medians can
    /// mix channels from different observations into a color nobody observed). OFF = the
    /// legacy per-channel weighted median. Unlike projection-side rejection this cannot
    /// lose coverage: every vertex keeps all its observations. Recolor the same scan once
    /// per setting to compare.
    static let robustColorMedian: Bool = true
    /// L1 RGB distance (0–765) within which observations count as agreeing with the
    /// consensus winner and join the trimmed average. Distinct-surface bleed colors sit
    /// far above this; raising it toward 765 degrades to a plain weighted mean, 0 = the
    /// winner observation alone (max rejection, may speckle).
    static let colorizationConsensusTrimL1: Int32 = 60

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
    static let lowStorageWarnBytes: Int64 = 5_000_000_000   // warn below ~5 GB free: a long LiDAR scan writes 0.5-2 GB of frames/depth before save, and a save that fails for space loses the whole capture
    static let coachRigGapSeconds: TimeInterval = 25                   // mesh-gap coach (all scans): seconds of recording before the ceiling/floor prompts can fire (gives the sweep a fair chance first)
    static let coachFloorMinFaces = 1500                               // mesh-gap coach: fewer floor-classified mesh faces than this late in a scan → floor prompt (WARNING — nadir face is dropped downstream, so LiDAR is the only floor source). Tune from [Coach] census log lines.
    static let coachCeilingMinFaces = 500                              // mesh-gap coach: fewer ceiling-classified faces → ceiling prompt (guidance — up-faces give it image coverage; mesh matters for the solver + mesh product). Tune from [Coach] census log lines.
    static let calibrationElevationCutoffDeg: Float = -45              // calibration cost (solve AND spot-check) ignores everything below this elevation: the bottom band holds the rod/tripod and usually the operator — the only content that moves WITH the rig, i.e. systematic attractors (runs 8-10 pulled params toward it). -90 disables
    /// 360° exposure-sway guard. The window that corrupts the pose runs from the
    /// camera ACCEPTING the shutter command (BLE write-ack / OSC response — recorded
    /// as shutter_ack_ms) to shutter close; motion during stitch/transfer is harmless.
    /// Per-model window lengths are conservative seeds pending a bench measurement
    /// (photograph a millisecond clock, read command→shutter latency in the pano);
    /// every downloaded still retro-annotates its sidecar with the EXIF exposure time
    /// so field scans tune these. Sway above either bound marks the still SWAYED:
    /// warning cue + chip count at capture, and the calibration solve prefers clean
    /// stills. 0.03 m matches the dy anchor's half-width; 2° at a ~2 m rig lever arm
    /// is ~7 cm of lens travel.
    /// Ack → shutter-open uncertainty. The ack says the camera ACCEPTED the command;
    /// it fires shortly after. Field data (360update4): ack lands 164-232 ms after the
    /// tap on the X over BLE.
    static let thetaShutterLatencyAllowance: TimeInterval = 0.12
    /// Exposure length used before this camera has ever reported one. 1/30 s is what
    /// the X returned in room light (360update4: EXIF 0.0333 on every still); the
    /// observed value replaces it per model as soon as a still downloads.
    static let thetaDefaultExposureSeconds: TimeInterval = 1.0 / 30
    /// Clamp on the learned exposure so one absurd EXIF value can't widen the guard
    /// into uselessness (a genuinely dark room still tops out well inside this).
    static let thetaMaxExposureSeconds: TimeInterval = 0.5
    /// Pose-probe sampling period. The real window is ~250 ms, so 250 ms sampling put
    /// exactly ONE sample in it; 50 ms gives ~5 and costs one transform read each.
    static let thetaMotionSampleSeconds: TimeInterval = 0.05
    static let thetaSwayWarnMeters: Float = 0.03
    static let thetaSwayWarnDegrees: Float = 2.0
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
    static let calibrationMeasuredDyHalfM: Float = 0.05                // dy half-range around the USER-MEASURED rig height. The cost's +dy pull ALWAYS rides this window's upper wall (360post5: measured 0.79 → solved 0.94 at the +0.15 wall), so the in-window solve adds no information — the window is sized to tape/clamp uncertainty only
    static let calibrationBoundLateralM: Float = 0.3                   // lateral offset half-range (m) around 0
    static let calibrationBoundYawDeg: Float = 45                      // yaw half-range (deg) around EACH coarse-scan start (yaw is solved globally: the 360° cam screws onto the rod at an arbitrary rotation, so a full-circle coarse scan picks the basin and local bounds keep Nelder-Mead inside it)
    static let calibrationBoundPitchDeg: Float = 10                    // pitch-residual half-range (deg) around 0 (zenith correction should leave only small error)
    static let calibrationConvergenceTolerance: Float = 1e-5           // cost-range convergence threshold
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
    static let colorizationMaxObservations: Int = 12         // max per-vertex observations kept (top-N by quality) for the weighted-median colorizer
    static let colorizationMinDistanceM: Float = 0.3         // distance floor (m) for the inverse-square distance weight, so very close frames don't dominate
    // ── Colorization anti-bleed projection knobs — ALL DISABLED by default ──────
    // Device verdict 2026-07-29 (M2, three large scans): shipping these ON together
    // (25 mm floor + 3% frac + 0.15 edge guard + 0.0 backface) was decisively WORSE —
    // widespread gray (= vertices with ZERO surviving observations) and wilder bleed.
    // Mechanism: the smoothed mesh and the upsampled 256×192 depth routinely disagree
    // by ±20–40 mm on perfectly valid front surfaces, so aggressive rejection guts the
    // GOOD observation population; the junk that survives then wins the median.
    // Anti-bleed now lives in the REDUCE step (robustColorMedian), which can't lose
    // coverage. If revisiting these, change ONE knob per recolor.
    static let colorizationOcclusionToleranceMM: Float = 50.0 // FLOOR (mm) of the depth-occlusion tolerance; effective tol = max(floor, frac × depth). 25 mm starved inliers (see above)
    static let colorizationOcclusionToleranceFrac: Float = 0  // distance-proportional tolerance part (LiDAR error grows with range). 0 = fixed floor only (legacy)
    static let colorizationDepthEdgeMaxSpreadFrac: Float = 0  // reject observations whose 3×3 depth neighborhood spans > frac × depth (silhouette-straddle guard). 0 = disabled (legacy); 0.15 killed too much near ALL edges
    static let colorizationBackfaceDotMin: Float = -1          // reject observations with signed n·v below this (seen-through-own-surface guard). -1 = disabled (legacy abs() weighting); 0.0 also zeroed noisy-normal grazing coverage
    static let thumbnailMaxWidth: CGFloat = 800              // max width for scan thumbnails
    static let thumbnailJpegQuality: CGFloat = 0.6           // JPEG quality for thumbnails
    static let stabilizationPollIntervalMs: Int = 200         // ms between tracking-state polls after session reset
    static let stabilizationMaxPolls: Int = 25                // max polls before timeout (total = interval × polls)
    static let semanticThrottleInterval: TimeInterval = 0.5   // min seconds between classification outline rebuilds per anchor

    // MARK: - ScanCoach Constants
    static let coachEvaluationInterval: TimeInterval = 1.0    // seconds between ScanCoach rule evaluations (~1Hz)
    static let guidanceCooldownSeconds: TimeInterval = 30.0   // min seconds before a GUIDANCE tip re-shows
    static let infoCooldownSeconds: TimeInterval = 60.0       // min seconds before an INFO tip re-shows
    static let warningAutoDismissSeconds: TimeInterval = 8.0   // WARNING tips auto-dismiss after this duration (or when resolved)
    static let guidanceAutoDismissSeconds: TimeInterval = 6.0  // GUIDANCE tips auto-dismiss after this duration
    static let infoAutoDismissSeconds: TimeInterval = 5.0      // INFO tips auto-dismiss after this duration
    static let earlyScanThresholdSeconds: TimeInterval = 30.0  // first N seconds considered "early scan" for pattern tips
    static let coachMaxDismissCount: Int = 2                   // after this many manual dismissals, tip won't re-show for the session
    static let coachFastMotionSustainSeconds: TimeInterval = 3 // fastMotion hint (guidance) needs the blur condition SUSTAINED this long — spikes during normal walking must not fire it
    static let coachFastMotionMaxShows: Int = 3                // per-session cap on the fastMotion hint — after this many the user knows the depth-vs-photos tradeoff
    static let nearDepthObstructionMeters: Float = 0.2         // LiDAR returns closer than this are rig hardware / fingers, not scene (sensor min range ≈ 0.25 m — field case: rig tension knob glancing the frame edge, 2026-08-05)
    static let nearDepthObstructionMinFraction: Float = 0.01   // fraction of valid depth samples under nearDepthObstructionMeters that counts as an obstruction (a knob sliver at the frame edge is ~1-5%)
    static let coachNearDepthSustainSeconds: TimeInterval = 4  // obstruction must persist this long before the coach warns — a hand passing the lens must not fire it
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

