import Foundation
import SwiftData

protocol LiturgicalRepositoryProtocol {
    func getDay(date: Date) async throws -> LiturgicalDay
    func prefetchWindow(centerDate: Date) async
}

enum LiturgicalRepositoryError: LocalizedError {
    case offlineNoCache(Date)
    case cacheCorrupted

    var errorDescription: String? {
        switch self {
        case let .offlineNoCache(date):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM yyyy"
            return "Данные за \(formatter.string(from: date)) не загружены оффлайн"
        case .cacheCorrupted:
            return "Ошибка локального кеша литургических данных"
        }
    }
}

@MainActor
final class LiturgicalRepository: LiturgicalRepositoryProtocol {
    static let shared = LiturgicalRepository()

    private let context: ModelContext
    private let backgroundContext: ModelContext
    private let apiClient: OrthocalAPIClient
    private let parser = ReadingReferenceParser()

    private init(
        context: ModelContext? = nil,
        apiClient: OrthocalAPIClient? = nil
    ) {
        self.context = context ?? PersistenceController.shared.container.mainContext
        self.backgroundContext = PersistenceController.shared.newBackgroundContext()
        self.apiClient = apiClient ?? OrthocalAPIClient()
    }

    func getDay(date: Date) async throws -> LiturgicalDay {
        if !FeatureFlags.useRealReadings {
            return fallbackDay(for: date, message: "Включен fallback режим чтений")
        }

        let dateKey = Self.dateKey(from: date)
        let cachedEntity = fetchDayEntity(for: dateKey)

        if let cachedEntity, !isStale(cachedEntity, for: date) {
            return mapEntityToDomain(cachedEntity, date: date, isFromCache: true, message: nil)
        }

        do {
            let dto = try await apiClient.fetchDay(date: date)
            let day = try upsert(dto: dto, for: date)
            return day
        } catch {
            if let cachedEntity {
                return mapEntityToDomain(cachedEntity, date: date, isFromCache: true, message: "Показаны последние сохраненные данные")
            }
            throw LiturgicalRepositoryError.offlineNoCache(date)
        }
    }

    func prefetchWindow(centerDate: Date) async {
        guard FeatureFlags.useRealReadings else { return }

        // Perform all heavy I/O on background context
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            
            let calendar = Calendar.current
            let start = calendar.date(byAdding: .day, value: -7, to: centerDate) ?? centerDate
            let end = calendar.date(byAdding: .day, value: 30, to: centerDate) ?? centerDate

            var day = start
            while day <= end {
                let dateKey = Self.dateKey(from: day)
                
                // Check cache on background thread
                let shouldRefresh: Bool = await self.shouldRefreshDay(dateKey: dateKey, date: day)

                if shouldRefresh {
                    do {
                        let dto = try await self.apiClient.fetchDay(date: day)
                        await self.upsertOnBackground(dto: dto, for: day)
                    } catch {
                        // Ignore transient prefetch failures.
                    }
                }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }

            // Purge old data on background thread
            await self.purgeOutsideWindowAsync(centerDate: centerDate)
        }.value
    }
    
    private func shouldRefreshDay(dateKey: String, date: Date) async -> Bool {
        let descriptor = FetchDescriptor<LiturgicalDayEntity>(
            predicate: #Predicate { $0.dateKey == dateKey }
        )
        
        guard let cached = try? backgroundContext.fetch(descriptor).first else {
            return true
        }
        
        let age = Date().timeIntervalSince(cached.fetchedAt)
        if Calendar.current.isDateInToday(date) {
            return age > 12 * 60 * 60
        }
        return age > 7 * 24 * 60 * 60
    }
    
    private func upsertOnBackground(dto: OrthocalDayDTO, for date: Date) async {
        let dateKey = Self.dateKey(from: date)
        
        // Perform the entire upsert on background context
        let descriptor = FetchDescriptor<LiturgicalDayEntity>(
            predicate: #Predicate { $0.dateKey == dateKey }
        )
        
        let existing = try? backgroundContext.fetch(descriptor).first
        let dayEntity: LiturgicalDayEntity
        if let existing {
            dayEntity = existing
        } else {
            dayEntity = LiturgicalDayEntity(
                dateKey: dateKey,
                saintOfDay: "",
                tone: nil,
                fastingLevelRaw: LiturgicalDay.FastingLevel.none.rawValue,
                apostolRefRaw: "—",
                gospelRefRaw: "—",
                fetchedAt: Date(),
                sourceVersion: "orthocal.v1"
            )
            backgroundContext.insert(dayEntity)
        }
        
        let saintOfDayRaw = dto.saints.first ?? dto.summaryTitle ?? "Память не указана"
        let saintOfDay = localizeSaintName(saintOfDayRaw)
        
        var ordinal = 0
        var parsedReferences: [ReadingReference] = []
        var apostolRefRaw = "—"
        var gospelRefRaw = "—"

        for reading in dto.readings {
            let kind = classify(kindSource: reading.source, description: reading.description, display: reading.display)
            let display = normalizedDisplay(for: reading)

            let resolved = resolveReferences(from: reading, kind: kind, sourceLabel: reading.source ?? "", fallbackDisplay: display, ordinalStart: ordinal)
            parsedReferences.append(contentsOf: resolved)
            ordinal += resolved.count

            if kind == .apostol && apostolRefRaw == "—" {
                apostolRefRaw = makeSummaryLabel(from: resolved, fallback: display)
            }
            if kind == .gospel && gospelRefRaw == "—" {
                gospelRefRaw = makeSummaryLabel(from: resolved, fallback: display)
            }
        }

        dayEntity.saintOfDay = saintOfDay
        dayEntity.tone = dto.tone
        dayEntity.fastingLevelRaw = mapFastingLevel(dto.fastingDescription, dto.fastingException).rawValue
        dayEntity.apostolRefRaw = apostolRefRaw
        dayEntity.gospelRefRaw = gospelRefRaw
        dayEntity.fetchedAt = Date()
        dayEntity.sourceVersion = "orthocal.v1"

        // Persist ReadingReferenceEntity objects (same as upsert on main context)
        let refDescriptor = FetchDescriptor<ReadingReferenceEntity>(
            predicate: #Predicate<ReadingReferenceEntity> { ref in ref.dateKey == dateKey }
        )
        if let oldRefs = try? backgroundContext.fetch(refDescriptor) {
            oldRefs.forEach { backgroundContext.delete($0) }
        }
        for ref in parsedReferences {
            backgroundContext.insert(
                ReadingReferenceEntity(
                    dateKey: dateKey,
                    kindRaw: ref.kind.rawValue,
                    sourceLabel: ref.sourceLabel,
                    displayRef: ref.displayRef,
                    bookId: ref.bookId,
                    chapter: ref.chapter,
                    verseStart: ref.verseStart,
                    verseEnd: ref.verseEnd,
                    ordinal: ref.ordinal
                )
            )
        }

        try? backgroundContext.save()
    }

    private func upsert(dto: OrthocalDayDTO, for date: Date) throws -> LiturgicalDay {
        let dateKey = Self.dateKey(from: date)

        let existing = fetchDayEntity(for: dateKey)
        let dayEntity: LiturgicalDayEntity
        if let existing {
            dayEntity = existing
        } else {
            dayEntity = LiturgicalDayEntity(
                dateKey: dateKey,
                saintOfDay: "",
                tone: nil,
                fastingLevelRaw: LiturgicalDay.FastingLevel.none.rawValue,
                apostolRefRaw: "—",
                gospelRefRaw: "—",
                fetchedAt: Date(),
                sourceVersion: "orthocal.v1"
            )
            context.insert(dayEntity)
        }

        let saintOfDayRaw = dto.saints.first ?? dto.summaryTitle ?? "Память не указана"
        let saintOfDay = localizeSaintName(saintOfDayRaw)

        var ordinal = 0
        var parsedReferences: [ReadingReference] = []
        var apostolRefRaw = "—"
        var gospelRefRaw = "—"

        for reading in dto.readings {
            let kind = classify(kindSource: reading.source, description: reading.description, display: reading.display)
            let display = normalizedDisplay(for: reading)

            let resolved = resolveReferences(from: reading, kind: kind, sourceLabel: reading.source ?? "", fallbackDisplay: display, ordinalStart: ordinal)
            parsedReferences.append(contentsOf: resolved)
            ordinal += resolved.count

            if kind == .apostol && apostolRefRaw == "—" {
                apostolRefRaw = makeSummaryLabel(from: resolved, fallback: display)
            }
            if kind == .gospel && gospelRefRaw == "—" {
                gospelRefRaw = makeSummaryLabel(from: resolved, fallback: display)
            }
        }

        dayEntity.saintOfDay = saintOfDay
        dayEntity.tone = dto.tone
        dayEntity.fastingLevelRaw = mapFastingLevel(dto.fastingDescription, dto.fastingException).rawValue
        dayEntity.apostolRefRaw = apostolRefRaw
        dayEntity.gospelRefRaw = gospelRefRaw
        dayEntity.fetchedAt = Date()
        dayEntity.sourceVersion = "orthocal.v1"

        try deleteReferenceEntities(for: dateKey)
        for ref in parsedReferences {
            context.insert(
                ReadingReferenceEntity(
                    dateKey: dateKey,
                    kindRaw: ref.kind.rawValue,
                    sourceLabel: ref.sourceLabel,
                    displayRef: ref.displayRef,
                    bookId: ref.bookId,
                    chapter: ref.chapter,
                    verseStart: ref.verseStart,
                    verseEnd: ref.verseEnd,
                    ordinal: ref.ordinal
                )
            )
        }

        if context.hasChanges {
            try context.save()
        }

        return mapEntityToDomain(dayEntity, date: date, isFromCache: false, message: nil)
    }

    private func resolveReferences(from reading: OrthocalReadingDTO,
                                   kind: ReadingKind,
                                   sourceLabel: String,
                                   fallbackDisplay: String,
                                   ordinalStart: Int) -> [ReadingReference] {
        var results: [ReadingReference] = []

        if !reading.passage.isEmpty {
            let grouped = groupPassage(verses: reading.passage)
            var ordinal = ordinalStart
            for group in grouped {
                results.append(
                    ReadingReference(
                        kind: kind,
                        sourceLabel: sourceLabel,
                        displayRef: localizeReferenceDisplay(
                            bookId: group.bookId,
                            chapter: group.chapter,
                            verseStart: group.start,
                            verseEnd: group.end,
                            fallback: fallbackDisplay
                        ),
                        bookId: group.bookId,
                        chapter: group.chapter,
                        verseStart: group.start,
                        verseEnd: group.end,
                        ordinal: ordinal
                    )
                )
                ordinal += 1
            }
            if !results.isEmpty {
                return results
            }
        }

        if !fallbackDisplay.isEmpty {
            let parsed = parser.parse(raw: fallbackDisplay, kind: kind, sourceLabel: sourceLabel, ordinalStart: ordinalStart)
            return parsed.map { ref in
                ReadingReference(
                    kind: ref.kind,
                    sourceLabel: ref.sourceLabel,
                    displayRef: localizeReferenceDisplay(
                        bookId: ref.bookId,
                        chapter: ref.chapter,
                        verseStart: ref.verseStart,
                        verseEnd: ref.verseEnd,
                        fallback: ref.displayRef
                    ),
                    bookId: ref.bookId,
                    chapter: ref.chapter,
                    verseStart: ref.verseStart,
                    verseEnd: ref.verseEnd,
                    ordinal: ref.ordinal
                )
            }
        }

        return []
    }

    private func groupPassage(verses: [OrthocalVerseDTO]) -> [(bookId: String, chapter: Int, start: Int, end: Int)] {
        let sorted = verses.sorted {
            if $0.book == $1.book, $0.chapter == $1.chapter {
                return $0.verse < $1.verse
            }
            if $0.book == $1.book {
                return $0.chapter < $1.chapter
            }
            return $0.book < $1.book
        }

        var groups: [(bookId: String, chapter: Int, start: Int, end: Int)] = []

        for verse in sorted {
            guard let bookId = BookAliasMapper.bookId(for: verse.book) else {
                // Skip non-Bible books like "Composite" or empty strings without logging
                if verse.book != "Composite" && !verse.book.isEmpty {
                    #if DEBUG
                    print("[LiturgicalRepository] unknown book alias in passage: \(verse.book)")
                    #endif
                }
                continue
            }

            if var last = groups.last,
               last.bookId == bookId,
               last.chapter == verse.chapter,
               verse.verse == last.end + 1 {
                last.end = verse.verse
                groups[groups.count - 1] = last
            } else {
                groups.append((bookId: bookId, chapter: verse.chapter, start: verse.verse, end: verse.verse))
            }
        }

        return groups
    }

    private func classify(kindSource: String?, description: String?, display: String?) -> ReadingKind {
        let value = [kindSource, description, display]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if value.contains("gospel") || value.contains("еванг") {
            return .gospel
        }
        if value.contains("apost") || value.contains("epistle") || value.contains("апост") {
            return .apostol
        }
        return .other
    }

    private func normalizedDisplay(for reading: OrthocalReadingDTO) -> String {
        if let value = reading.display?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return sanitizeDisplay(value)
        }
        if let value = reading.shortDisplay?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return sanitizeDisplay(value)
        }
        if let value = reading.description?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return sanitizeDisplay(value)
        }
        if let value = reading.book?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return sanitizeDisplay(value)
        }
        return "Чтение"
    }

    private func sanitizeDisplay(_ value: String) -> String {
        var normalized = value.replacingOccurrences(of: "_", with: "")
        while normalized.contains("  ") {
            normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeSummaryLabel(from refs: [ReadingReference], fallback: String) -> String {
        var seen: Set<String> = []
        var ordered: [String] = []
        for ref in refs {
            guard !seen.contains(ref.displayRef) else { continue }
            seen.insert(ref.displayRef)
            ordered.append(ref.displayRef)
        }
        if !ordered.isEmpty {
            return ordered.joined(separator: "; ")
        }
        return localizeFreeFormReference(fallback)
    }

    private func localizeReferenceDisplay(bookId: String,
                                          chapter: Int,
                                          verseStart: Int,
                                          verseEnd: Int,
                                          fallback: String) -> String {
        guard chapter > 0, verseStart > 0, verseEnd > 0 else {
            return localizeFreeFormReference(fallback)
        }

        let bookLabel = BibleDataProvider.book(id: bookId)?.abbreviation ?? bookId.uppercased()
        if verseStart == verseEnd {
            return "\(bookLabel) \(chapter):\(verseStart)"
        }
        return "\(bookLabel) \(chapter):\(verseStart)-\(verseEnd)"
    }

    private func localizeFreeFormReference(_ raw: String) -> String {
        let cleaned = sanitizeDisplay(raw)
        guard !cleaned.isEmpty else { return "Чтение" }

        let segments = cleaned
            .split(separator: ";")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if segments.isEmpty {
            return cleaned
        }

        let localizedSegments = segments.map { segment in
            let parsed = parser.parse(raw: segment, kind: .other, sourceLabel: "", ordinalStart: 0)
            guard !parsed.isEmpty else {
                return segment
            }

            var seen: Set<String> = []
            var ordered: [String] = []
            for ref in parsed {
                let localized = localizeReferenceDisplay(
                    bookId: ref.bookId,
                    chapter: ref.chapter,
                    verseStart: ref.verseStart,
                    verseEnd: ref.verseEnd,
                    fallback: segment
                )
                guard !seen.contains(localized) else { continue }
                seen.insert(localized)
                ordered.append(localized)
            }
            return ordered.isEmpty ? segment : ordered.joined(separator: ", ")
        }

        let result = localizedSegments.joined(separator: "; ")
        return result.isEmpty ? cleaned : result
    }

    private func localizeSaintName(_ raw: String) -> String {
        var text = sanitizeDisplay(raw)
        if text.isEmpty { return "Память не указана" }
        if containsCyrillic(text) { return text }

        text = replaceCaseInsensitive("our holy father", with: "Прп.", in: text)
        text = replaceCaseInsensitive("holy father", with: "Прп.", in: text)
        text = replaceCaseInsensitive("our venerable father", with: "Прп.", in: text)
        text = replaceCaseInsensitive("venerable", with: "Прп.", in: text)
        text = replaceCaseInsensitive("great martyr", with: "Вмч.", in: text)
        text = replaceCaseInsensitive("hieromartyr", with: "Сщмч.", in: text)
        text = replaceCaseInsensitive("martyr", with: "Мч.", in: text)
        text = replaceCaseInsensitive("bishop of", with: "епископ", in: text)
        text = replaceCaseInsensitive("archbishop of", with: "архиепископ", in: text)
        text = replaceCaseInsensitive("patriarch", with: "патриарх", in: text)
        text = replaceCaseInsensitive(" of ", with: " ", in: text)
        text = replaceCaseInsensitive("st. ", with: "Св.", in: text)
        text = replaceCaseInsensitive("st ", with: "Св. ", in: text)

        text = text.replacingOccurrences(
            of: #"(\d+)(st|nd|rd|th)\s*c\."#,
            with: "$1 в.",
            options: .regularExpression
        )

        if containsLatin(text),
           let transformed = text.applyingTransform(StringTransform(rawValue: "Latin-Cyrillic"), reverse: false) {
            text = transformed
        }

        if containsLatin(text) {
            text = manualLatinToCyrillic(text)
        }

        return sanitizeDisplay(text)
    }

    private func replaceCaseInsensitive(_ target: String, with replacement: String, in value: String) -> String {
        value.replacingOccurrences(of: target, with: replacement, options: [.caseInsensitive, .diacriticInsensitive], range: nil)
    }

    private func containsLatin(_ value: String) -> Bool {
        value.range(of: "[A-Za-z]", options: .regularExpression) != nil
    }

    private func containsCyrillic(_ value: String) -> Bool {
        value.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil
    }

    private func manualLatinToCyrillic(_ value: String) -> String {
        let pairs: [(String, String)] = [
            ("sch", "щ"), ("sh", "ш"), ("ch", "ч"), ("ya", "я"), ("yu", "ю"), ("yo", "ё"), ("zh", "ж"),
            ("a", "а"), ("b", "б"), ("c", "к"), ("d", "д"), ("e", "е"), ("f", "ф"), ("g", "г"), ("h", "х"),
            ("i", "и"), ("j", "й"), ("k", "к"), ("l", "л"), ("m", "м"), ("n", "н"), ("o", "о"), ("p", "п"),
            ("q", "к"), ("r", "р"), ("s", "с"), ("t", "т"), ("u", "у"), ("v", "в"), ("w", "в"), ("x", "кс"),
            ("y", "ы"), ("z", "з")
        ]

        var result = value.lowercased()
        for (latin, cyrillic) in pairs {
            result = result.replacingOccurrences(of: latin, with: cyrillic)
        }

        if let first = result.first {
            let head = String(first).uppercased()
            result = head + result.dropFirst()
        }
        return result
    }

    private func mapFastingLevel(_ description: String?, _ exception: String?) -> LiturgicalDay.FastingLevel {
        let joined = [description, exception].compactMap { $0?.lowercased() }.joined(separator: " ")
        if joined.isEmpty {
            return .none
        }
        if joined.contains("strict") || joined.contains("great lent") {
            return .strict
        }
        if joined.contains("fish") {
            return .fish
        }
        if joined.contains("oil") {
            return .oil
        }
        if joined.contains("fast") {
            return .regular
        }
        return .none
    }

    private func isStale(_ entity: LiturgicalDayEntity, for date: Date) -> Bool {
        let age = Date().timeIntervalSince(entity.fetchedAt)
        if Calendar.current.isDateInToday(date) {
            return age > 12 * 60 * 60
        }
        return age > 7 * 24 * 60 * 60
    }

    private func purgeOutsideWindow(centerDate: Date) {
        // Keep synchronous version for backward compatibility, but run on background
        Task.detached(priority: .utility) { [weak self] in
            await self?.purgeOutsideWindowAsync(centerDate: centerDate)
        }
    }
    
    private func purgeOutsideWindowAsync(centerDate: Date) async {
        let calendar = Calendar.current
        let lowerBound = calendar.date(byAdding: .day, value: -7, to: centerDate) ?? centerDate
        let upperBound = calendar.date(byAdding: .day, value: 30, to: centerDate) ?? centerDate

        let descriptor = FetchDescriptor<LiturgicalDayEntity>()
        guard let allDays = try? backgroundContext.fetch(descriptor) else { return }

        for entity in allDays {
            let dateKey = entity.dateKey
            guard let entityDate = Self.date(fromKey: dateKey) else {
                backgroundContext.delete(entity)
                continue
            }
            if entityDate < lowerBound || entityDate > upperBound {
                // Delete associated references
                let refDescriptor = FetchDescriptor<ReadingReferenceEntity>(
                    predicate: #Predicate<ReadingReferenceEntity> { ref in ref.dateKey == dateKey }
                )
                if let refs = try? backgroundContext.fetch(refDescriptor) {
                    refs.forEach { backgroundContext.delete($0) }
                }
                backgroundContext.delete(entity)
            }
        }

        if backgroundContext.hasChanges {
            try? backgroundContext.save()
        }
    }

    private func fetchDayEntity(for dateKey: String) -> LiturgicalDayEntity? {
        let descriptor = FetchDescriptor<LiturgicalDayEntity>(
            predicate: #Predicate { $0.dateKey == dateKey }
        )
        return try? context.fetch(descriptor).first
    }

    private func fetchReferenceEntities(for dateKey: String) throws -> [ReadingReferenceEntity] {
        let descriptor = FetchDescriptor<ReadingReferenceEntity>(
            predicate: #Predicate { $0.dateKey == dateKey },
            sortBy: [SortDescriptor(\.ordinal)]
        )
        return try context.fetch(descriptor)
    }

    private func deleteReferenceEntities(for dateKey: String) throws {
        let items = try fetchReferenceEntities(for: dateKey)
        items.forEach { context.delete($0) }
    }

    private func mapEntityToDomain(_ entity: LiturgicalDayEntity,
                                   date: Date,
                                   isFromCache: Bool,
                                   message: String?) -> LiturgicalDay {
        let refs: [ReadingReference] = (try? fetchReferenceEntities(for: entity.dateKey))?.compactMap { ref in
            guard let kind = ReadingKind(rawValue: ref.kindRaw) else { return nil }
            return ReadingReference(
                kind: kind,
                sourceLabel: ref.sourceLabel,
                displayRef: localizeReferenceDisplay(
                    bookId: ref.bookId,
                    chapter: ref.chapter,
                    verseStart: ref.verseStart,
                    verseEnd: ref.verseEnd,
                    fallback: ref.displayRef
                ),
                bookId: ref.bookId,
                chapter: ref.chapter,
                verseStart: ref.verseStart,
                verseEnd: ref.verseEnd,
                ordinal: ref.ordinal
            )
        } ?? []

        let level = LiturgicalDay.FastingLevel(rawValue: entity.fastingLevelRaw) ?? LiturgicalCalendar.fallbackFastingLevel(for: date)
        let isFastDay = level != .none

        return LiturgicalDay(
            id: date,
            date: date,
            apostolReading: localizeFreeFormReference(entity.apostolRefRaw),
            gospelReading: localizeFreeFormReference(entity.gospelRefRaw),
            saintOfDay: localizeSaintName(entity.saintOfDay),
            tone: entity.tone,
            isSunday: LiturgicalCalendar.isSunday(date),
            isFastDay: isFastDay,
            fastingLevel: level,
            references: refs,
            isFromCache: isFromCache,
            dataAvailabilityMessage: message
        )
    }

    private func fallbackDay(for date: Date, message: String) -> LiturgicalDay {
        let level = LiturgicalCalendar.fallbackFastingLevel(for: date)
        return LiturgicalDay(
            id: date,
            date: date,
            apostolReading: "—",
            gospelReading: "—",
            saintOfDay: "Источник чтений отключен",
            tone: nil,
            isSunday: LiturgicalCalendar.isSunday(date),
            isFastDay: level != .none,
            fastingLevel: level,
            references: [],
            isFromCache: true,
            dataAvailabilityMessage: message
        )
    }

    nonisolated static func dateKey(from date: Date) -> String {
        dateFormatter.string(from: date)
    }

    nonisolated static func date(fromKey key: String) -> Date? {
        dateFormatter.date(from: key)
    }

    private nonisolated static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
