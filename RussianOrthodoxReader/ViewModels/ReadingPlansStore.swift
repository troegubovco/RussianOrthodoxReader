import Combine
import Foundation
import SwiftData
import SwiftUI

/// Единая точка записи планов чтения («Мои чтения»): зеркало
/// `PrayersUserDataStore` в том же стиле — `@MainActor`, единственный путь
/// записи, `reload()` в конце каждой мутации, хуки синка, отправка снимка на
/// часы. См. §4.4 akathist_psalter_design.md.
///
/// Модель плана — счётчик (§4.1): единица плана (`unitIndex`) — порядковый
/// номер прочтения, не положение в календаре. Отметки — отдельные записи
/// `ReadingPlanUnitEntity`, индекс новой отметки всегда
/// `max(существующие индексы) + 1`, а не `count` — иначе снятие отметки из
/// середины (`unmark`) освобождало бы индекс, который затем коллизировал бы
/// с уже существующей более поздней записью.
@MainActor
final class ReadingPlansStore: ObservableObject {
    static let shared = ReadingPlansStore()

    /// Только активные (не архивные) планы — этот массив и есть источник
    /// правды для «не более трёх планов одновременно» (§4.7/§8.8).
    @Published private(set) var plans: [ReadingPlanSnapshot] = []

    /// Бюджет уведомлений (§8.8): «Больше трёх чтений одновременно — уже не
    /// правило, а список дел». UI должен скрывать/дизейблить кнопку запуска
    /// нового плана, когда это `false`.
    var canStartNewPlan: Bool { plans.count < 3 }

    private let context: ModelContext

    private init(context: ModelContext? = nil) {
        self.context = context ?? PersistenceController.shared.container.mainContext
        reload()
        #if DEBUG
        FastPeriods.runSelfTest()
        WatchSnapshot.runV1CompatibilitySelfTest()
        #endif
    }

    func reload() {
        let descriptor = FetchDescriptor<ReadingPlanEntity>(
            predicate: #Predicate { $0.isArchived == false },
            sortBy: [SortDescriptor(\.createdAt)])
        let entities = (try? context.fetch(descriptor)) ?? []

        var snapshots: [ReadingPlanSnapshot] = []
        var reminders: [ReadingPlanReminderInfo] = []
        for entity in entities {
            guard let snapshot = snapshot(for: entity, units: fetchUnits(planUUID: entity.uuid)) else { continue }
            snapshots.append(snapshot)
            if let reminderTime = entity.reminderTime {
                reminders.append(ReadingPlanReminderInfo(
                    uuid: entity.uuid,
                    title: snapshot.title,
                    nextUnitLabel: snapshot.nextUnitLabel,
                    reminderTime: reminderTime,
                    doneToday: snapshot.doneToday))
            }
        }
        plans = snapshots

        // reload() — единственная точка, где меняются данные, доступные
        // Apple Watch, поэтому именно здесь планируем отправку снимка (тот
        // же приём, что в PrayersUserDataStore.reload()).
        WatchSnapshotSender.shared.scheduleSend()

        // Бюджет уведомлений (§4.7/§8.8): не более трёх активных планов —
        // `plans` уже отфильтрован по isArchived, здесь дополнительно
        // подстраховываемся на случай гонки создания четвёртого плана.
        let cappedReminders = Array(reminders.prefix(3))
        Task { await ReadingReminderScheduler.shared.applyPlanReminders(cappedReminders) }
    }

    // MARK: - Мутации

    /// Создаёт новый план и возвращает его `uuid`. Ограничение «не более трёх
    /// активных планов» — на стороне вызывающего UI через `canStartNewPlan`
    /// (сигнатура ниже фиксирована контрактом C0 и не может вернуть отказ).
    @discardableResult
    func start(kind: ReadingPlanKind, totalUnits: Int,
               endDateRule: String?, endDate: Date?, reminderTime: String?) -> String {
        let entity = ReadingPlanEntity(
            kindRaw: kind.rawKind,
            subjectSlug: kind.subjectSlug,
            startDate: Calendar.current.startOfDay(for: Date()),
            totalUnits: totalUnits,
            endDateRule: endDateRule,
            endDate: endDate,
            reminderTime: reminderTime)
        context.insert(entity)
        save()
        ReadingPlansSyncHooks.didSavePlan?(entity.uuid)
        reload()
        return entity.uuid
    }

    /// Идемпотентно по календарному дню устройства (§8.7, §4.4): если для
    /// плана уже есть отметка с тем же днём — ничего не делает. Это и делает
    /// канал отметок с часов (`WCSession.transferUserInfo`, §4.6) безопасным:
    /// потерянное сообщение восстановится следующей отметкой, продублированное
    /// безвредно.
    func markDone(planUUID: String, on day: Date = Date()) {
        guard let entity = fetchPlan(planUUID), !entity.isArchived else { return }

        let dayKey = ISO8601DayFormatter.string(from: day)
        let existingUnits = fetchUnits(planUUID: planUUID)
        guard !existingUnits.contains(where: { ISO8601DayFormatter.string(from: $0.completedOn) == dayKey }) else {
            return
        }
        guard existingUnits.count < entity.totalUnits else { return }   // план уже завершён

        let nextIndex = (existingUnits.map(\.unitIndex).max() ?? -1) + 1
        let recordName = ReadingPlanUnitEntity.recordName(planUUID: planUUID, unitIndex: nextIndex)
        let unit = ReadingPlanUnitEntity(
            recordName: recordName,
            planUUID: planUUID,
            unitIndex: nextIndex,
            completedOn: Calendar.current.startOfDay(for: day))
        context.insert(unit)
        save()
        ReadingPlansSyncHooks.didSaveUnit?(recordName)

        // Отметили сегодняшний день — снимаем вечернее напоминание сразу,
        // не дожидаясь следующей пересборки очереди в reload() (§4.7).
        if dayKey == ISO8601DayFormatter.string(from: Date()) {
            ReadingReminderScheduler.shared.cancelTodayPlanReminder(planUUID: planUUID)
        }
        reload()
    }

    /// Снятие отметки — только с телефона (см. §4.6: с часов уходит только
    /// добавление, никогда снятие).
    func unmark(planUUID: String, unitIndex: Int) {
        guard let unit = fetchUnit(planUUID: planUUID, unitIndex: unitIndex) else { return }
        let recordName = unit.recordName
        context.delete(unit)
        save()
        ReadingPlansSyncHooks.didDeleteUnit?(recordName)
        reload()
    }

    /// Останавливает план (архивирует, не удаляет — история отметок
    /// остаётся и на других устройствах).
    func stop(planUUID: String) {
        guard let entity = fetchPlan(planUUID) else { return }
        entity.isArchived = true
        entity.modifiedAt = Date()
        save()
        ReadingPlansSyncHooks.didSavePlan?(entity.uuid)
        reload()
    }

    /// Активный план, чья текущая единица (`nextUnitIndex`) открывает именно
    /// эту молитву — для карточки плана на экране молитвы (`PrayerDetailView`).
    /// Для кругового вида (`psalterKathisma`/`psalterSlava`/`greatCanon`)
    /// матчинг по всему семейству страниц этого вида (любая кафизма,
    /// любой день Великого канона), а не только по текущему дню — карточка
    /// плана должна быть видна независимо от того, на какой день листает
    /// пользователь.
    func plan(forTarget slug: String) -> ReadingPlanSnapshot? {
        plans.first { snapshot in
            switch snapshot.kind {
            case .dailyPrayer(let planSlug):
                return planSlug == slug
            case .psalterKathisma, .psalterSlava:
                return slug.hasPrefix("psaltir.kafizma-")
            case .greatCanon:
                return slug.hasPrefix("canons.velikij-kanon-")
            }
        }
    }

    // MARK: - Применение удалённых изменений (вызывается PrayersSyncService)

    func applyRemoteChanges() {
        reload()
    }

    // MARK: - Private

    private func snapshot(for entity: ReadingPlanEntity, units: [ReadingPlanUnitEntity]) -> ReadingPlanSnapshot? {
        guard let kind = entity.kind else { return nil }

        let completedCount = units.count
        let nextUnitIndex = (units.map(\.unitIndex).max() ?? -1) + 1
        let todayKey = ISO8601DayFormatter.string(from: Date())
        let doneToday = units.contains { ISO8601DayFormatter.string(from: $0.completedOn) == todayKey }

        let calendar = Calendar.current
        let daysSinceStart = max(0, calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: entity.startDate),
            to: calendar.startOfDay(for: Date())).day ?? 0)
        let missedDays = max(0, daysSinceStart - completedCount)

        let totalUnits = entity.totalUnits
        let progress = totalUnits > 0 ? min(1, Double(completedCount) / Double(totalUnits)) : 0

        return ReadingPlanSnapshot(
            uuid: entity.uuid,
            kind: kind,
            title: Self.title(for: kind),
            totalUnits: totalUnits,
            completedCount: completedCount,
            doneToday: doneToday,
            missedDays: missedDays,
            nextUnitIndex: nextUnitIndex,
            nextUnitLabel: kind.unitLabel(for: nextUnitIndex, total: totalUnits),
            endDate: entity.endDate,
            progress: progress)
    }

    /// Часы не ходят в БД молитв за названием (см. `WatchSnapshot.Plan.title`) —
    /// поэтому готовая строка вычисляется здесь, один раз за `reload()`.
    private static func title(for kind: ReadingPlanKind) -> String {
        switch kind {
        case .dailyPrayer(let slug):
            return PrayersRepository.shared.prayer(slug: slug)?.title ?? "Молитва"
        case .psalterKathisma:
            return "Псалтирь по кафизмам"
        case .psalterSlava:
            return "Псалтирь по «Славам»"
        case .greatCanon:
            return "Великий канон прп. Андрея Критского"
        }
    }

    private func fetchPlan(_ uuid: String) -> ReadingPlanEntity? {
        var descriptor = FetchDescriptor<ReadingPlanEntity>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchUnits(planUUID: String) -> [ReadingPlanUnitEntity] {
        let descriptor = FetchDescriptor<ReadingPlanUnitEntity>(
            predicate: #Predicate { $0.planUUID == planUUID })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchUnit(planUUID: String, unitIndex: Int) -> ReadingPlanUnitEntity? {
        var descriptor = FetchDescriptor<ReadingPlanUnitEntity>(
            predicate: #Predicate { $0.planUUID == planUUID && $0.unitIndex == unitIndex })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func save() {
        do {
            try context.save()
        } catch {
            print("ReadingPlansStore: ошибка сохранения — \(error)")
        }
    }
}

/// Слабая связка store → sync: PrayersSyncService назначает обработчики при
/// старте; без него мутации остаются локальными. Отдельный enum, а не
/// расширение `PrayersSyncHooks` — тот определён в `PrayersUserDataStore.swift`,
/// которую этот пакет не трогает (см. akathist_psalter_design.md §7 «Пакет B»).
@MainActor
enum ReadingPlansSyncHooks {
    /// Принимает голый `uuid` плана — префикс `"plan-"` добавляет
    /// PrayersSyncService (тот же приём, что `PrayersSyncHooks.didSaveBookmark`
    /// с голым slug'ом).
    static var didSavePlan: ((String) -> Void)?
    static var didDeletePlan: ((String) -> Void)?
    /// Принимает уже готовый `ReadingPlanUnitEntity.recordName`
    /// (`"planunit-<planUUID>-<index>"`) — префикс тут не добавляется, поле
    /// уже хранит полное имя записи.
    static var didSaveUnit: ((String) -> Void)?
    static var didDeleteUnit: ((String) -> Void)?
}
