# Scan4D Application Design

Based on the architecture specifications (`wiselab-scan/ARCHITECTURE.md`), the iOS application will act as the primary sensor client and edge proxy. The design focuses on three core interfaces using SwiftUI, aiming for a professional, hackable "pro-tool" aesthetic utilizing dark mode and glassmorphism (e.g., `.ultraThinMaterial`).

## 1. Connection & Sync Dashboard
**Matches:** Network Discovery & Sync, Wearable Proxy Streaming
*   **Server Discovery:** Automatically scans the local network via mDNS/Bonjour for the backend Prefect/Python server. Displays connection health, latency, and time-synchronization status.
*   **Wearable Proxy Node:** A pairing section for secondary capture devices (like Meta/Ray-Ban glasses), treating the iOS device as a bridge/proxy for these data streams.

## 2. Main Capture Interface
**Matches:** Streaming & Capture Modes, Environment Mesh Capture, Privacy Filtering
The primary AR view prioritizes the camera feed with overlaid, translucent controls.
*   **Mode Switcher:** A prominent segmented control to flip between **Streaming Mode** (low-latency preview/telemetry to server) and **Capture Mode** (full-res batch recording).
*   **Visual Coverage Guidance:** Incorporates an ARKit-driven heatmap or grid indicating areas with sufficient parallax and scanning coverage.
*   **Privacy Toggle:** A quick-action button for instantly engaging a privacy filter to anonymize or pause capture in sensitive settings.

## 3. Pipeline Orchestration (Post-Capture)
**Matches:** Preset Workflows & Orchestrated Processing
A remote control interface managing server-side reconstruction pipelines after scanning.
*   **Preset Workflows Selection:** Cards to select the required backend processing pipeline (e.g., Quick Mesh, High-Quality Gaussian Splat, Spatial Indexing for OpenFLAME).
*   **Job Observability:** Polls the server to display Prefect job status (e.g., "Training Splat") directly within the app, allowing the researcher to monitor workflow progress remotely.
