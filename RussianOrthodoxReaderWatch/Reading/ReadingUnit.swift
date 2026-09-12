//
//  ReadingUnit.swift
//  RussianOrthodoxReaderWatch
//
//  Разбивка длинных последований на фрагменты, которые показываются на часах
//  по одному за раз (см. ReaderScreen). Чистый Foundation, без SwiftUI —
//  фрагменты описывают только текст и структуру, не оформление.
//

import Foundation

/// Один абзац текста молитвы (после разбиения по "\n\n") и порция экрана чтения.
struct Fragment: Identifiable, Hashable {
    struct Paragraph: Hashable {
        let text: String
        let isRubric: Bool
    }

    let id: Int
    let prayerSlug: String
    let prayerTitle: String
    let prayerSubtitle: String?
    /// Заголовок молитвы; текст указания-якоря (для последований с ≥4 указаниями,
    /// напр. канонов); либо «Часть N».
    let label: String
    /// Первый фрагмент молитвы — на нём показывается заголовок молитвы.
    let showsTitle: Bool
    let paragraphs: [Paragraph]
    /// Индекс молитвы внутри последования — для группировки в «Содержании».
    let prayerIndex: Int
}

enum ReadingUnit {

    /// Абзац длиннее этого считается собственным фрагментом; иначе абзацы
    /// накапливаются в один фрагмент, пока не будет превышен этот предел.
    static let maxFragmentChars = 1800
    /// От скольких указаний в молитве переключаемся на разбиение по указаниям
    /// вместо разбиения по длине (см. group(paragraphs:)).
    static let rubricAnchorThreshold = 4

    // MARK: - Публичное API

    /// Молитвы единицы чтения в порядке следования.
    static func loadPrayers(for ref: ReadingUnitRef) -> [Prayer] {
        switch ref.kind {
        case .sequence(let categorySlug, _):
            let feminine = UserDefaults.standard.bool(forKey: PrayersRepository.feminineFormsKey)
            return PrayersRepository.shared.fullPrayers(inCategory: categorySlug, feminine: feminine)
        case .prayer(let slug):
            if let prayer = PrayersRepository.shared.prayer(slug: slug) { return [prayer] }
            return []
        case .list(_, let slugs):
            return PrayersRepository.shared.prayers(slugs: slugs)
        case .rule(let slugs):
            return PrayersRepository.shared.prayers(slugs: slugs)
        }
    }

    static func build(ref: ReadingUnitRef,
                       language: PrayerLanguage,
                       showStress: Bool,
                       names: (PomyannikList) -> [WatchSnapshot.Entry]) -> [Fragment] {
        build(prayers: loadPrayers(for: ref), language: language, showStress: showStress, names: names)
    }

    /// Перегрузка для случаев, когда молитвы уже загружены (например, экран
    /// чтения перестраивает фрагменты при смене языка/ударений без похода в БД).
    static func build(prayers: [Prayer],
                       language: PrayerLanguage,
                       showStress: Bool,
                       names: (PomyannikList) -> [WatchSnapshot.Entry]) -> [Fragment] {
        var fragments: [Fragment] = []
        for (prayerIndex, prayer) in prayers.enumerated() {
            let paragraphs = paragraphs(for: prayer, language: language, showStress: showStress, names: names)
            let groups = group(paragraphs: paragraphs)
            for (partIndex, group) in groups.enumerated() {
                let label: String
                if partIndex == 0 {
                    label = prayer.title
                } else if let anchor = group.anchorRubricText {
                    label = anchor
                } else {
                    label = "Часть \(partIndex + 1)"
                }
                fragments.append(Fragment(
                    id: fragments.count,
                    prayerSlug: prayer.slug,
                    prayerTitle: prayer.title,
                    prayerSubtitle: prayer.subtitle,
                    label: label,
                    showsTitle: partIndex == 0,
                    paragraphs: group.paragraphs,
                    prayerIndex: prayerIndex
                ))
            }
        }
        return fragments
    }

    // MARK: - Текст молитвы → абзацы

    private static func paragraphs(for prayer: Prayer,
                                    language: PrayerLanguage,
                                    showStress: Bool,
                                    names: (PomyannikList) -> [WatchSnapshot.Entry]) -> [Fragment.Paragraph] {
        var text: String
        switch language {
        case .russian where prayer.textRU != nil:
            text = prayer.textRU ?? prayer.textCS
        default:
            text = prayer.textCS
        }

        if prayer.takesNames {
            let entries = prayer.nameList.map(names) ?? []
            let toInsert: [PrayerTemplateRenderer.NameToInsert] = entries.map { entry in
                let declined = (prayer.nameCase == .accusative) ? entry.canonicalAcc : entry.canonicalGen
                return PrayerTemplateRenderer.NameToInsert(declined: declined, gender: entry.genderValue)
            }
            text = PrayerTemplateRenderer.render(text, names: toInsert)
        }

        if !showStress {
            text = StressMarks.strip(text)
        }

        return text.components(separatedBy: "\n\n").compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("*") && trimmed.hasSuffix("*") && trimmed.count > 2 {
                return Fragment.Paragraph(text: String(trimmed.dropFirst().dropLast()), isRubric: true)
            }
            return Fragment.Paragraph(text: trimmed, isRubric: false)
        }
    }

    // MARK: - Абзацы → фрагменты одной молитвы

    private struct Group {
        var paragraphs: [Fragment.Paragraph]
        var anchorRubricText: String?
    }

    private static func group(paragraphs: [Fragment.Paragraph]) -> [Group] {
        guard !paragraphs.isEmpty else {
            return [Group(paragraphs: [], anchorRubricText: nil)]
        }

        let rubricCount = paragraphs.filter(\.isRubric).count
        if rubricCount >= rubricAnchorThreshold {
            return groupByRubric(paragraphs)
        }
        return groupByLength(paragraphs)
    }

    /// Новый фрагмент на каждом абзаце-указании (когда указаний ≥4 — как в канонах).
    private static func groupByRubric(_ paragraphs: [Fragment.Paragraph]) -> [Group] {
        var groups: [Group] = []
        var current: [Fragment.Paragraph] = []
        var anchor: String?

        for paragraph in paragraphs {
            if paragraph.isRubric {
                if !current.isEmpty {
                    groups.append(Group(paragraphs: current, anchorRubricText: anchor))
                }
                current = [paragraph]
                anchor = paragraph.text
            } else {
                current.append(paragraph)
            }
        }
        if !current.isEmpty {
            groups.append(Group(paragraphs: current, anchorRubricText: anchor))
        }
        return groups
    }

    /// Накопление абзацев, пока не будет превышен предел в 1 800 символов.
    /// Абзац длиннее предела — сам по себе отдельный фрагмент.
    private static func groupByLength(_ paragraphs: [Fragment.Paragraph]) -> [Group] {
        var groups: [Group] = []
        var current: [Fragment.Paragraph] = []
        var currentLength = 0

        func flush() {
            if !current.isEmpty {
                groups.append(Group(paragraphs: current, anchorRubricText: nil))
                current = []
                currentLength = 0
            }
        }

        for paragraph in paragraphs {
            let length = paragraph.text.count
            if length > maxFragmentChars {
                flush()
                groups.append(Group(paragraphs: [paragraph], anchorRubricText: nil))
                continue
            }
            if !current.isEmpty && currentLength + length > maxFragmentChars {
                flush()
            }
            current.append(paragraph)
            currentLength += length
        }
        flush()
        return groups
    }
}
