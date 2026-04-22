//
//  AppDelegate.swift
//  wisescan-ios
//
//  Created by mwfarb on 3/2/26.
//

import SwiftUI
import SwiftData
import UIKit
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
        do {
            try Wearables.configure()
        } catch {
            print("Failed to configure Meta Wearables SDK: \(error)")
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ScanLocation.self,
            CapturedScan.self
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

    var body: some Scene {
        WindowGroup {
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
        .modelContainer(sharedModelContainer)
    }
}
