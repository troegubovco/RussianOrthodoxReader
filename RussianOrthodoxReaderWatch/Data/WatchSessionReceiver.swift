//
//  WatchSessionReceiver.swift
//  RussianOrthodoxReaderWatch
//
//  Принимает WatchSnapshot от iPhone через WatchConnectivity и кладёт его
//  в UserDefaults, откуда его читает локальное хранилище часов. Часы не
//  редактируют данные — applicationContext целиком заменяет предыдущее
//  состояние.
//
//  Единственное исключение — `sendPlanUnitDone` ниже: отметка «прочитано
//  сегодня» по плану чтения, первый (и пока единственный) канал записи с
//  часов на телефон (§4.6 akathist_psalter_design.md).
//

import Foundation
import WatchConnectivity

/// nonisolated: WCSessionDelegate — objc-протокол, чьи колбэки система
/// вызывает на произвольной очереди. Под MainActor-изоляцией по умолчанию
/// для этого таргета класс обязан быть nonisolated, а работа с общим
/// состоянием (UserDefaults, NotificationCenter) переносится на MainActor
/// явно через Task { @MainActor in … } (см. приём в
/// RussianOrthodoxReader/PrayersSyncService.swift).
nonisolated final class WatchSessionReceiver: NSObject, WCSessionDelegate {
    static let shared = WatchSessionReceiver()

    private override init() {
        super.init()
    }

    // MARK: - Активация

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if let error {
            print("WatchSessionReceiver: activation failed — \(error.localizedDescription)")
        }
        let context = session.receivedApplicationContext
        Task { @MainActor in
            WatchSessionReceiver.apply(context)
        }
    }

    #if os(iOS)
    // Только для компиляции watch-таргета под iOS SDK при legacy-сборке
    // (`xcodebuild -target … -sdk iphonesimulator`), где WCSessionDelegate
    // требует эти методы. На watchOS их нет.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            WatchSessionReceiver.apply(applicationContext)
        }
    }

    // MARK: - Отправка: отметка «прочитано» по плану чтения (§4.6)

    /// Отправляет отметку «прочитано сегодня» на телефон.
    /// `WCSession.transferUserInfo`, а не `sendMessage`: ставится в очередь
    /// и переживает недоступность телефона (в кармане/сумке во время
    /// службы — обычный сценарий); `sendMessage` требует немедленной
    /// досягаемости.
    ///
    /// Безопасно ровно одним ограничением: с часов уходит только
    /// добавление отметки, никогда снятие — `ReadingPlansStore.markDone`
    /// на телефоне идемпотентен по календарному дню, так что потерянное
    /// сообщение восстановится следующей отметкой, а продублированное
    /// безвредно. Снятие отметки и остановка плана — только на телефоне.
    ///
    /// Не проверяет доставку и не ждёт ответа — оптимистичный UI на часах
    /// (`WatchUserDataStore.markPendingDone`) должен вызываться отдельно,
    /// до или сразу после этого вызова.
    func sendPlanUnitDone(planId: String, day: Date = Date()) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.transferUserInfo([
            "kind": "planUnitDone",
            "planId": planId,
            "day": ISO8601DayFormatter.string(from: day)
        ])
    }

    // MARK: - Применение снимка (MainActor)

    @MainActor
    private static func apply(_ context: [String: Any]) {
        guard let data = context[WatchSnapshot.contextKey] as? Data,
              WatchSnapshot.decode(data) != nil else { return }

        UserDefaults.standard.set(data, forKey: WatchSnapshot.userDefaultsKey)
        NotificationCenter.default.post(name: WatchSnapshot.didChangeNotification, object: nil)
    }
}
