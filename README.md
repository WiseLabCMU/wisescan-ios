# WiSEScan iOS

`wisescan-ios` is the companion reality capture mobile application for the WiSEScan platform. It acts as an advanced sensor client and wearable edge proxy designed to bridge high-fidelity device data with hackable backend reconstruction servers.

## Features & Implementation Status

| Feature | Description | Status |
| :--- | :--- | :--- |
| **Server Discovery** | Detect local Prefect orchestration servers via mDNS/Bonjour | 🔲 UI Mockup Only |
| **Wearable Proxy** | Bridge data from secondary devices (e.g., Meta/Ray-Ban glasses) | 🔲 UI Mockup Only |
| **Capture UI** | Main camera preview interface | 🔲 UI Mockup Only |
| **Coverage Guidance** | ARKit heatmap highlighting scanned geometry | 🔲 UI Mockup Only |
| **Streaming Mode** | Real-time lower-res tracking data sent to server | 🔲 UI Mockup Only |
| **Capture Mode** | High-res image/depth batching for offline processing | 🚧 In Progress (Static HTTP PUT) |
| **Privacy Filter** | Real-time visual redaction/pause for sensitive spaces | 🔲 UI Mockup Only |
| **Workflow Orchestration** | Select preset server pipelines (Mesh, Splat, Spatial Indexing) | 🔲 UI Mockup Only |
| **Job Observability** | Display remote Prefect job status locally | 🔲 UI Mockup Only |

## Setup
### Design & Mockups
The initial phase consists of building SwiftUI mockups mapped to the overall system design. You can view the full architectural context in the primary `wiselab-scan` repository's `ARCHITECTURE.md`. Mockup components currently live in the `Views/` directory, and visual designs reside in the `Design/` directory.

### Quick Start
1. Open the `.xcodeproj` file in Xcode (Requires development team signing set in target).
2. Configure your specific temporary upload paths (for Capture Mode) directly in the `DashboardView` settings text field while server discovery logic is pending.
