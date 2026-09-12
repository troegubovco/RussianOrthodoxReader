//
//  WatchSnapshotSender.swift
//  RussianOrthodoxReader
//
//  Отправляет снимок пользовательских данных молитвослова (WatchSnapshot) на
//  Apple Watch через WatchConnectivity. Часы только читают — вся мутация
//  происходит на телефоне в PrayersUserDataStore, которая после каждого
//  reload() дёргает scheduleSend().
//

#if os(iOS) && canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

/// nonisolated: WCSessionDelegate — objc-протокол, колбэки которого система
/// вызывает на произвольной (не главной) очереди. Под MainActor-изоляцией по
/// умолчанию для этого таргета класс обязан быть nonisolated, а работу с
/// изолированным состоянием (PrayersUserDataStore, UserDefaults настроек)
/// нужно явно переносить на MainActor через Task { @MainActor in … }
/// (см. аналогичный приём в PrayersSyncService.swift).
nonisolated final class WatchSnapshotSender: NSObject, WCSessionDelegate {
    static let shared = WatchSnapshotSender()

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
            print("WatchSnapshotSender: activation failed — \(error.localizedDescription)")
        }
        Task { @MainActor in
            WatchSnapshotSender.shared.scheduleSend()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            WatchSnapshotSender.shared.scheduleSend()
        }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Требуется реактивировать сессию (например, после переключения
        // между часами в паре с несколькими Apple Watch).
        session.activate()
        Task { @MainActor in
            WatchSnapshotSender.shared.scheduleSend()
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            WatchSnapshotSender.shared.scheduleSend()
        }
    }

    /// Первый (и пока единственный) канал записи с часов на телефон (§4.6):
    /// отметка «прочитано» по плану чтения. `transferUserInfo`, а не
    /// `sendMessage` — ставится в очередь и переживает недоступность
    /// телефона (в кармане/сумке во время службы — обычный сценарий),
    /// `sendMessage` требует немедленной досягаемости.
    ///
    /// Безопасно ровно одним ограничением: с часов уходит только
    /// добавление отметки, никогда снятие — `ReadingPlansStore.markDone`
    /// идемпотентен по календарному дню, так что потерянное сообщение
    /// восстановится следующей отметкой, а продублированное безвредно.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["kind"] as? String == "planUnitDone",
              let planId = userInfo["planId"] as? String,
              let dayString = userInfo["day"] as? String,
              let day = ISO8601DayFormatter.date(from: dayString) else { return }
        Task { @MainActor in
            ReadingPlansStore.shared.markDone(planUUID: planId, on: day)
        }
    }

    // MARK: - Отправка (MainActor)

    @MainActor
    private var pendingSendTask: Task<Void, Never>?
    @MainActor
    private var lastSentData: Data?

    private static let debounceNanoseconds: UInt64 = 500_000_000

    /// Планирует отправку снимка с дебаунсом ~0.5 с — повторные вызовы за
    /// это время (например, серия правок помянника) схлопываются в одну
    /// отправку.
    @MainActor
    func scheduleSend() {
        pendingSendTask?.cancel()
        pendingSendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.sendNow()
        }
    }

    @MainActor
    private func sendNow() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }

        let store = PrayersUserDataStore.shared
        let entries = store.entries.map { entity in
            WatchSnapshot.Entry(
                uuid: entity.uuid,
                list: entity.listRaw,
                canonicalName: entity.canonicalName,
                canonicalGen: entity.canonicalGen,
                canonicalAcc: entity.canonicalAcc,
                gender: entity.genderRaw,
                status: entity.status)
        }
        let plans = ReadingPlansStore.shared.plans.map { plan in
            WatchSnapshot.Plan(
                uuid: plan.uuid,
                kind: plan.kind.rawKind,
                subjectSlug: plan.kind.subjectSlug,
                title: plan.title,
                totalUnits: plan.totalUnits,
                completedCount: plan.completedCount,
                doneToday: plan.doneToday,
                nextUnitIndex: plan.nextUnitIndex,
                nextUnitLabel: plan.nextUnitLabel,
                nextTargetSlug: plan.kind.target(for: plan.nextUnitIndex).prayerSlug)
        }

        let snapshot = WatchSnapshot(
            sentAt: Date(),
            myRuleSlugs: store.myRuleSlugs,
            bookmarkSlugs: store.bookmarkSlugs,
            pomyannik: entries,
            prayerLanguage: UserDefaults.standard.string(forKey: "prayerLanguage"),
            showStress: UserDefaults.standard.object(forKey: "prayerShowStress") as? Bool,
            plans: plans)

        do {
            let data = try snapshot.encoded()
            guard data != lastSentData else { return }
            try session.updateApplicationContext([WatchSnapshot.contextKey: data])
            lastSentData = data
        } catch {
            print("WatchSnapshotSender: failed to send snapshot — \(error.localizedDescription)")
        }
    }
}

#else

/// Пустая заглушка для платформ без WatchConnectivity (macOS-сборка того же
/// таргета) — сохраняет единый call site в PrayersUserDataStore.reload().
final class WatchSnapshotSender {
    static let shared = WatchSnapshotSender()

    private init() {}

    func activate() {}

    func scheduleSend() {}
}

#endif
