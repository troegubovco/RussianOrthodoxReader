//
//  CatalogView.swift
//  RussianOrthodoxReaderWatch
//
//  «Разделы» — полный каталог молитвослова. Верхнеуровневая категория с
//  подкатегориями становится своим Section'ом; категория без подкатегорий —
//  сама лист и попадает в общий раздел «Ещё».
//

import SwiftUI

/// Поиск категории по slug'у в дереве категорий (используется и корневым
/// экраном для строк «Утренние»/«Вечерние»/«Поминовение», и каталогом).
enum PrayerCatalog {
    static func category(slug: String) -> PrayerCategory? {
        let top = PrayersRepository.shared.categories()
        if let match = top.first(where: { $0.slug == slug }) { return match }
        for parent in top {
            if let match = PrayersRepository.shared.subcategories(of: parent.id).first(where: { $0.slug == slug }) {
                return match
            }
        }
        return nil
    }
}

struct CatalogView: View {
    private struct CatalogSection: Identifiable {
        let id: String
        let title: String
        let leaves: [PrayerCategory]
    }

    private var sections: [CatalogSection] {
        let top = PrayersRepository.shared.categories()
        var result: [CatalogSection] = []
        var childless: [PrayerCategory] = []

        for category in top {
            let children = PrayersRepository.shared.subcategories(of: category.id)
            if children.isEmpty {
                childless.append(category)
            } else {
                result.append(CatalogSection(id: category.slug, title: category.title, leaves: children))
            }
        }
        if !childless.isEmpty {
            result.append(CatalogSection(id: "more", title: "Ещё", leaves: childless))
        }
        return result
    }

    var body: some View {
        List {
            NavigationLink(value: WatchRoute.search) {
                Label("Поиск", systemImage: "magnifyingglass")
            }
            .accessibilityElement(children: .combine)

            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.leaves) { leaf in
                        row(for: leaf)
                    }
                }
            }
        }
        .navigationTitle("Разделы")
    }

    @ViewBuilder
    private func row(for leaf: PrayerCategory) -> some View {
        if leaf.isSequence {
            NavigationLink(value: WatchRoute.read(ReadingUnitRef(kind: .sequence(categorySlug: leaf.slug, title: leaf.title)))) {
                rowLabel(leaf)
            }
        } else {
            NavigationLink(value: WatchRoute.prayerList(leaf)) {
                rowLabel(leaf)
            }
        }
    }

    private func rowLabel(_ leaf: PrayerCategory) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(leaf.title)
            if let subtitle = leaf.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
