import CloudKit
import os.log

private let logger = Logger(subsystem: "OG.RussianOrthodoxReader", category: "CloudSync")

/// CloudKit-backed sync service. Stores a single "Settings" record in the user's
/// private database so data is synced across all of the user's devices.
///
/// All operations are serialized through an internal actor to prevent concurrent
/// writes that would cause CKError.serverRecordChanged ("oplock") errors.
final class CloudSyncService {
    static let shared = CloudSyncService()
    private init() {}

    private let container = CKContainer(identifier: "iCloud.OG.RussianOrthodoxReader")
    private var database: CKDatabase { container.privateCloudDatabase }
    private let recordID = CKRecord.ID(recordName: "user-settings")
    private let recordType = "Settings"

    /// Serial queue actor — guarantees at most one CloudKit operation at a time.
    private actor SerialQueue {
        private var inFlight = false
        private var pending: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if inFlight {
                await withCheckedContinuation { cont in
                    pending.append(cont)
                }
            }
            inFlight = true
        }

        func release() {
            if let next = pending.first {
                pending.removeFirst()
                next.resume()
            } else {
                inFlight = false
            }
        }
    }
    private let queue = SerialQueue()

    struct Settings {
        var lastReadingBookId: String?
        var lastReadingChapter: Int?
        var lastReadingUpdatedAt: Date?
        var prayerReadDate: String? // "yyyy-MM-dd"

        init(lastReadingBookId: String? = nil,
             lastReadingChapter: Int? = nil,
             lastReadingUpdatedAt: Date? = nil,
             prayerReadDate: String? = nil) {
            self.lastReadingBookId = lastReadingBookId
            self.lastReadingChapter = lastReadingChapter
            self.lastReadingUpdatedAt = lastReadingUpdatedAt
            self.prayerReadDate = prayerReadDate
        }
    }

    // MARK: - Load

    /// Fetches the Settings record from the user's private CloudKit database.
    /// Returns empty Settings if no record exists yet.
    func load() async throws -> Settings {
        await queue.acquire()
        do {
            let result = try await loadFromCloud()
            await queue.release()
            return result
        } catch {
            await queue.release()
            throw error
        }
    }

    private func loadFromCloud() async throws -> Settings {
        logger.info("CloudSync: loading settings from CloudKit…")
        do {
            let record = try await database.record(for: recordID)
            let settings = Settings(
                lastReadingBookId: record["lastReadingBookId"] as? String,
                lastReadingChapter: record["lastReadingChapter"] as? Int,
                lastReadingUpdatedAt: (record["lastReadingUpdatedAt"] as? Date) ?? record.modificationDate,
                prayerReadDate: record["prayerReadDate"] as? String
            )
            logger.info("CloudSync: loaded — book=\(settings.lastReadingBookId ?? "nil", privacy: .public), ch=\(settings.lastReadingChapter.map(String.init) ?? "nil", privacy: .public), updated=\(settings.lastReadingUpdatedAt?.description ?? "nil", privacy: .public), prayer=\(settings.prayerReadDate ?? "nil", privacy: .public)")
            return settings
        } catch let ckError as CKError where ckError.code == .unknownItem {
            logger.info("CloudSync: no record yet (unknownItem), returning empty settings")
            return Settings()
        } catch {
            logger.error("CloudSync: load failed — \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Save

    /// Upserts the Settings record. Only non-nil fields overwrite existing values.
    func save(_ settings: Settings) async throws {
        await queue.acquire()
        do {
            try await saveToCloud(settings)
            await queue.release()
        } catch {
            await queue.release()
            throw error
        }
    }

    private func saveToCloud(_ settings: Settings) async throws {
        logger.info("CloudSync: saving — book=\(settings.lastReadingBookId ?? "nil", privacy: .public), ch=\(settings.lastReadingChapter.map(String.init) ?? "nil", privacy: .public), updated=\(settings.lastReadingUpdatedAt?.description ?? "nil", privacy: .public), prayer=\(settings.prayerReadDate ?? "nil", privacy: .public)")
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
            logger.debug("CloudSync: fetched existing record for upsert")
        } catch let ckError as CKError where ckError.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: recordID)
            logger.info("CloudSync: creating new Settings record")
        } catch {
            logger.error("CloudSync: failed to fetch existing record — \(error.localizedDescription, privacy: .public)")
            throw error
        }

        if let bookId = settings.lastReadingBookId {
            record["lastReadingBookId"] = bookId as CKRecordValue
        }
        if let chapter = settings.lastReadingChapter {
            record["lastReadingChapter"] = chapter as CKRecordValue
        }
        if let updatedAt = settings.lastReadingUpdatedAt {
            record["lastReadingUpdatedAt"] = updatedAt as CKRecordValue
        }
        if let prayerDate = settings.prayerReadDate {
            record["prayerReadDate"] = prayerDate as CKRecordValue
        }

        do {
            _ = try await database.save(record)
            logger.info("CloudSync: save succeeded")
        } catch {
            logger.error("CloudSync: save failed — \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
