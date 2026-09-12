//
//  WatchRoute.swift
//  RussianOrthodoxReaderWatch
//
//  Навигация часов: NavigationStack + navigationDestination(for: WatchRoute.self).
//  Глубина не превышает 3 push'а от корня (root → раздел → список → чтение).
//

import Foundation

/// Единица чтения: что именно показывает экран чтения, и с какого фрагмента
/// начать (используется при восстановлении позиции чтения — «Продолжить»).
struct ReadingUnitRef: Hashable, Codable {
    enum Kind: Hashable, Codable {
        /// Последование целиком (утренние/вечерние/ко Причащению…).
        case sequence(categorySlug: String, title: String)
        /// Одна молитва.
        case prayer(slug: String)
        /// «Моё правило» — произвольный набор молитв по slug'ам.
        case rule(slugs: [String])
        /// Произвольный набор молитв с собственным заголовком (например,
        /// «Закладки» подряд).
        case list(title: String, slugs: [String])
    }

    var kind: Kind
    var startFragment: Int?

    init(kind: Kind, startFragment: Int? = nil) {
        self.kind = kind
        self.startFragment = startFragment
    }
}

/// Маршруты навигации часов.
enum WatchRoute: Hashable {
    case catalog
    case prayerList(PrayerCategory)
    /// Список молитв по конкретным slug'ам (используется для закладок).
    case prayers(title: String, slugs: [String])
    case read(ReadingUnitRef)
    case search
    case settings
    /// Экран плана чтения («Мои чтения», §4/§5 akathist_psalter_design.md).
    /// Строка — `WatchSnapshot.Plan.uuid`; сам план ищется в
    /// `WatchUserDataStore.shared.plans` в момент отрисовки, а не хранится
    /// в маршруте — план мог обновиться (отметка «прочитано», новый снимок)
    /// уже после push'а.
    case plan(String)
}
