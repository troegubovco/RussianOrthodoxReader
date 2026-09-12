import Foundation
import SwiftData

/// Активный (или архивный) план чтения — счётчик, не календарная сетка
/// (§4.1 akathist_psalter_design.md). Единицы прогресса лежат в отдельных
/// записях `ReadingPlanUnitEntity`, а не в массиве здесь — см. обоснование
/// там же и в §4.3: множество отметок на двух устройствах должно быть
/// grow-only set, а не LWW-полем.
/// Синхронизируется через PrayersSyncService, recordName = "plan-" + uuid.
@Model
final class ReadingPlanEntity {
    @Attribute(.unique) var uuid: String
    /// `ReadingPlanKind.rawKind`: "dailyPrayer" | "psalterKathisma" | "psalterSlava" | "greatCanon".
    var kindRaw: String
    /// slug молитвы — только для `dailyPrayer`.
    var subjectSlug: String?
    /// startOfDay дня создания плана.
    var startDate: Date
    var totalUnits: Int
    /// nil | "greatLent" | "apostles" | "dormition" | "nativity" — только для
    /// подписи кнопки («до конца …»); сама дата ниже, в `endDate`, и не
    /// пересчитывается при переходе через Новый год.
    var endDateRule: String?
    /// Материализована при создании плана — см. `endDateRule`.
    var endDate: Date?
    /// "HH:mm"; nil — без напоминания.
    var reminderTime: String?
    var isArchived: Bool
    var createdAt: Date
    var modifiedAt: Date   // ключ last-writer-wins

    init(uuid: String = UUID().uuidString,
         kindRaw: String,
         subjectSlug: String? = nil,
         startDate: Date,
         totalUnits: Int,
         endDateRule: String? = nil,
         endDate: Date? = nil,
         reminderTime: String? = nil,
         isArchived: Bool = false,
         createdAt: Date = Date(),
         modifiedAt: Date = Date()) {
        self.uuid = uuid
        self.kindRaw = kindRaw
        self.subjectSlug = subjectSlug
        self.startDate = startDate
        self.totalUnits = totalUnits
        self.endDateRule = endDateRule
        self.endDate = endDate
        self.reminderTime = reminderTime
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// `nil`, если `kindRaw`/`subjectSlug` повреждены или относятся к виду
    /// плана из будущей версии приложения — вызывающая сторона тогда
    /// пропускает запись, а не падает.
    var kind: ReadingPlanKind? {
        ReadingPlanKind.make(rawKind: kindRaw, subjectSlug: subjectSlug)
    }
}
