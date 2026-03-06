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
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active {
                    cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    locationManager.authorizationStatus = locationManager.authorizationStatus // forces publish
                }
            }
        }
    }

    private func requestPermissions() {
        if cameraStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    // Once camera is resolved, ask for location
                    if self.locationManager.authorizationStatus == .notDetermined {
                        self.locationManager.requestPermissions()
                    }
                }
            }
        } else if locationManager.authorizationStatus == .notDetermined {
            // Camera already resolved, just ask for location
            locationManager.requestPermissions()
        } else {
            // Both are already resolved. If they are denied, punt to settings.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
}

#Preview {
    PermissionsOverlay(locationManager: LocationManager())
}
