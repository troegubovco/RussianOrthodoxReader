//
//  PrayerListView.swift
//  RussianOrthodoxReaderWatch
//
//  Список отдельных молитв — либо всей категории (не-последования, например
//  «Богородице»), либо произвольного набора slug'ов (закладки). Строка ведёт
//  на чтение конкретной молитвы.
//
//  Названо WatchPrayerListView, чтобы не путать с одноимённым типом на iPhone
//  (хотя таргеты — разные модули).
//

import SwiftUI

struct WatchPrayerListView: View {
    private struct Row: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String?
    }

    private let navTitle: String
    private let rows: [Row]
    /// Чтение всего списка подряд (только для наборов slug'ов — закладок).
    private let sequenceRef: ReadingUnitRef?

    init(category: PrayerCategory) {
        navTitle = category.title
        rows = PrayersRepository.shared.prayers(inCategory: category.slug).map {
            Row(id: $0.slug, title: $0.title, subtitle: $0.subtitle)
        }
        sequenceRef = nil
    }

    init(title: String, slugs: [String]) {
        navTitle = title
        rows = PrayersRepository.shared.prayers(slugs: slugs).map {
            Row(id: $0.slug, title: $0.title, subtitle: $0.subtitle)
        }
        sequenceRef = slugs.count > 1
            ? ReadingUnitRef(kind: .list(title: title, slugs: slugs))
            : nil
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Text("Список пуст")
                    .foregroundStyle(WatchTheme.muted)
            }
            if let sequenceRef {
                NavigationLink(value: WatchRoute.read(sequenceRef)) {
                    Label("Читать подряд", systemImage: "text.justify.leading")
                        .foregroundStyle(WatchTheme.accent)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(WatchTheme.accent.opacity(0.16)))
                .accessibilityElement(children: .combine)
            }
            ForEach(rows) { row in
                NavigationLink(value: WatchRoute.read(ReadingUnitRef(kind: .prayer(slug: row.id)))) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                        if let subtitle = row.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(WatchTheme.muted)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle(navTitle)
    }
}
