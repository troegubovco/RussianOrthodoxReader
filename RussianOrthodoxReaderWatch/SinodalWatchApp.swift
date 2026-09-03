//
//  SinodalWatchApp.swift
//  RussianOrthodoxReaderWatch
//

import SwiftUI

@main
struct SinodalWatchApp: App {
    init() {
        // Прогреваем снимок пользовательских данных как можно раньше — от него
        // зависят значения по умолчанию для языка и ударений (см. WatchUserDataStore).
        _ = WatchUserDataStore.shared
        // Слушаем iPhone: снимок «Моего правила», закладок и помянника
        // приходит через WatchConnectivity и попадает в WatchUserDataStore.
        WatchSessionReceiver.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
