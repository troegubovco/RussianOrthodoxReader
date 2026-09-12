import SwiftUI

/// Bible full-text search — modelled on `PrayerSearchView`
/// (PrayersView.swift:253) and `DictionaryLookupView`. See search_design.md §4.5.
///
/// Custom in-app search field, **not** `.searchable` — this project's own
/// documented lesson (PrayerSearchView, PrayersView.swift:~265) is that the
/// system `.searchable` inside a sheet looks foreign/clipped on macOS.
struct BibleSearchView: View {
    /// Prefills and immediately runs a search — used by the
    /// `SINODAL_OPEN_SEARCH` DEBUG launch hook (see RussianOrthodoxReaderApp.swift).
    var initialQuery: String = ""
    /// bookId, chapter, verse. Optional so `#Preview` and any call site that
    /// doesn't care about navigation still compiles.
    var onSelectVerse: ((String, Int, Int) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private let repo = BibleSearchRepository.shared
    private let pageSize = 50

    @State private var query = ""
    @State private var testament: Testament?
    @State private var referenceResult: BibleReferenceQuery.Result?
    @State private var topicResults: [BibleTopicResult] = []
    @State private var verseResults: [BibleSearchResult] = []
    @State private var queryStems: Set<String> = []
    @State private var totalCount = 0
    @State private var page = 1
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    /// Поле поиска в стиле приложения — как в PrayerSearchView, системный
    /// .searchable в шите на macOS выглядит чужеродно и обрезанно.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.muted)

            TextField("Слово, фраза или ссылка — Ин 3:16", text: $query)
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.text)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .autocorrectionDisabled()

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var testamentPicker: some View {
        SlidingSegmentedControl(
            segments: [
                .init(value: nil, title: "Всё"),
                .init(value: .old, title: "Ветхий Завет"),
                .init(value: .new, title: "Новый Завет"),
            ],
            selection: $testament,
            font: AppFont.regular(typ.footnote)
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                testamentPicker

                Group {
                    if !repo.isAvailable {
                        unavailablePlaceholder
                    } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
                        placeholder
                    } else if referenceResult == nil && topicResults.isEmpty && verseResults.isEmpty {
                        Text("Ничего не найдено")
                            .font(AppFont.regular(typ.body))
                            .foregroundColor(theme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        resultsList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Поиск по Библии")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
        .onAppear {
            query = initialQuery
            searchFocused = true
            runSearch(resetPage: true)
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: testament) { _, _ in scheduleSearch() }
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let referenceResult {
                    referenceRow(referenceResult)
                }

                if !topicResults.isEmpty {
                    topicsBand
                }

                if !verseResults.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Найдено стихов: \(totalCount)")
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                            .padding(.horizontal, 4)

                        VStack(spacing: 0) {
                            ForEach(Array(verseResults.enumerated()), id: \.element.id) { index, result in
                                Button {
                                    select(bookId: result.bookId, chapter: result.chapter, verse: result.verse)
                                } label: {
                                    verseRow(result)
                                }
                                .buttonStyle(.plain)

                                if index < verseResults.count - 1 {
                                    Rectangle()
                                        .fill(theme.border)
                                        .frame(height: 0.5)
                                        .padding(.leading, 20)
                                }
                            }
                        }
                        .background(theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        if verseResults.count == page * pageSize {
                            Button("Показать ещё") {
                                page += 1
                                runSearch(resetPage: false)
                            }
                            .font(AppFont.regular(typ.footnote))
                            .foregroundColor(theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
            .readableContentWidth()
            .padding(16)
        }
    }

    private func referenceRow(_ result: BibleReferenceQuery.Result) -> some View {
        Button {
            switch result {
            case let .chapter(bookId, chapter):
                select(bookId: bookId, chapter: chapter, verse: 1)
            case let .verse(bookId, chapter, verse):
                select(bookId: bookId, chapter: chapter, verse: verse)
            case let .range(references):
                guard let first = references.first else { return }
                select(bookId: first.bookId, chapter: first.chapter, verse: first.verseStart)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.accent)
                Text("\(referenceLabel(result)) — открыть")
                    .font(AppFont.semiBold(typ.callout))
                    .foregroundColor(theme.accent)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    private var topicsBand: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Возможно, вы ищете")
                .sectionHeader()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(topicResults.enumerated()), id: \.element.id) { index, topic in
                    Button {
                        select(bookId: topic.bookId, chapter: topic.chapter, verse: topic.verseStart ?? 1)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(theme.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title)
                                    .font(AppFont.regular(typ.callout))
                                    .foregroundColor(theme.text)
                                Text(topic.displayRef)
                                    .font(AppFont.regular(typ.caption))
                                    .foregroundColor(theme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < topicResults.count - 1 {
                        Rectangle()
                            .fill(theme.border)
                            .frame(height: 0.5)
                            .padding(.leading, 48)
                    }
                }
            }
            .background(theme.todayHighlight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private func verseRow(_ result: BibleSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.displayRef)
                .font(AppFont.semiBold(typ.caption))
                .foregroundColor(theme.accent)
            Text(VerseSnippet.make(text: result.text, queryStems: queryStems))
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.muted)
            Text("Введите слово, фразу или ссылку — например, «Ин 3:16»")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var unavailablePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.muted)
            Text("Поиск по Библии временно недоступен")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Actions

    private func select(bookId: String, chapter: Int, verse: Int) {
        onSelectVerse?(bookId, chapter, verse)
        dismiss()
    }

    private func referenceLabel(_ result: BibleReferenceQuery.Result) -> String {
        func abbr(_ bookId: String) -> String {
            BibleDataProvider.book(id: bookId)?.abbreviation ?? bookId.uppercased()
        }
        switch result {
        case let .chapter(bookId, chapter):
            return "\(abbr(bookId)) \(chapter)"
        case let .verse(bookId, chapter, verse):
            return "\(abbr(bookId)) \(chapter):\(verse)"
        case let .range(references):
            guard let first = references.first else { return "" }
            if first.verseStart == first.verseEnd {
                return "\(abbr(first.bookId)) \(first.chapter):\(first.verseStart)"
            }
            return "\(abbr(first.bookId)) \(first.chapter):\(first.verseStart)-\(first.verseEnd)"
        }
    }

    // MARK: - Search

    /// 120 ms debounce — with FTS the work itself is sub-millisecond, so this
    /// is purely cosmetic (avoids re-querying on every keystroke of a long
    /// query), same rationale as PrayerSearchView.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            runSearch(resetPage: true)
        }
    }

    private func runSearch(resetPage: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, repo.isAvailable else {
            referenceResult = nil
            topicResults = []
            verseResults = []
            queryStems = []
            totalCount = 0
            return
        }
        if resetPage { page = 1 }

        referenceResult = BibleReferenceQuery.parse(trimmed)
        // Запрос-ссылка («Ин 3:16», «Быт 1») — только переход: полнотекстовый
        // поиск по «Ин» даёт сотни случайных «иному», «иная» и т.п.
        if referenceResult != nil {
            queryStems = []
            topicResults = []
            verseResults = []
            totalCount = 0
            return
        }
        queryStems = repo.queryStems(trimmed)
        topicResults = repo.topics(matching: trimmed)

        #if DEBUG
        let start = Date()
        #endif
        verseResults = repo.search(query: trimmed, testament: testament, limit: page * pageSize, offset: 0)
        totalCount = repo.count(query: trimmed, testament: testament)
        #if DEBUG
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        print(String(format: "[BibleSearchView] «%@» -> %d/%d verses in %.2f ms",
                     trimmed, verseResults.count, totalCount, elapsedMs))
        #endif
    }
}

#Preview {
    BibleSearchView()
}
