import Foundation
import SwiftData

/// Пункт пользовательского молитвенного правила («Моё правило»).
/// Синхронизируется через PrayersSyncService, recordName = "rule-" + prayerSlug.
@Model
final class MyRuleItemEntity {
    @Attribute(.unique) var prayerSlug: String
    var sortOrder: Int
    var createdAt: Date
    var modifiedAt: Date   // ключ last-writer-wins

    init(prayerSlug: String, sortOrder: Int,
         createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.prayerSlug = prayerSlug
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
