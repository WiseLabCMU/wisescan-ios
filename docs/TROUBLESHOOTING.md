# Scan4D Troubleshooting Guide

This document catalogs known issues, hardware quirks, and recovery steps for the Scan4D iOS application, with a specific focus on the physical layer and third-party hardware integrations like the Meta Wearables SDK.

---

## Meta Ray-Ban Wearables

The Meta Wearables Device Access Toolkit (DAT) SDK enforces strict lifecycle requirements and device state checks. Below are common failure modes and their resolutions.

### 1. "noEligibleDevice" or "Device update may be needed" Banner
**Symptoms:** 
- The CaptureView displays a yellow banner stating *"Device update may be needed — check Meta AI app"*.
- In the Xcode console, you see `[MetaWearable] Failed to start device session: noEligibleDevice` or `datAppOnTheGlassesUpdateRequired`.
- The Meta AI companion app states the glasses' firmware is fully up-to-date.

**Root Cause:**
This is a known bug in the DAT SDK (specifically highlighted in SDK v0.7.0). The SDK gets out of sync with the physical companion app (`datApp`) installed on the glasses, even if the primary firmware is current. The SDK strictly blocks the `DeviceSession` from starting.

**Recovery Steps:**
Because this is a hard SDK block, you must update the DAT app on the glasses to match the SDK. As of SDK 0.7.0, there are two ways to do this:

**Method A: Direct Update (Recommended)**
1. Open the **Meta View** companion app.
2. Navigate to **Settings -> App Info**.
3. Look for a pending DAT install under your glasses (e.g., "DAT SDK version: 0.7.0.10.0").
4. Tap the pending install and confirm to update the background app.

**Method B: Force Re-sync (If Method A is unavailable)**
1. **Force Companion App Update:** Plug the glasses case into a wall charger and place the glasses inside with the lid open. Leave them for 15+ minutes. This triggers background downloads over Wi-Fi.
2. **Unpair & Re-pair:** 
   - Open the Meta View app -> Settings -> Your Glasses -> **Unpair**.
   - Put the glasses in their case, hold the back pairing button until the LED pulses blue, and pair them again.
   - You **must** re-enable Developer Mode (tap the version number 5 times in the Meta View app).
3. **Revoke and Re-grant:**
   - In the Meta View app -> Settings -> Developer -> **Revoke Third-Party Access**.
   - Open Scan4D to trigger the OAuth permission flow again.

### 2. "Meta App Permission Required" Banner Stuck
**Symptoms:**
- The CaptureView displays a yellow *"Meta App Permission Required"* banner.
- You have already granted permissions in the Meta AI app.

**Root Cause:**
The OAuth redirect flow failed to properly update the local app state, or the Meta AI app silently revoked the permission token.

**Recovery Steps:**
1. Navigate to the **Scan4D Dashboard tab**.
2. Tap the "Open Meta App to Register" button to force a fresh permission check.
3. If that fails, go to iOS Settings -> Scan4D -> Toggle **Local Network** and **Bluetooth** off and back on to reset the XPC connection.

### 3. No Video Feed / Infinite "Starting stream..." Spinner
**Symptoms:**
- The app connects to the glasses (the banner goes away).
- The spinner stays on screen indefinitely; no picture-in-picture video appears.

**Root Cause:**
The DAT SDK uses Bluetooth for control but negotiates a hidden **WiFi Direct** connection for the high-bandwidth video stream. If your phone refuses to join the glasses' temporary WiFi network (e.g., "RBMeta 08NR -2"), the stream will hang.

**Recovery Steps:**
1. Ensure you have not disabled Wi-Fi on your iPhone.
2. If prompted by iOS with *"Scan4D wants to join Wi-Fi network RBMeta..."*, you must tap **Join**.
3. Force quit the Scan4D app and the Meta AI app, then reopen Scan4D.

---

## Core AR & Capture Issues

### 1. Mesh Export is Empty or Missing
**Symptoms:**
- After stopping a recording, the exported `.obj` or `.ply` file is extremely small or missing.
- The 3D Preview screen is blank.

**Root Cause:**
- **LiDAR Requirement:** You might be running on a non-LiDAR device (Lite Mode). Mesh reconstruction requires a LiDAR scanner (iPhone Pro / iPad Pro).
- **Movement Speed:** Moving the camera too quickly prevents ARKit from triangulating the mesh.
- **Resource Constraints:** The console may show `World tracking performance is being affected by resource constraints`. ARKit pauses mesh generation under heavy thermal or memory load.

**Recovery Steps:**
1. Check the Dashboard or CaptureView for the blue "Lite Mode" banner. If present, the device lacks LiDAR.
2. Scan slower. Watch the HUD's capacity score. If it turns yellow/red, stop the scan and save it, then use "Extend Scan" to start a new chunk.

### 2. Relocalization Fails (Ghost Mesh Jumps)
**Symptoms:**
- When extending a scan, the red ghost mesh appears but is completely misaligned or jumps wildly around the room.

**Root Cause:**
ARKit's `ARWorldMap` requires identical visual features to relocalize. If the lighting has changed significantly, or if the original scan was entirely of a blank wall, ARKit cannot anchor the coordinate space.

**Recovery Steps:**
1. Ensure the room lighting matches the original scan exactly.
2. Point the camera at a visually distinct area (posters, furniture corners, textured rugs) that was captured in the first session.
3. Move the phone slowly left/right to give the camera parallax data until the ghost mesh locks into place.
