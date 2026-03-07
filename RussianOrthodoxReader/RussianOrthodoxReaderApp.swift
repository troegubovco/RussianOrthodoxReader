//
//  RussianOrthodoxReaderApp.swift
//  RussianOrthodoxReader
//
//  Created by Andrey Troegubov on 2/25/26.
//

import SwiftUI
import SwiftData

@main
struct RussianOrthodoxReaderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .modelContainer(PersistenceController.shared.container)
    }
}
