import Foundation
import SwiftData

@Model
final class ReadingReferenceEntity {
    var dateKey: String
    var kindRaw: String
    var sourceLabel: String = ""
    var displayRef: String
    var bookId: String
    var chapter: Int
    var verseStart: Int
    var verseEnd: Int
    var ordinal: Int

    init(dateKey: String,
         kindRaw: String,
         sourceLabel: String = "",
         displayRef: String,
         bookId: String,
         chapter: Int,
         verseStart: Int,
         verseEnd: Int,
         ordinal: Int) {
        self.dateKey = dateKey
        self.kindRaw = kindRaw
        self.sourceLabel = sourceLabel
        self.displayRef = displayRef
        self.bookId = bookId
        self.chapter = chapter
        self.verseStart = verseStart
        self.verseEnd = verseEnd
        self.ordinal = ordinal
    }
}
