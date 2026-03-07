import Foundation
import SwiftData

@Model
final class LiturgicalDayEntity {
    @Attribute(.unique) var dateKey: String
    var saintOfDay: String
    var tone: Int?
    var fastingLevelRaw: String
    var apostolRefRaw: String
    var gospelRefRaw: String
    var fetchedAt: Date
    var sourceVersion: String

    init(dateKey: String,
         saintOfDay: String,
         tone: Int?,
         fastingLevelRaw: String,
         apostolRefRaw: String,
         gospelRefRaw: String,
         fetchedAt: Date,
         sourceVersion: String) {
        self.dateKey = dateKey
        self.saintOfDay = saintOfDay
        self.tone = tone
        self.fastingLevelRaw = fastingLevelRaw
        self.apostolRefRaw = apostolRefRaw
        self.gospelRefRaw = gospelRefRaw
        self.fetchedAt = fetchedAt
        self.sourceVersion = sourceVersion
    }
}
