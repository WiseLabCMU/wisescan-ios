//
//  AppDelegate.swift
//  wisescan-ios
//
//  Created by mwfarb on 3/2/26.
//

import SwiftUI
import SwiftData

@main
struct Scan4DApp: App {
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
        }
        .modelContainer(sharedModelContainer)
    }
}
