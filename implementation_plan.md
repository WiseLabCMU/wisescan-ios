# Meta Ray-Ban Stream Connection Plan

Based on the [Meta Wearables DAT iOS SDK](https://github.com/facebook/meta-wearables-dat-ios) documentation, this is the plan to transition from our scaffolding to a functional live proxy data stream.

## User Action Required
The Meta Wearables DAT SDK relies on specific Xcode build configurations that cannot be safely executed automatically via typical text edits, as it will corrupt the `.pbxproj`. You will need to manually perform these setup steps in Xcode:

> [!IMPORTANT]
> **1. Add the Swift Package**
> In Xcode, go to `File > Add Package Dependencies...` and enter the repository URL: `https://github.com/facebook/meta-wearables-dat-ios`. Add the `meta-wearables-dat-ios` library to the `wisescan-ios` target.

> [!IMPORTANT]
> **2. Gather Meta Credentials**
> If you haven't already, ensure you have your `MetaAppID`, `ClientToken`, and `TeamID` registered from the Meta Wearables Developer Center. If omitted or kept blank, the app will still function in Developer Mode.

## Proposed Changes

---

### App Configuration
We need to update the [Info.plist](file:///Users/mwfarb/git/wisescan-ios/Custom-Info.plist) to allow the SDK to perform background discovery and deep-link communication with the Meta AI iOS companion app.

#### [MODIFY] [Custom-Info.plist](file:///Users/mwfarb/git/wisescan-ios/Custom-Info.plist)
- Inject the required MWDAT keys:
    - `MetaAppID` (Placeholder: empty string for dev mode)
    - `ClientToken` (Placeholder: empty string)
    - `TeamID` (Placeholder: empty string)
    - `AppLinkURLScheme` (e.g., `wisescandat`)
- Add `LSApplicationQueriesSchemes` containing `meta-ai` to ensure `wearables.requestPermission(.camera)` can successfully bounce out to the Meta AI app for authentication.

---

### App Initialization
#### [MODIFY] [wisescan-iosApp.swift](file:///Users/mwfarb/git/wisescan-ios/wisescan-ios/wisescan-iosApp.swift)
- Import `MWDATCore`.
- Invoke `Wearables.configure()` early in the app lifecycle (typically [init()](file:///Users/mwfarb/git/rayban-androidApp/receiver.py#32-35) of the main App struct) to ensure the Wearables daemon begins discovery.

---

### Wearable Stream Manager
#### [MODIFY] [MetaWearableManager.swift](file:///Users/mwfarb/git/wisescan-ios/wisescan-ios/MetaWearableManager.swift)
- Replace scaffold logic with real SDK implementations.
- Import `MWDATCore` and `MWDATCamera`.
- **Discovery**: Use `Wearables.shared.devices` publisher to track real `WearableDevice` instances, mapping them to our UI list.
- **Permissions**: Add logic to evaluate `Wearables.shared.checkPermissionStatus(.camera)`. If unauthorized, trigger `requestPermission(.camera)`.
- **Stream Session**: 
    - Construct an `MWDATCamera.StreamSession(device: device)`.
    - Handle the `streamSession.state` publisher to react to user hardware button clicks (e.g., when state transitions to `.capturing`).
    - Subscribe to `streamSession.framePublisher`. For every new frame, extract the pixel buffer and pass it down into our existing `FrameCaptureSession.start()` logic to save it identically to a native scan.

---

### Trigger Handshakes
#### [MODIFY] [DashboardView.swift](file:///Users/mwfarb/git/wisescan-ios/wisescan-ios/DashboardView.swift)
- Update the action button to check and request camera permissions from the SDK before attempting to start a stream session.

## Verification
- **Compilation Check**: The project should compile cleanly with SPM dependencies linked.
- **Pairing Check**: `DashboardView` should automatically list the Meta Ray-Bans once the Meta AI companion app broadcasts their availability.
- **Hardware Trigger Check**: Clicking the capture button on the physical glasses should instantly initiate the frame drop into `scan4d_metadata.json` proxy packages.

## Remaining Tasks (Next Session)
> [!NOTE]
> The scaffolding is in place, but these final wiring steps remain:

**1. MWDAT Announcer Subscriptions (`MetaWearableManager.swift`)** - [x]
- [x] Identify the exact Combine publisher syntax for the linked version of the MWDAT SDK. (It uses `listen` from a custom `Announcer` protocol).
- [x] Uncomment and implement `session.statePublisher` to listen for the hardware shutter button and toggle `isStreaming`.
- [x] Uncomment and implement `session.videoFramePublisher` to extract `frame.pixelBuffer` and pipe it into `activeCaptureSession`.

**2. Dashboard UI Wiring (`DashboardView.swift`)** - [x]
- [x] Wire up the currently empty `Button(action: {})` on the `WearableCard`.
- [x] Have it invoke `MetaWearableManager.shared.connect(to: deviceId)`, ensuring permissions are checked and the stream session observation begins.
