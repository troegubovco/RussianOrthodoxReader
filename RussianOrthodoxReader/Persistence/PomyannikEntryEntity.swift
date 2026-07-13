import Foundation
import SwiftData

/// Запись помянника («О здравии» / «О упокоении»).
/// Синхронизируется вручную через CKSyncEngine (PrayersSyncService),
/// recordName = uuid.
@Model
final class PomyannikEntryEntity {
    @Attribute(.unique) var uuid: String
    var listRaw: String        // PomyannikList.rawValue: "health" | "repose"
    var inputName: String      // как ввёл пользователь: «Егор»
    var canonicalName: String  // церковная форма, именительный: «Георгий»
    var canonicalGen: String   // родительный: «Георгия»
    var canonicalAcc: String   // винительный: «Георгия»
    var genderRaw: String      // PersonGender.rawValue: "m" | "f"
    var status: String?        // «болящий», «новопреставленный» и т.п.
    var createdAt: Date
    var modifiedAt: Date       // ключ разрешения конфликтов (last-writer-wins)
    var sortOrder: Int

    init(uuid: String = UUID().uuidString,
         listRaw: String,
         inputName: String,
         canonicalName: String,
         canonicalGen: String,
         canonicalAcc: String,
         genderRaw: String,
         status: String? = nil,
         createdAt: Date = Date(),
         modifiedAt: Date = Date(),
         sortOrder: Int = 0) {
        self.uuid = uuid
        self.listRaw = listRaw
        self.inputName = inputName
        self.canonicalName = canonicalName
        self.canonicalGen = canonicalGen
        self.canonicalAcc = canonicalAcc
        self.genderRaw = genderRaw
        self.status = status
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sortOrder = sortOrder
    }

    var list: PomyannikList {
        get { PomyannikList(rawValue: listRaw) ?? .health }
        set { listRaw = newValue.rawValue }
    }

    var gender: PersonGender {
        get { PersonGender(rawValue: genderRaw) ?? .male }
        set { genderRaw = newValue.rawValue }
    }
}
