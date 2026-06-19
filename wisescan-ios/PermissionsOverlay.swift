import SwiftUI
import CoreLocation
import AVFoundation

struct PermissionsOverlay: View {
    @Bindable var locationManager: LocationManager
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Environment(\.scenePhase) var scenePhase

    var isAuthorized: Bool {
        return cameraStatus == .authorized &&
               (locationManager.authorizationStatus == .authorizedWhenInUse ||
                locationManager.authorizationStatus == .authorizedAlways)
    }

    var body: some View {
        if !isAuthorized {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 32) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.orange)

                    VStack(spacing: 12) {
                        Text("Permissions Required")
                            .font(.title2).bold()

                        Text("Scan4D needs Camera access to build 3D geometry and Location access to physically anchor your scans so they can be accurately aligned later.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.gray)
                            .padding(.horizontal, 32)
                    }

                    Button(action: requestPermissions) {
                        Text("Grant Permissions")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                }
            }
            // Transition smoothly out when permissions are granted
            .transition(.opacity)
            .animation(.easeInOut, value: isAuthorized)
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    // Re-read from the underlying CLLocationManager to trigger @Observable update
                    locationManager.refreshAuthorizationStatus()
                }
            }
        }
    }

    private func requestPermissions() {
        // A denied/restricted permission can only be changed in Settings — re-prompting is a no-op.
        let cameraBlocked = (cameraStatus == .denied || cameraStatus == .restricted)

        if cameraStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async {
                    self.cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    // Once camera is resolved, chain the location prompt if it's still undetermined;
                    // otherwise a permission is denied, so route to Settings rather than dead-ending.
                    if self.locationManager.authorizationStatus == .notDetermined {
                        self.locationManager.requestPermissions()
                    } else {
                        self.openSettings()
                    }
                }
            }
        } else if locationManager.authorizationStatus == .notDetermined && !cameraBlocked {
            // Camera is fine and location can still be prompted in-app.
            locationManager.requestPermissions()
        } else {
            // Nothing left to prompt for in-app (a permission is denied/restricted) — Settings is the
            // only path forward. This covers the camera-denied + location-undetermined case that
            // previously only re-prompted location and left the user stuck.
            openSettings()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    PermissionsOverlay(locationManager: LocationManager())
}
