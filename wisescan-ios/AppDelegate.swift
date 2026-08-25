//
//  AppDelegate.swift
//  scan4d
//
//  Created by mwfarb on 3/2/26.
//

import SwiftUI
import SwiftData
import UIKit
import CoreText
import QuartzCore
import MWDATCore

/// UIApplicationDelegate for orientation locking support.
/// CaptureView sets `orientationLocked = true` on appear to lock portrait during scanning.
class AppDelegate: NSObject, UIApplicationDelegate {
    /// When true, the app is locked to portrait orientation (used during capture).
    static var orientationLocked = false

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLocked ? .portrait : .all
    }
}

@main
struct Scan4DApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Add clear button to all text fields globally (especially useful in alerts for long names)
        UITextField.appearance().clearButtonMode = .whileEditing
        
        // Register defaults for keys read via UserDefaults.standard.bool() (not @AppStorage).
        // @AppStorage provides its own default, but direct UserDefaults reads need registration.
        UserDefaults.standard.register(defaults: [
            AppConstants.Key.semanticLabeling: AppConstants.semanticLabeling,
            AppConstants.Key.meshClassifier: AppConstants.meshClassifier,
            AppConstants.Key.registerLegacyScans: AppConstants.registerLegacyScans,
            AppConstants.Key.colorizeFrom360Faces: AppConstants.colorizeFrom360Faces,
            AppConstants.Key.gpuColorize: AppConstants.gpuColorize,
            AppConstants.Key.keyframeWeightBonus: AppConstants.keyframeWeightBonus,
            AppConstants.Key.robustColorMedian: AppConstants.robustColorMedian
        ])
        print("Application directory: \(NSHomeDirectory())")
        // Main-thread stall watchdog, app-wide from first frame (no-op unless Perf
        // Diagnostics is on). Capture-scoped arming structurally missed the #71 class:
        // the freeze happens BEFORE CaptureView.onAppear, exactly where it used to start.
        MainThreadWatchdog.shared.start()
        // Warm CoreText's device-capability lookup OFF the main thread. The mid-stall
        // sampler (2026-08-25, 4th occurrence, 18090 ms) caught the ~18 s freeze family:
        // SwiftUI lays out a Text → CoreText's dispatch_once asks MobileGestalt →
        // MobileGestalt's OWN dispatch_once loads its extensions and makes a SYNCHRONOUS
        // XPC call (xpc_connection_send_message_with_reply_sync) that waited ~18 s on
        // main, every time, starting the instant "Connected" logged — i.e. the first
        // render of the battery-emoji status line. The daemon wait is Apple's; where
        // it happens is ours. Rendering an equivalent line here, on a utility queue,
        // takes both once-tokens before any main-thread Text ever needs them. Timed
        // and logged so the next diagnostics export proves whether the wait is
        // inherent (~18 s here too, but invisible) or transition-related (fast here).
        DispatchQueue.global(qos: .utility).async {
            let t0 = CACurrentMediaTime()
            let probe = NSAttributedString(string: "Connected · v1.0.0 · 🔋 88% ⚠️ ✓",
                                           attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1)])
            let line = CTLineCreateWithAttributedString(probe)
            _ = CTLineGetTypographicBounds(line, nil, nil, nil)
            PerfDiag.log(String(format: "[PerfDiag] CoreText/MobileGestalt warm-up took %.0f ms (off main)",
                                (CACurrentMediaTime() - t0) * 1000))
        }
        do {
            try Wearables.configure()
        } catch {
            print("Failed to configure Meta Wearables SDK: \(error)")
        }
    }

    /// Single shared container — used both for SwiftUI's `.modelContainer` injection and by off-main
    /// consumers (e.g. `ScanExportManager`) that need a background `ModelContext` on the SAME store.
    /// `static` so there is exactly ONE persistent-store coordinator for the app's SQLite file:
    /// `ScanExportManager` previously opened a SECOND container over the same store (stale-read / lock
    /// risk); it now reuses this. Multiple `ModelContext`s on one container is the supported pattern.
    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ScanLocation.self,
            CapturedScan.self,
            StitchLink.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            // Pre-create the Application Support directory to silence CoreData Simulator warnings
            if let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                if !FileManager.default.fileExists(atPath: supportDirectory.path) {
                    try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                }
            }
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    /// True when the process is hosting an XCTest bundle. Unit tests are hosted by this app,
    /// but the Meta Wearables SDK asserts on the simulator (no paired device), which would
    /// crash the host on launch as soon as `ContentView` builds `DashboardView`. Skip the real
    /// UI under test — the logic tests build their own in-memory `ModelContainer` and never need it.
    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            if isRunningUnitTests {
                EmptyView()
            } else {
                ContentView()
                    .onOpenURL { url in
                        Task {
                            do {
                                _ = try await Wearables.shared.handleUrl(url)
                            } catch {
                                print("Error handling Wearables URL: \(error)")
                            }
                        }
                    }
            }
        }
        .modelContainer(Self.sharedModelContainer)
    }
}
