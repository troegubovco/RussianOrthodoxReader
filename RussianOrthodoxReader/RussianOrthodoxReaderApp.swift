//
//  RussianOrthodoxReaderApp.swift
//  RussianOrthodoxReader
//
//  Created by Andrey Troegubov on 2/25/26.
//

import SwiftUI
import SwiftData
#if canImport(UIKit) && !os(macOS)
import UIKit
#elseif canImport(AppKit)
import AppKit

final class ReadingSyncAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }
}
#endif

#if canImport(UIKit) && !os(macOS)
final class ReadingSyncAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
}
#endif

@main
struct RussianOrthodoxReaderApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    #if canImport(UIKit) && !os(macOS)
    @UIApplicationDelegateAdaptor(ReadingSyncAppDelegate.self) private var appDelegate
    #elseif canImport(AppKit)
    @NSApplicationDelegateAdaptor(ReadingSyncAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                // У приложения нет тёмной темы (кремовый фон всегда), а системные
                // заголовки листов следовали за тёмным режимом устройства и
                // рисовались белым по кремовому. Фиксируем светлую схему глобально.
                .preferredColorScheme(.light)
                #if os(macOS)
                .frame(minWidth: 800, minHeight: 600)
                #endif
                // Pull latest settings from CloudKit on first appearance
                .task {
                    await appState.refreshFromCloud()
                }
                #if DEBUG
                // `SINODAL_SEARCH_REPORT=1` — dump the prayer-search worked
                // examples (search_design.md §3.7) to stdout once at launch.
                .task {
                    if ProcessInfo.processInfo.environment["SINODAL_SEARCH_REPORT"] == "1" {
                        PrayersRepository.debugSearchReport()
                    }
                }
                #endif
        }
        .modelContainer(PersistenceController.shared.container)
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif
        // Re-sync whenever the app returns to the foreground
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await appState.refreshFromCloud(force: true) }
            }
        }
    }
}
