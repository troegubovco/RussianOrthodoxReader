import Foundation
import SwiftData

/// Одна отметка «прочитано» внутри плана — отдельная запись, а не элемент
/// массива в `ReadingPlanEntity` (см. обоснование там же и в §4.3
/// akathist_psalter_design.md): grow-only set из отметок переживает
/// параллельные правки с двух устройств, LWW над массивом — нет.
/// Синхронизируется через PrayersSyncService,
/// recordName = "planunit-<planUUID>-<unitIndex>" (хранится в `recordName`
/// целиком, не собирается из префикса при синке — в отличие от `ReadingPlanEntity.uuid`).
@Model
final class ReadingPlanUnitEntity {
    @Attribute(.unique) var recordName: String
    var planUUID: String
    var unitIndex: Int
    /// startOfDay местного календаря устройства в момент отметки. Для
    /// дедупликации между телефоном и часами сравнивать через
    /// `ISO8601DayFormatter.string(from:)`, а не этот `Date` напрямую —
    /// расхождение часовых поясов иначе даёт ложное «другой день» (§8.7).
    var completedOn: Date
    var createdAt: Date
    var modifiedAt: Date

    init(recordName: String,
         planUUID: String,
         unitIndex: Int,
         completedOn: Date,
         createdAt: Date = Date(),
         modifiedAt: Date = Date()) {
        self.recordName = recordName
        self.planUUID = planUUID
        self.unitIndex = unitIndex
        self.completedOn = completedOn
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    static func recordName(planUUID: String, unitIndex: Int) -> String {
        "planunit-\(planUUID)-\(unitIndex)"
    }
}
