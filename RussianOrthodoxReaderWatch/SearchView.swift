//
//  SearchView.swift
//  RussianOrthodoxReaderWatch
//
//  Поиск по названиям и текстам молитв (не .searchable — простое текстовое
//  поле в списке, поиск по onSubmit).
//

import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results: [PrayerSearchResult] = []

    var body: some View {
        List {
            TextField("Поиск", text: $query)
                .onSubmit(runSearch)

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && results.isEmpty {
                Text("Ничего не найдено")
                    .foregroundStyle(WatchTheme.muted)
            }

            ForEach(results) { result in
                row(for: result)
            }
        }
        .navigationTitle("Поиск")
        #if DEBUG
        // SINODAL_WATCH_OPEN=search SINODAL_WATCH_QUERY=<текст> — для снимков
        // экрана результатов поиска без ручного набора на часах.
        .onAppear {
            guard query.isEmpty, let q = ProcessInfo.processInfo.environment["SINODAL_WATCH_QUERY"],
                  !q.isEmpty else { return }
            query = q
            runSearch()
        }
        #endif
    }

    /// Молитва → экран чтения, как раньше. Раздел-результат
    /// (search_design.md §3.4, Tier 2 — например «утром» → «Утренние
    /// молитвы») ведёт туда же, куда и одноимённая строка в CatalogView:
    /// последование целиком читается сразу, обычный раздел открывает список.
    @ViewBuilder
    private func row(for result: PrayerSearchResult) -> some View {
        switch result.kind {
        case .prayer:
            NavigationLink(value: WatchRoute.read(ReadingUnitRef(kind: .prayer(slug: result.slug)))) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                    Text(result.categoryTitle)
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.muted)
                }
            }
            .accessibilityElement(children: .combine)
        case .category(let slug):
            if let category = PrayerCatalog.category(slug: slug) {
                if category.isSequence {
                    NavigationLink(value: WatchRoute.read(ReadingUnitRef(
                        kind: .sequence(categorySlug: category.slug, title: category.title)))) {
                        categoryLabel(category)
                    }
                } else {
                    NavigationLink(value: WatchRoute.prayerList(category)) {
                        categoryLabel(category)
                    }
                }
            }
        }
    }

    private func categoryLabel(_ category: PrayerCategory) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(WatchTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                if let subtitle = category.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            return
        }
        results = PrayersRepository.shared.search(query: trimmed)
    }
}
