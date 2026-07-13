import Foundation
import SwiftData

/// Закладка на молитву. Ссылается на стабильный slug из prayers.sqlite.
/// Синхронизируется вручную через CKSyncEngine (PrayersSyncService),
/// recordName = "bm-" + prayerSlug.
@Model
final class PrayerBookmarkEntity {
    @Attribute(.unique) var prayerSlug: String
    var createdAt: Date
    var modifiedAt: Date   // ключ разрешения конфликтов (last-writer-wins)

    init(prayerSlug: String, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.prayerSlug = prayerSlug
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
