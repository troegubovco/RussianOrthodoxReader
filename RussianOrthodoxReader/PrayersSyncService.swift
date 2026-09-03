import CloudKit
import Foundation
import SwiftData
import os

/// CloudKit-синхронизация пользовательских данных раздела «Молитвы»:
/// записи помянника и закладки. Второй экземпляр CKSyncEngine в собственной
/// зоне PrayersZone — не трогает ReadingStateSyncService.
///
/// Модель конфликтов: last-writer-wins по полю modifiedAt каждой записи.
/// Источник истины офлайн — SwiftData (PomyannikEntryEntity, PrayerBookmarkEntity).
final class PrayersSyncService: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    static let shared = PrayersSyncService()

    private static let containerIdentifier = "iCloud.OG.RussianOrthodoxReader"
    private static let subscriptionID = "prayers-sync"
    private static let zoneName = "PrayersZone"
    private static let writeDebounceNanoseconds: UInt64 = 2_000_000_000

    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    enum RecordType {
        static let pomyannikEntry = "PomyannikEntry"
        static let prayerBookmark = "PrayerBookmark"
        static let myRuleItem = "MyRuleItem"
        static let readingPlan = "ReadingPlan"
        static let readingPlanUnit = "ReadingPlanUnit"
    }

    private static let bookmarkPrefix = "bm-"
    private static let rulePrefix = "rule-"
    // Определены в Shared/ReadingPlanModels.swift, чтобы ReadingPlansStore и
    // этот сервис не могли разойтись в написании префикса.
    private static let planPrefix = ReadingPlanSync.planPrefix
    private static let planUnitPrefix = ReadingPlanSync.planUnitPrefix

    private let container = CKContainer(identifier: containerIdentifier)
    private let logger = Logger(subsystem: "OG.RussianOrthodoxReader", category: "PrayersSync")
    private let recordCache = PrayersRecordCache()
    private let debouncer = PrayersSyncDebouncer()
    private let stateStore = PrayersSyncStateStore()

    private lazy var syncEngine: CKSyncEngine = {
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: PrayersSyncStorage.loadStateSerialization(),
            delegate: self
        )
        configuration.automaticallySync = true
        configuration.subscriptionID = Self.subscriptionID
        return CKSyncEngine(configuration)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Жизненный цикл

    /// Подключает обработчики мутаций стора и запускает синк (если включён).
    @MainActor
    func activate(enabled: Bool) async {
        PrayersSyncHooks.didSaveBookmark = { slug in
            Task { await PrayersSyncService.shared.enqueueSave(recordName: Self.bookmarkPrefix + slug) }
        }
        PrayersSyncHooks.didDeleteBookmark = { slug in
            Task { await PrayersSyncService.shared.enqueueDelete(recordName: Self.bookmarkPrefix + slug) }
        }
        PrayersSyncHooks.didSaveEntry = { uuid in
            Task { await PrayersSyncService.shared.enqueueSave(recordName: uuid) }
        }
        PrayersSyncHooks.didDeleteEntry = { uuid in
            Task { await PrayersSyncService.shared.enqueueDelete(recordName: uuid) }
        }
        PrayersSyncHooks.didSaveRuleItem = { slug in
            Task { await PrayersSyncService.shared.enqueueSave(recordName: Self.rulePrefix + slug) }
        }
        PrayersSyncHooks.didDeleteRuleItem = { slug in
            Task { await PrayersSyncService.shared.enqueueDelete(recordName: Self.rulePrefix + slug) }
        }
        ReadingPlansSyncHooks.didSavePlan = { uuid in
            Task { await PrayersSyncService.shared.enqueueSave(recordName: Self.planPrefix + uuid) }
        }
        ReadingPlansSyncHooks.didDeletePlan = { uuid in
            Task { await PrayersSyncService.shared.enqueueDelete(recordName: Self.planPrefix + uuid) }
        }
        ReadingPlansSyncHooks.didSaveUnit = { recordName in
            Task { await PrayersSyncService.shared.enqueueSave(recordName: recordName) }
        }
        ReadingPlansSyncHooks.didDeleteUnit = { recordName in
            Task { await PrayersSyncService.shared.enqueueDelete(recordName: recordName) }
        }
        await setSyncEnabled(enabled)
    }

    func setSyncEnabled(_ enabled: Bool) async {
        await stateStore.setEnabled(enabled)
        guard enabled else {
            await debouncer.cancel()
            return
        }
        await start()
    }

    private func start() async {
        guard await stateStore.beginStartIfNeeded() else { return }

        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        // Однократная миграция: заталкиваем локальные записи, созданные до
        // включения синка. В дальнейшем движок сам помнит незавершённые
        // изменения в сериализованном состоянии, поэтому повторять не нужно —
        // иначе каждый запуск порождает шторм serverRecordChanged.
        if !PrayersSyncStorage.loadDidInitialPush() {
            let localNames = await MainActor.run { Self.allLocalRecordNames() }
            if !localNames.isEmpty {
                syncEngine.state.add(pendingRecordZoneChanges: localNames.map {
                    .saveRecord(CKRecord.ID(recordName: $0, zoneID: Self.zoneID))
                })
            }
            PrayersSyncStorage.markInitialPushDone()
        }

        do {
            try await syncEngine.fetchChanges()
            try await syncEngine.sendChanges()
        } catch {
            logger.error("Prayers sync start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Повторная синхронизация вне контекста колбэка делегата (после входа в
    /// аккаунт). CKSyncEngine падает, если fetch/send вызвать из делегата.
    private func scheduleResync() {
        Task.detached { [weak self] in
            guard let self, await self.stateStore.isEnabled() else { return }
            self.syncEngine.state.add(
                pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            do {
                try await self.syncEngine.fetchChanges()
                try await self.syncEngine.sendChanges()
            } catch {
                self.logger.error("Prayers sync resync failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Очередь изменений (вызывается из PrayersSyncHooks)

    func enqueueSave(recordName: String) async {
        guard await stateStore.isEnabled() else { return }
        syncEngine.state.add(pendingRecordZoneChanges: [
            .saveRecord(CKRecord.ID(recordName: recordName, zoneID: Self.zoneID))
        ])
        await scheduleSend()
    }

    func enqueueDelete(recordName: String) async {
        guard await stateStore.isEnabled() else { return }
        syncEngine.state.add(pendingRecordZoneChanges: [
            .deleteRecord(CKRecord.ID(recordName: recordName, zoneID: Self.zoneID))
        ])
        await recordCache.remove(recordName)
        await scheduleSend()
    }

    private func scheduleSend() async {
        await debouncer.schedule(delayNanoseconds: Self.writeDebounceNanoseconds) { [weak self] in
            guard let self else { return }
            do {
                try await self.syncEngine.sendChanges()
            } catch {
                self.logger.error("Prayers sync send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            PrayersSyncStorage.persistStateSerialization(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            switch accountChange.changeType {
            case .signIn:
                // НЕ вызывать fetch/send напрямую из колбэка делегата —
                // CKSyncEngine это запрещает. Переносим в detached-задачу.
                scheduleResync()
            case .signOut, .switchAccounts:
                await debouncer.cancel()
                await recordCache.removeAll()
            @unknown default:
                break
            }

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications
            where modification.record.recordID.zoneID == Self.zoneID {
                await applyRemoteRecord(modification.record)
            }
            for deletion in changes.deletions
            where deletion.recordID.zoneID == Self.zoneID {
                await applyRemoteDeletion(recordName: deletion.recordID.recordName)
            }

        case .sentRecordZoneChanges(let changes):
            for saved in changes.savedRecords {
                await recordCache.store(saved)
            }
            for failedSave in changes.failedRecordSaves {
                await handleFailedSave(failedSave, syncEngine: syncEngine)
            }
            for (recordID, error) in changes.failedRecordDeletes {
                // Удаление несуществующей записи — не ошибка для нас.
                if error.code != .unknownItem {
                    logger.error("Prayers sync delete failed for \(recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

        case .sentDatabaseChanges, .didSendChanges, .willSendChanges,
             .willFetchChanges, .didFetchChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .fetchedDatabaseChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !pendingChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { recordID in
            await self.recordForPendingSave(recordID: recordID)
        }
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                 syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = CKSyncEngine.FetchChangesOptions()
        options.prioritizedZoneIDs = [Self.zoneID]
        return options
    }

    // MARK: - Построение записей (локальное → CKRecord)

    private func recordForPendingSave(recordID: CKRecord.ID) async -> CKRecord? {
        let base = await recordCache.record(recordID.recordName)
        return await MainActor.run {
            Self.buildRecord(recordName: recordID.recordName, base: base)
        }
    }

    @MainActor
    private static func buildRecord(recordName: String, base: CKRecord?) -> CKRecord? {
        let context = PersistenceController.shared.container.mainContext

        if recordName.hasPrefix(bookmarkPrefix) {
            let slug = String(recordName.dropFirst(bookmarkPrefix.count))
            var descriptor = FetchDescriptor<PrayerBookmarkEntity>(
                predicate: #Predicate { $0.prayerSlug == slug })
            descriptor.fetchLimit = 1
            guard let bookmark = try? context.fetch(descriptor).first else { return nil }
            let record = base ?? CKRecord(
                recordType: RecordType.prayerBookmark,
                recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
            record["prayerSlug"] = bookmark.prayerSlug
            record["createdAt"] = bookmark.createdAt
            record["modifiedAt"] = bookmark.modifiedAt
            return record
        }

        if recordName.hasPrefix(rulePrefix) {
            let slug = String(recordName.dropFirst(rulePrefix.count))
            var descriptor = FetchDescriptor<MyRuleItemEntity>(
                predicate: #Predicate { $0.prayerSlug == slug })
            descriptor.fetchLimit = 1
            guard let item = try? context.fetch(descriptor).first else { return nil }
            let record = base ?? CKRecord(
                recordType: RecordType.myRuleItem,
                recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
            record["prayerSlug"] = item.prayerSlug
            record["sortOrder"] = item.sortOrder
            record["createdAt"] = item.createdAt
            record["modifiedAt"] = item.modifiedAt
            return record
        }

        if recordName.hasPrefix(planUnitPrefix) {
            var descriptor = FetchDescriptor<ReadingPlanUnitEntity>(
                predicate: #Predicate { $0.recordName == recordName })
            descriptor.fetchLimit = 1
            guard let unit = try? context.fetch(descriptor).first else { return nil }
            let record = base ?? CKRecord(
                recordType: RecordType.readingPlanUnit,
                recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
            record["planUUID"] = unit.planUUID
            record["unitIndex"] = unit.unitIndex
            record["completedOn"] = unit.completedOn
            record["createdAt"] = unit.createdAt
            record["modifiedAt"] = unit.modifiedAt
            return record
        }

        if recordName.hasPrefix(planPrefix) {
            let uuid = String(recordName.dropFirst(planPrefix.count))
            var descriptor = FetchDescriptor<ReadingPlanEntity>(
                predicate: #Predicate { $0.uuid == uuid })
            descriptor.fetchLimit = 1
            guard let plan = try? context.fetch(descriptor).first else { return nil }
            let record = base ?? CKRecord(
                recordType: RecordType.readingPlan,
                recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
            record["kindRaw"] = plan.kindRaw
            record["subjectSlug"] = plan.subjectSlug
            record["startDate"] = plan.startDate
            record["totalUnits"] = plan.totalUnits
            record["endDateRule"] = plan.endDateRule
            record["endDate"] = plan.endDate
            record["reminderTime"] = plan.reminderTime
            record["isArchived"] = plan.isArchived ? 1 : 0
            record["createdAt"] = plan.createdAt
            record["modifiedAt"] = plan.modifiedAt
            return record
        }

        let uuid = recordName
        var descriptor = FetchDescriptor<PomyannikEntryEntity>(
            predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return nil }
        let record = base ?? CKRecord(
            recordType: RecordType.pomyannikEntry,
            recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        record["list"] = entry.listRaw
        record["inputName"] = entry.inputName
        record["canonicalName"] = entry.canonicalName
        record["canonicalGen"] = entry.canonicalGen
        record["canonicalAcc"] = entry.canonicalAcc
        record["gender"] = entry.genderRaw
        record["status"] = entry.status
        record["createdAt"] = entry.createdAt
        record["modifiedAt"] = entry.modifiedAt
        record["sortOrder"] = entry.sortOrder
        return record
    }

    // MARK: - Применение удалённых изменений (CKRecord → локальное)

    private func handleFailedSave(_ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
                                  syncEngine: CKSyncEngine) async {
        let recordID = failedSave.record.recordID

        switch failedSave.error.code {
        case .serverRecordChanged:
            guard let serverRecord = failedSave.error.serverRecord else { return }
            let localModified = failedSave.record["modifiedAt"] as? Date ?? .distantPast
            let remoteModified = serverRecord["modifiedAt"] as? Date ?? .distantPast
            await recordCache.store(serverRecord)
            if localModified >= remoteModified {
                // Локальная версия новее — повторяем отправку поверх серверной.
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                await scheduleSend()
            } else {
                await applyRemoteRecord(serverRecord)
            }

        case .zoneNotFound, .userDeletedZone:
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

        default:
            logger.error("Prayers sync save failed for \(recordID.recordName, privacy: .public): \(failedSave.error.localizedDescription, privacy: .public)")
        }
    }

    private func applyRemoteRecord(_ record: CKRecord) async {
        await recordCache.store(record)
        await MainActor.run {
            Self.upsertLocal(from: record)
            PrayersUserDataStore.shared.applyRemoteChanges()
        }
    }

    private func applyRemoteDeletion(recordName: String) async {
        await recordCache.remove(recordName)
        await MainActor.run {
            Self.deleteLocal(recordName: recordName)
            PrayersUserDataStore.shared.applyRemoteChanges()
        }
    }

    @MainActor
    private static func upsertLocal(from record: CKRecord) {
        let context = PersistenceController.shared.container.mainContext
        let remoteModified = record["modifiedAt"] as? Date ?? .distantPast

        switch record.recordType {
        case RecordType.prayerBookmark:
            guard let slug = record["prayerSlug"] as? String else { return }
            var descriptor = FetchDescriptor<PrayerBookmarkEntity>(
                predicate: #Predicate { $0.prayerSlug == slug })
            descriptor.fetchLimit = 1
            if let existing = try? context.fetch(descriptor).first {
                guard remoteModified > existing.modifiedAt else { return }
                existing.createdAt = record["createdAt"] as? Date ?? existing.createdAt
                existing.modifiedAt = remoteModified
            } else {
                context.insert(PrayerBookmarkEntity(
                    prayerSlug: slug,
                    createdAt: record["createdAt"] as? Date ?? Date(),
                    modifiedAt: remoteModified))
            }
            try? context.save()

        case RecordType.myRuleItem:
            guard let slug = record["prayerSlug"] as? String else { return }
            var descriptor = FetchDescriptor<MyRuleItemEntity>(
                predicate: #Predicate { $0.prayerSlug == slug })
            descriptor.fetchLimit = 1
            if let existing = try? context.fetch(descriptor).first {
                guard remoteModified > existing.modifiedAt else { return }
                existing.sortOrder = record["sortOrder"] as? Int ?? existing.sortOrder
                existing.modifiedAt = remoteModified
            } else {
                context.insert(MyRuleItemEntity(
                    prayerSlug: slug,
                    sortOrder: record["sortOrder"] as? Int ?? 0,
                    createdAt: record["createdAt"] as? Date ?? Date(),
                    modifiedAt: remoteModified))
            }
            try? context.save()

        case RecordType.readingPlanUnit:
            let recordName = record.recordID.recordName
            var descriptor = FetchDescriptor<ReadingPlanUnitEntity>(
                predicate: #Predicate { $0.recordName == recordName })
            descriptor.fetchLimit = 1
            if let existing = try? context.fetch(descriptor).first {
                guard remoteModified > existing.modifiedAt else { return }
                existing.completedOn = record["completedOn"] as? Date ?? existing.completedOn
                existing.modifiedAt = remoteModified
            } else {
                context.insert(ReadingPlanUnitEntity(
                    recordName: recordName,
                    planUUID: record["planUUID"] as? String ?? "",
                    unitIndex: record["unitIndex"] as? Int ?? 0,
                    completedOn: record["completedOn"] as? Date ?? Date(),
                    createdAt: record["createdAt"] as? Date ?? Date(),
                    modifiedAt: remoteModified))
            }
            try? context.save()

        case RecordType.readingPlan:
            let recordName = record.recordID.recordName
            let uuid = recordName.hasPrefix(planPrefix)
                ? String(recordName.dropFirst(planPrefix.count))
                : recordName
            var descriptor = FetchDescriptor<ReadingPlanEntity>(
                predicate: #Predicate { $0.uuid == uuid })
            descriptor.fetchLimit = 1
            let plan: ReadingPlanEntity
            if let existing = try? context.fetch(descriptor).first {
                guard remoteModified > existing.modifiedAt else { return }
                plan = existing
            } else {
                let created = ReadingPlanEntity(
                    uuid: uuid,
                    kindRaw: record["kindRaw"] as? String ?? "",
                    subjectSlug: record["subjectSlug"] as? String,
                    startDate: record["startDate"] as? Date ?? Date(),
                    totalUnits: record["totalUnits"] as? Int ?? 0)
                context.insert(created)
                plan = created
            }
            plan.kindRaw = record["kindRaw"] as? String ?? plan.kindRaw
            plan.subjectSlug = record["subjectSlug"] as? String
            plan.startDate = record["startDate"] as? Date ?? plan.startDate
            plan.totalUnits = record["totalUnits"] as? Int ?? plan.totalUnits
            plan.endDateRule = record["endDateRule"] as? String
            plan.endDate = record["endDate"] as? Date
            plan.reminderTime = record["reminderTime"] as? String
            plan.isArchived = ((record["isArchived"] as? Int) ?? 0) != 0
            plan.createdAt = record["createdAt"] as? Date ?? plan.createdAt
            plan.modifiedAt = remoteModified
            try? context.save()

        case RecordType.pomyannikEntry:
            let uuid = record.recordID.recordName
            var descriptor = FetchDescriptor<PomyannikEntryEntity>(
                predicate: #Predicate { $0.uuid == uuid })
            descriptor.fetchLimit = 1
            let entry: PomyannikEntryEntity
            if let existing = try? context.fetch(descriptor).first {
                guard remoteModified > existing.modifiedAt else { return }
                entry = existing
            } else {
                let created = PomyannikEntryEntity(
                    uuid: uuid,
                    listRaw: record["list"] as? String ?? PomyannikList.health.rawValue,
                    inputName: record["inputName"] as? String ?? "",
                    canonicalName: record["canonicalName"] as? String ?? "",
                    canonicalGen: record["canonicalGen"] as? String ?? "",
                    canonicalAcc: record["canonicalAcc"] as? String ?? "",
                    genderRaw: record["gender"] as? String ?? PersonGender.male.rawValue)
                context.insert(created)
                entry = created
            }
            entry.listRaw = record["list"] as? String ?? entry.listRaw
            entry.inputName = record["inputName"] as? String ?? entry.inputName
            entry.canonicalName = record["canonicalName"] as? String ?? entry.canonicalName
            entry.canonicalGen = record["canonicalGen"] as? String ?? entry.canonicalGen
            entry.canonicalAcc = record["canonicalAcc"] as? String ?? entry.canonicalAcc
            entry.genderRaw = record["gender"] as? String ?? entry.genderRaw
            entry.status = record["status"] as? String
            entry.createdAt = record["createdAt"] as? Date ?? entry.createdAt
            entry.modifiedAt = remoteModified
            entry.sortOrder = record["sortOrder"] as? Int ?? entry.sortOrder
            try? context.save()

        default:
            break
        }
    }

    @MainActor
    private static func deleteLocal(recordName: String) {
        let context = PersistenceController.shared.container.mainContext

        if recordName.hasPrefix(bookmarkPrefix) {
            let slug = String(recordName.dropFirst(bookmarkPrefix.count))
            var descriptor = FetchDescriptor<PrayerBookmarkEntity>(
                predicate: #Predicate { $0.prayerSlug == slug })
            descriptor.fetchLimit = 1
            if let bookmark = try? context.fetch(descriptor).first {
                context.delete(bookmark)
                try? context.save()
            }
            return
        }

        if recordName.hasPrefix(rulePrefix) {
            let slug = String(recordName.dropFirst(rulePrefix.count))
            var descriptor = FetchDescriptor<MyRuleItemEntity>(
                predicate: #Predicate { $0.prayerSlug == slug })
            descriptor.fetchLimit = 1
            if let item = try? context.fetch(descriptor).first {
                context.delete(item)
                try? context.save()
            }
            return
        }

        if recordName.hasPrefix(planUnitPrefix) {
            var descriptor = FetchDescriptor<ReadingPlanUnitEntity>(
                predicate: #Predicate { $0.recordName == recordName })
            descriptor.fetchLimit = 1
            if let unit = try? context.fetch(descriptor).first {
                context.delete(unit)
                try? context.save()
            }
            return
        }

        if recordName.hasPrefix(planPrefix) {
            let uuid = String(recordName.dropFirst(planPrefix.count))
            var descriptor = FetchDescriptor<ReadingPlanEntity>(
                predicate: #Predicate { $0.uuid == uuid })
            descriptor.fetchLimit = 1
            if let plan = try? context.fetch(descriptor).first {
                context.delete(plan)
                try? context.save()
            }
            return
        }

        let uuid = recordName
        var descriptor = FetchDescriptor<PomyannikEntryEntity>(
            predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        if let entry = try? context.fetch(descriptor).first {
            context.delete(entry)
            try? context.save()
        }
    }

    @MainActor
    private static func allLocalRecordNames() -> [String] {
        let context = PersistenceController.shared.container.mainContext
        var names: [String] = []
        if let entries = try? context.fetch(FetchDescriptor<PomyannikEntryEntity>()) {
            names.append(contentsOf: entries.map(\.uuid))
        }
        if let bookmarks = try? context.fetch(FetchDescriptor<PrayerBookmarkEntity>()) {
            names.append(contentsOf: bookmarks.map { bookmarkPrefix + $0.prayerSlug })
        }
        if let items = try? context.fetch(FetchDescriptor<MyRuleItemEntity>()) {
            names.append(contentsOf: items.map { rulePrefix + $0.prayerSlug })
        }
        if let readingPlans = try? context.fetch(FetchDescriptor<ReadingPlanEntity>()) {
            names.append(contentsOf: readingPlans.map { planPrefix + $0.uuid })
        }
        if let readingPlanUnits = try? context.fetch(FetchDescriptor<ReadingPlanUnitEntity>()) {
            names.append(contentsOf: readingPlanUnits.map(\.recordName))
        }
        return names
    }
}

// MARK: - Кэш серверных записей (change-tag'и для повторной отправки)

private actor PrayersRecordCache {
    private var records: [String: CKRecord] = [:]

    func store(_ record: CKRecord) {
        records[record.recordID.recordName] = record
    }

    func record(_ name: String) -> CKRecord? {
        records[name]
    }

    func remove(_ name: String) {
        records[name] = nil
    }

    func removeAll() {
        records.removeAll()
    }
}

// MARK: - Дебаунсер отправки

private actor PrayersSyncDebouncer {
    private var task: Task<Void, Never>?

    func schedule(delayNanoseconds: UInt64, operation: @escaping @Sendable () async -> Void) {
        task?.cancel()
        // ВАЖНО: Task.detached, не Task {} — отправка планируется в том числе
        // из колбэка делегата (handleFailedSave), а обычный Task наследует
        // task-local-маркер CKSyncEngine «внутри колбэка». Тогда отложенный
        // sendChanges() падает с fatalError «Cannot await a call into
        // CKSyncEngine from within a delegate callback».
        task = Task.detached {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Состояние (включён/запущен)

private actor PrayersSyncStateStore {
    private var enabled = false
    private var started = false

    func setEnabled(_ value: Bool) {
        enabled = value
    }

    func isEnabled() -> Bool {
        enabled
    }

    /// true — если синк включён и ещё не запускался.
    func beginStartIfNeeded() -> Bool {
        guard enabled, !started else { return false }
        started = true
        return true
    }
}

// MARK: - Хранение сериализации движка

// nonisolated: вызывается из неизолированных колбэков движка; UserDefaults
// потокобезопасен (та же схема, что ReadingStateSyncStorage).
nonisolated private enum PrayersSyncStorage {
    private static let stateKey = "prayersSync.engineState"
    private static let didInitialPushKey = "prayersSync.didInitialPush"

    static func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    static func persistStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }

    static func loadDidInitialPush() -> Bool {
        UserDefaults.standard.bool(forKey: didInitialPushKey)
    }

    static func markInitialPushDone() {
        UserDefaults.standard.set(true, forKey: didInitialPushKey)
    }
}
