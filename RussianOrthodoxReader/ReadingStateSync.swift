import CloudKit
import Foundation
import os.log

nonisolated enum ReadingSyncPhase: String, Sendable {
    case disabled
    case starting
    case syncing
    case idle
    case waitingForNetwork
    case accountUnavailable
    case error
}

nonisolated struct ReadingSyncSnapshot: Sendable {
    var state: ReadingState?
    var phase: ReadingSyncPhase
    var lastSyncDate: Date?
    var errorDescription: String?
    var isSyncEnabled: Bool
    var clearsLocalCache: Bool = false
}

nonisolated struct ReadingState: Codable, Equatable, Sendable {
    static let zoneName = "ReadingStateZone"
    static let recordType = "ReadingState"
    static let recordName = "current"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    static let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)

    let bookID: String
    let chapter: Int
    let verse: Int?
    let lastModified: Date
    let progressTimestamp: Date?
    let versionID: String?

    init(bookID: String,
         chapter: Int,
         verse: Int? = nil,
         lastModified: Date,
         progressTimestamp: Date? = nil,
         versionID: String? = nil) {
        self.bookID = bookID
        self.chapter = chapter
        self.verse = verse
        self.lastModified = lastModified
        self.progressTimestamp = progressTimestamp
        self.versionID = versionID
    }

    init?(route: ReaderRoute, lastModified: Date = Date(), versionID: String? = nil) {
        guard case let .chapter(bookID, chapter) = route else { return nil }
        self.init(
            bookID: bookID,
            chapter: chapter,
            verse: nil,
            lastModified: lastModified,
            progressTimestamp: lastModified,
            versionID: versionID
        )
    }

    init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
              let bookID = record["bookID"] as? String,
              let chapter = record["chapter"] as? Int else {
            return nil
        }

        self.init(
            bookID: bookID,
            chapter: chapter,
            verse: record["verse"] as? Int,
            lastModified: (record["lastModified"] as? Date) ?? record.modificationDate ?? Date(),
            progressTimestamp: record["progressTimestamp"] as? Date,
            versionID: record["versionID"] as? String
        )
    }

    var route: ReaderRoute {
        .chapter(bookId: bookID, chapter: chapter)
    }

    func makeRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: Self.recordID)
        record["bookID"] = bookID as CKRecordValue
        record["chapter"] = chapter as CKRecordValue
        if let verse {
            record["verse"] = verse as CKRecordValue
        }
        record["lastModified"] = lastModified as CKRecordValue
        if let progressTimestamp {
            record["progressTimestamp"] = progressTimestamp as CKRecordValue
        }
        if let versionID {
            record["versionID"] = versionID as CKRecordValue
        }
        return record
    }

    func rebased(lastModified: Date, progressTimestamp: Date?) -> ReadingState {
        ReadingState(
            bookID: bookID,
            chapter: chapter,
            verse: verse,
            lastModified: lastModified,
            progressTimestamp: progressTimestamp,
            versionID: versionID
        )
    }
}

nonisolated private struct ReadingStateConflictResolution {
    let resolvedState: ReadingState?
    let shouldUploadResolvedState: Bool
}

nonisolated private enum ReadingStateConflictResolver {
    static let mergeWindow: TimeInterval = 60

    static func resolve(local: ReadingState?, remote: ReadingState?, now: Date = Date()) -> ReadingStateConflictResolution {
        switch (local, remote) {
        case (nil, nil):
            return ReadingStateConflictResolution(resolvedState: nil, shouldUploadResolvedState: false)
        case let (local?, nil):
            return ReadingStateConflictResolution(resolvedState: local, shouldUploadResolvedState: true)
        case let (nil, remote?):
            return ReadingStateConflictResolution(resolvedState: remote, shouldUploadResolvedState: false)
        case let (local?, remote?):
            let delta = local.lastModified.timeIntervalSince(remote.lastModified)

            if abs(delta) >= mergeWindow {
                if delta > 0 {
                    return ReadingStateConflictResolution(resolvedState: local, shouldUploadResolvedState: true)
                }
                return ReadingStateConflictResolution(resolvedState: remote, shouldUploadResolvedState: false)
            }

            if let furthest = furthestProgress(local, remote) {
                let newest = delta >= 0 ? local : remote
                if furthest == newest {
                    return ReadingStateConflictResolution(
                        resolvedState: newest,
                        shouldUploadResolvedState: newest == local
                    )
                }

                let mergedProgressTimestamp = [local.progressTimestamp, remote.progressTimestamp, local.lastModified, remote.lastModified]
                    .compactMap { $0 }
                    .max()
                let merged = furthest.rebased(lastModified: now, progressTimestamp: mergedProgressTimestamp)
                return ReadingStateConflictResolution(resolvedState: merged, shouldUploadResolvedState: true)
            }

            if delta >= 0 {
                return ReadingStateConflictResolution(resolvedState: local, shouldUploadResolvedState: true)
            }
            return ReadingStateConflictResolution(resolvedState: remote, shouldUploadResolvedState: false)
        }
    }

    private static func furthestProgress(_ lhs: ReadingState, _ rhs: ReadingState) -> ReadingState? {
        if let lhsVersion = lhs.versionID, let rhsVersion = rhs.versionID, lhsVersion != rhsVersion {
            return nil
        }

        guard let comparison = compareProgress(lhs, rhs) else { return nil }
        switch comparison {
        case .orderedDescending: return lhs
        case .orderedAscending:  return rhs
        case .orderedSame:       return nil
        }
    }

    private static let bookOrder: [String: Int] = {
        Dictionary(uniqueKeysWithValues: BibleDataProvider.books.enumerated().map { ($0.element.id, $0.offset) })
    }()

    private static func compareProgress(_ lhs: ReadingState, _ rhs: ReadingState) -> ComparisonResult? {
        guard let lhsBook = bookOrder[lhs.bookID], let rhsBook = bookOrder[rhs.bookID] else {
            return nil
        }

        if lhsBook != rhsBook {
            return lhsBook < rhsBook ? .orderedAscending : .orderedDescending
        }
        if lhs.chapter != rhs.chapter {
            return lhs.chapter < rhs.chapter ? .orderedAscending : .orderedDescending
        }

        let lhsVerse = lhs.verse ?? 0
        let rhsVerse = rhs.verse ?? 0
        if lhsVerse != rhsVerse {
            return lhsVerse < rhsVerse ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

nonisolated private enum ReadingStateSyncStorage {
    private static let defaults = UserDefaults.standard
    private static let cachedStateKey = "readingSync.cachedState"
    private static let syncEnabledKey = "readingSync.enabled"
    private static let engineStateKey = "readingSync.engineState"
    private static let lastSyncDateKey = "readingSync.lastSyncDate"

    static func loadCachedState() -> ReadingState? {
        guard let data = defaults.data(forKey: cachedStateKey) else { return nil }
        return try? JSONDecoder().decode(ReadingState.self, from: data)
    }

    static func persistCachedState(_ state: ReadingState?) {
        if let state, let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: cachedStateKey)
        } else {
            defaults.removeObject(forKey: cachedStateKey)
        }
    }

    static func loadSyncEnabled() -> Bool {
        if defaults.object(forKey: syncEnabledKey) == nil {
            return true
        }
        return defaults.bool(forKey: syncEnabledKey)
    }

    static func persistSyncEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: syncEnabledKey)
    }

    static func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = defaults.data(forKey: engineStateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    static func persistStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        defaults.set(data, forKey: engineStateKey)
    }

    static func clearStateSerialization() {
        defaults.removeObject(forKey: engineStateKey)
    }

    static func loadLastSyncDate() -> Date? {
        defaults.object(forKey: lastSyncDateKey) as? Date
    }

    static func persistLastSyncDate(_ date: Date?) {
        if let date {
            defaults.set(date, forKey: lastSyncDateKey)
        } else {
            defaults.removeObject(forKey: lastSyncDateKey)
        }
    }
}

private actor ReadingSyncDebouncer {
    private var task: Task<Void, Never>?

    func schedule(delayNanoseconds: UInt64, operation: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
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

private enum ReadingSyncEngineCall {
    case send
    case fetch
}

private actor ReadingSyncEngineCallScheduler {
    private var isDraining = false
    private var pendingSend = false
    private var pendingFetch = false

    func enqueue(_ call: ReadingSyncEngineCall) -> Bool {
        switch call {
        case .send:
            pendingSend = true
        case .fetch:
            pendingFetch = true
        }

        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    func nextCall() -> ReadingSyncEngineCall? {
        if pendingSend {
            pendingSend = false
            return .send
        }
        if pendingFetch {
            pendingFetch = false
            return .fetch
        }

        isDraining = false
        return nil
    }
}

private actor ReadingStateSyncStore {
    private var cachedState: ReadingState?
    private var syncEnabled: Bool
    private var lastSyncDate: Date?
    private var phase: ReadingSyncPhase
    private var errorDescription: String?
    private var engineStarted = false
    private var awaitingInitialFetch = true
    private var sawRemoteStateDuringFetch = false
    private var pendingUploadFromFetch = false

    init(cachedState: ReadingState?, syncEnabled: Bool, lastSyncDate: Date?) {
        self.cachedState = cachedState
        self.syncEnabled = syncEnabled
        self.lastSyncDate = lastSyncDate
        self.phase = syncEnabled ? .starting : .disabled
        self.errorDescription = nil
    }

    func beginEngineStartIfNeeded() -> Bool {
        guard syncEnabled else {
            phase = .disabled
            errorDescription = nil
            return false
        }
        guard !engineStarted else { return false }
        engineStarted = true
        phase = .starting
        errorDescription = nil
        return true
    }

    func isSyncEnabled() -> Bool {
        syncEnabled
    }

    func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        ReadingStateSyncStorage.persistSyncEnabled(enabled)
        errorDescription = nil
        phase = enabled ? (engineStarted ? .idle : .starting) : .disabled
    }

    func updateLocalStateFromUser(_ state: ReadingState) -> Bool {
        cachedState = state
        ReadingStateSyncStorage.persistCachedState(state)
        errorDescription = nil
        if !syncEnabled {
            phase = .disabled
            return false
        }
        if engineStarted {
            phase = .idle
        }
        return true
    }

    func recordForPendingSave(recordID: CKRecord.ID) -> CKRecord? {
        guard recordID == ReadingState.recordID else { return nil }
        return cachedState?.makeRecord()
    }

    func beginFetchCycle() {
        guard syncEnabled else { return }
        sawRemoteStateDuringFetch = false
        pendingUploadFromFetch = false
        phase = .syncing
        errorDescription = nil
    }

    func reconcile(with remote: ReadingState) -> Bool {
        guard syncEnabled else { return false }
        sawRemoteStateDuringFetch = true

        let resolution = ReadingStateConflictResolver.resolve(local: cachedState, remote: remote)
        cachedState = resolution.resolvedState
        ReadingStateSyncStorage.persistCachedState(resolution.resolvedState)
        errorDescription = nil
        phase = .idle
        pendingUploadFromFetch = pendingUploadFromFetch || resolution.shouldUploadResolvedState

        if !resolution.shouldUploadResolvedState {
            lastSyncDate = Date()
            ReadingStateSyncStorage.persistLastSyncDate(lastSyncDate)
        }

        return resolution.shouldUploadResolvedState
    }

    func noteRemoteDeletion() -> Bool {
        guard syncEnabled else { return false }
        errorDescription = nil
        phase = .idle

        if cachedState == nil {
            lastSyncDate = Date()
            ReadingStateSyncStorage.persistLastSyncDate(lastSyncDate)
            return false
        }

        pendingUploadFromFetch = true
        return true
    }

    func completeFetchCycle() -> Bool {
        guard syncEnabled else { return false }
        phase = .idle
        errorDescription = nil

        let shouldUploadCachedState = (awaitingInitialFetch && !sawRemoteStateDuringFetch && cachedState != nil) || pendingUploadFromFetch
        awaitingInitialFetch = false
        pendingUploadFromFetch = false

        if !shouldUploadCachedState {
            lastSyncDate = Date()
            ReadingStateSyncStorage.persistLastSyncDate(lastSyncDate)
        }

        return shouldUploadCachedState
    }

    func noteSendSucceeded(savedRecords: [CKRecord]) {
        guard savedRecords.contains(where: { $0.recordID == ReadingState.recordID }) else { return }
        lastSyncDate = Date()
        ReadingStateSyncStorage.persistLastSyncDate(lastSyncDate)
        phase = .idle
        errorDescription = nil
    }

    func noteError(_ error: Error) {
        errorDescription = error.localizedDescription
        phase = Self.phase(for: error)
    }

    func noteAccountUnavailable() -> ReadingSyncSnapshot {
        cachedState = nil
        ReadingStateSyncStorage.persistCachedState(nil)
        ReadingStateSyncStorage.persistLastSyncDate(nil)
        ReadingStateSyncStorage.clearStateSerialization()
        lastSyncDate = nil
        errorDescription = nil
        phase = .accountUnavailable
        awaitingInitialFetch = true
        sawRemoteStateDuringFetch = false
        engineStarted = false
        return snapshot(clearsLocalCache: true)
    }

    func snapshot(clearsLocalCache: Bool = false) -> ReadingSyncSnapshot {
        ReadingSyncSnapshot(
            state: cachedState,
            phase: phase,
            lastSyncDate: lastSyncDate,
            errorDescription: errorDescription,
            isSyncEnabled: syncEnabled,
            clearsLocalCache: clearsLocalCache
        )
    }

    private static func phase(for error: Error) -> ReadingSyncPhase {
        guard let ckError = error as? CKError else {
            return .error
        }

        switch ckError.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .waitingForNetwork
        case .notAuthenticated, .accountTemporarilyUnavailable, .permissionFailure, .badContainer, .missingEntitlement:
            return .accountUnavailable
        default:
            return .error
        }
    }
}

/// CKSyncEngine is Apple's higher-level custom CloudKit sync API and handles
/// subscriptions, scheduling, and state tracking for this private reading-state zone.
final class ReadingStateSyncService: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    static let shared = ReadingStateSyncService()

    private static let containerIdentifier = "iCloud.OG.RussianOrthodoxReader"
    private static let subscriptionID = "reading-state-sync"
    private static let writeDebounceNanoseconds: UInt64 = 2_000_000_000

    private let container = CKContainer(identifier: containerIdentifier)
    private let debouncer = ReadingSyncDebouncer()
    private let engineCallScheduler = ReadingSyncEngineCallScheduler()
    private let store = ReadingStateSyncStore(
        cachedState: ReadingStateSyncStorage.loadCachedState(),
        syncEnabled: ReadingStateSyncStorage.loadSyncEnabled(),
        lastSyncDate: ReadingStateSyncStorage.loadLastSyncDate()
    )

    @MainActor private var snapshotHandler: ((ReadingSyncSnapshot) -> Void)?

    private lazy var syncEngine: CKSyncEngine = {
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: ReadingStateSyncStorage.loadStateSerialization(),
            delegate: self
        )
        configuration.automaticallySync = true
        configuration.subscriptionID = Self.subscriptionID
        return CKSyncEngine(configuration)
    }()

    private override init() {
        super.init()
    }

    @MainActor
    func setSnapshotHandler(_ handler: ((ReadingSyncSnapshot) -> Void)?) {
        snapshotHandler = handler
    }

    func start() async {
        let shouldStart = await store.beginEngineStartIfNeeded()
        await publishSnapshot()

        guard shouldStart else { return }

        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: ReadingState.zoneID))])

        do {
            try await syncEngine.sendChanges()
            try await syncEngine.fetchChanges()
        } catch {
            await handleSyncError(error)
        }
    }

    private func scheduleEngineCall(_ call: ReadingSyncEngineCall) async {
        guard await engineCallScheduler.enqueue(call) else { return }

        Task.detached { [weak self] in
            await Task.yield()
            await self?.drainScheduledEngineCalls()
        }
    }

    private func drainScheduledEngineCalls() async {
        while let call = await engineCallScheduler.nextCall() {
            switch call {
            case .send:
                await flushPendingChanges()
            case .fetch:
                await refreshNow()
            }
        }
    }

    func setSyncEnabled(_ enabled: Bool) async {
        await store.setSyncEnabled(enabled)
        if !enabled {
            await debouncer.cancel()
            await publishSnapshot()
            return
        }

        await start()
        await refreshNow()
    }

    func refreshNow() async {
        guard await store.isSyncEnabled() else {
            await publishSnapshot()
            return
        }

        _ = await store.beginEngineStartIfNeeded()
        await store.beginFetchCycle()
        await publishSnapshot()

        do {
            try await syncEngine.fetchChanges()
        } catch {
            await handleSyncError(error)
        }
    }

    func updateLocalRoute(_ route: ReaderRoute) async {
        guard let state = ReadingState(route: route, lastModified: Date()) else { return }

        let shouldSync = await store.updateLocalStateFromUser(state)
        await publishSnapshot()

        guard shouldSync else { return }

        _ = await store.beginEngineStartIfNeeded()
        await debouncer.schedule(delayNanoseconds: Self.writeDebounceNanoseconds) { [weak self] in
            await self?.flushPendingChanges()
        }
    }

    private func flushPendingChanges() async {
        guard await store.isSyncEnabled() else { return }

        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: ReadingState.zoneID))])
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(ReadingState.recordID)])
        await publishSnapshot()

        do {
            try await syncEngine.sendChanges()
        } catch {
            await handleSyncError(error)
        }
    }

    private func publishSnapshot(_ snapshot: ReadingSyncSnapshot? = nil) async {
        let value: ReadingSyncSnapshot
        if let snapshot {
            value = snapshot
        } else {
            value = await store.snapshot()
        }
        await MainActor.run {
            snapshotHandler?(value)
        }
    }

    private func handleSyncError(_ error: Error) async {
        Logger(subsystem: "OG.RussianOrthodoxReader", category: "ReadingSync")
            .error("Reading sync failed: \(error.localizedDescription, privacy: .public)")
        await store.noteError(error)
        await publishSnapshot()
    }

    private func handleRemoteRecordConflict(_ error: CKError) async {
        guard let serverRecord = error.serverRecord,
              let remoteState = ReadingState(record: serverRecord) else {
            await store.noteError(error)
            await publishSnapshot()
            return
        }

        let shouldUploadResolvedState = await store.reconcile(with: remoteState)
        await publishSnapshot()

        if shouldUploadResolvedState {
            await scheduleEngineCall(.send)
        }
    }

    private func handleAccountChange(_ changeType: CKSyncEngine.Event.AccountChange.ChangeType) async {
        switch changeType {
        case .signIn:
            await publishSnapshot()
            await scheduleEngineCall(.fetch)
        case .signOut, .switchAccounts:
            await debouncer.cancel()
            let snapshot = await store.noteAccountUnavailable()
            await publishSnapshot(snapshot)
        @unknown default:
            await publishSnapshot()
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            ReadingStateSyncStorage.persistStateSerialization(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            await handleAccountChange(accountChange.changeType)
            return

        case .willFetchChanges:
            await store.beginFetchCycle()

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                guard modification.record.recordID == ReadingState.recordID,
                      let remoteState = ReadingState(record: modification.record) else { continue }

                let shouldUploadResolvedState = await store.reconcile(with: remoteState)
                await publishSnapshot()

                if shouldUploadResolvedState {
                    await scheduleEngineCall(.send)
                }
            }

            for deletion in changes.deletions where deletion.recordID == ReadingState.recordID {
                let shouldUploadCachedState = await store.noteRemoteDeletion()
                await publishSnapshot()

                if shouldUploadCachedState {
                    await scheduleEngineCall(.send)
                }
            }
            return

        case .didFetchChanges:
            let shouldUploadCachedState = await store.completeFetchCycle()
            await publishSnapshot()

            if shouldUploadCachedState {
                await scheduleEngineCall(.send)
            }
            return

        case .sentRecordZoneChanges(let changes):
            await store.noteSendSucceeded(savedRecords: changes.savedRecords)

            for failedSave in changes.failedRecordSaves where failedSave.record.recordID == ReadingState.recordID {
                if failedSave.error.code == .serverRecordChanged {
                    await handleRemoteRecordConflict(failedSave.error)
                    continue
                }

                if failedSave.error.code == .zoneNotFound || failedSave.error.code == .userDeletedZone {
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: ReadingState.zoneID))])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(ReadingState.recordID)])
                    continue
                }

                await store.noteError(failedSave.error)
            }

            for error in changes.failedRecordDeletes.values {
                await store.noteError(error)
            }

        case .sentDatabaseChanges(let changes):
            for failedZoneSave in changes.failedZoneSaves where failedZoneSave.zone.zoneID == ReadingState.zoneID {
                await store.noteError(failedZoneSave.error)
            }

            for (zoneID, error) in changes.failedZoneDeletes where zoneID == ReadingState.zoneID {
                await store.noteError(error)
            }

        case .didSendChanges, .didFetchRecordZoneChanges, .fetchedDatabaseChanges, .willFetchRecordZoneChanges, .willSendChanges:
            break
        @unknown default:
            break
        }

        await publishSnapshot()
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pendingChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { [store] recordID in
            await store.recordForPendingSave(recordID: recordID)
        }
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = CKSyncEngine.FetchChangesOptions()
        options.prioritizedZoneIDs = [ReadingState.zoneID]
        return options
    }
}
