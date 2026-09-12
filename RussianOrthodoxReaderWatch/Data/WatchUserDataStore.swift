//
//  WatchUserDataStore.swift
//  RussianOrthodoxReaderWatch
//
//  Читает снимок пользовательских данных (моё правило, закладки, помянник,
//  планы чтения), который телефон присылает через WatchConnectivity. Часы
//  только читают снимок целиком — правки делаются на iPhone.
//  WatchSessionReceiver кладёт JSON снимка в UserDefaults под
//  WatchSnapshot.userDefaultsKey и рассылает WatchSnapshot.didChangeNotification;
//  этот класс просто следит за этим.
//
//  Исключение — отметка «прочитано сегодня» по плану чтения (§4.6
//  akathist_psalter_design.md): единственный канал записи с часов. До того
//  как телефон подтвердит её новым снимком, кольцо должно среагировать
//  сразу — для этого здесь же живёт `pendingDone`, оптимистичная надбавка
//  поверх последнего снимка.
//

import Foundation
import Combine

@MainActor
final class WatchUserDataStore: ObservableObject {
    static let shared = WatchUserDataStore()

    @Published private(set) var snapshot: WatchSnapshot?

    /// Отметки «прочитано», отправленные на телефон, но ещё не
    /// подтверждённые новым снимком — `planUUID → множество дней
    /// (`ISO8601DayFormatter`, всегда «сегодня» на момент отправки)`.
    /// Персистентно в `UserDefaults`, чтобы пережить перезапуск часов между
    /// отправкой и ответом телефона.
    @Published private(set) var pendingDone: [String: Set<String>] = [:]

    private var cancellable: AnyCancellable?

    private static let pendingDoneKey = "watch.pendingPlanDone"
    /// Снимается по TTL, даже если снимок так и не подтвердил отметку —
    /// «телефон всё равно сверит» (§4.6). Дни, а не секунды с момента
    /// отправки: `pendingDone` хранит только календарный день отметки, и
    /// этого достаточно, чтобы не плодить отдельное поле с временем записи.
    private static let pendingDoneTTLDays = 3

    private init() {
        let stored = WatchSnapshot.loadStored()
        snapshot = stored
        Self.seedDefaultsIfNeeded(from: stored)
        pendingDone = Self.loadPendingDone()
        reconcilePendingDone(with: stored)

        cancellable = NotificationCenter.default
            .publisher(for: WatchSnapshot.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updated = WatchSnapshot.loadStored()
                self.snapshot = updated
                self.reconcilePendingDone(with: updated)
            }
    }

    var hasSnapshot: Bool { snapshot != nil }

    var myRuleSlugs: [String] { snapshot?.myRuleSlugs ?? [] }
    var bookmarkSlugs: [String] { snapshot?.bookmarkSlugs ?? [] }

    /// Планы чтения из последнего снимка, с наложенными неподтверждёнными
    /// отметками (`pendingDone`) — кольцо и «сегодня отмечено» реагируют
    /// на отметку с часов немедленно, не дожидаясь ответа телефона.
    var plans: [WatchSnapshot.Plan] {
        (snapshot?.plans ?? []).map(applyPendingOverlay)
    }

    func entries(in list: PomyannikList) -> [WatchSnapshot.Entry] {
        snapshot?.entries(in: list) ?? []
    }

    // MARK: - Отметка «прочитано» (оптимистично, до ответа телефона)

    /// Регистрирует отметку локально сразу после отправки на телефон
    /// (`WatchSessionReceiver.sendPlanUnitDone`). Идемпотентно по дню — как
    /// и `ReadingPlansStore.markDone` на телефоне.
    func markPendingDone(planUUID: String, on day: Date = Date()) {
        let dayKey = ISO8601DayFormatter.string(from: day)
        var days = pendingDone[planUUID] ?? []
        guard !days.contains(dayKey) else { return }
        days.insert(dayKey)
        pendingDone[planUUID] = days
        persistPendingDone()
    }

    private func applyPendingOverlay(_ plan: WatchSnapshot.Plan) -> WatchSnapshot.Plan {
        guard let days = pendingDone[plan.uuid], !days.isEmpty else { return plan }
        var overlaid = plan
        overlaid.completedCount += days.count
        overlaid.doneToday = true
        return overlaid
    }

    /// Снимает отметки, которые снимок уже подтвердил (`doneToday == true`
    /// для этого плана), и отметки старше TTL — на случай, если
    /// `transferUserInfo` потерялось, а следующий обычный снимок почему-то
    /// не пришёл. Вызывается при загрузке и на каждый новый снимок.
    private func reconcilePendingDone(with snapshot: WatchSnapshot?) {
        guard !pendingDone.isEmpty else { return }
        var changed = false

        if let confirmedPlans = snapshot?.plans {
            for plan in confirmedPlans where plan.doneToday {
                if pendingDone.removeValue(forKey: plan.uuid) != nil {
                    changed = true
                }
            }
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.pendingDoneTTLDays, to: Date()) ?? .distantPast
        for (uuid, days) in pendingDone {
            let fresh = days.filter { dayKey in
                guard let date = ISO8601DayFormatter.date(from: dayKey) else { return false }
                return date >= cutoff
            }
            if fresh.isEmpty {
                pendingDone.removeValue(forKey: uuid)
                changed = true
            } else if fresh.count != days.count {
                pendingDone[uuid] = fresh
                changed = true
            }
        }

        if changed { persistPendingDone() }
    }

    private static func loadPendingDone() -> [String: Set<String>] {
        guard let data = UserDefaults.standard.data(forKey: pendingDoneKey),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return raw.mapValues(Set.init)
    }

    private func persistPendingDone() {
        let raw = pendingDone.mapValues(Array.init)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingDoneKey)
    }

    /// При первом запуске часов подставляем язык/ударения из настроек телефона —
    /// дальше пользователь управляет ими независимо на часах.
    private static func seedDefaultsIfNeeded(from snapshot: WatchSnapshot?) {
        guard let snapshot else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "watch.prayerLanguage") == nil, let language = snapshot.prayerLanguage {
            defaults.set(language, forKey: "watch.prayerLanguage")
        }
        if defaults.object(forKey: "watch.showStress") == nil, let showStress = snapshot.showStress {
            defaults.set(showStress, forKey: "watch.showStress")
        }
    }
}
