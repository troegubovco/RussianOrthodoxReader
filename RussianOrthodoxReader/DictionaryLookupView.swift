import SwiftUI

struct DictionaryLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    @State private var query: String = ""
    @State private var results: [DictionaryEntry] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private let dictionary = DictionaryRepository.shared
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let isLandscape = proxy.size.width > proxy.size.height

                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(theme.muted)
                            .font(.system(size: 16))

                        TextField("Найти слово...", text: $query)
                            .font(AppFont.regular(typ.subheadline))
                            .foregroundColor(theme.text)
                            .autocorrectionDisabled()
                            .focused($isSearchFocused)
                            .onChange(of: query) { _, newValue in
                                performSearch(newValue)
                            }

                        if !query.isEmpty {
                            Button {
                                query = ""
                                results = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(theme.muted)
                            }
                            .accessibilityLabel("Очистить")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                    .padding(.vertical, isLandscape ? 8 : 14)

                    Divider()
                        .background(theme.border)

                    if query.isEmpty {
                        emptyState(isLandscape: isLandscape)
                    } else if results.isEmpty && !isSearching {
                        noResults
                    } else {
                        resultsList(isLandscape: isLandscape)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Словарь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") {
                        isSearchFocused = false
                        dismiss()
                    }
                    .font(AppFont.regular(17))
                    .foregroundColor(theme.accent)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") {
                        isSearchFocused = false
                    }
                    .foregroundColor(theme.accent)
                }
            }
        }
    }

    // MARK: - States

    private func emptyState(isLandscape: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "character.book.closed")
                .font(.system(size: isLandscape ? 32 : 48))
                .foregroundColor(theme.accent.opacity(0.4))
                .padding(.top, isLandscape ? 24 : 48)

            Text("Библейский словарь")
                .font(AppFont.medium(typ.callout))
                .foregroundColor(theme.text)

            Text("Введите имя, место или термин из Синодальной Библии или церковнославянское слово, чтобы найти объяснение.")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text("Источники: Нюстрем Э. Библейский словарь; Церковнослав. словарь")
                .font(AppFont.regular(typ.caption))
                .foregroundColor(theme.muted.opacity(0.7))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundColor(theme.muted.opacity(0.5))
                .padding(.top, 48)

            Text("Слово не найдено")
                .font(AppFont.medium(typ.subheadline))
                .foregroundColor(theme.text)

            Text("«\(query)» не найдено в словаре.\nПопробуйте начальную форму слова.")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func resultsList(isLandscape: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(results) { entry in
                    DictionaryEntryRow(entry: entry)
                }
            }
            .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
            .padding(.vertical, 12)
            .padding(.bottom, isLandscape ? 8 : 20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Search

    private func performSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            // Debounce: wait 200ms before executing search
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let found = dictionary.search(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}

// MARK: - Entry Row

struct DictionaryEntryRow: View {
    let entry: DictionaryEntry
    @State private var isExpanded = false

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.word)
                            .font(AppFont.semiBold(typ.subheadline))
                            .foregroundColor(theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !isExpanded {
                            Text(entry.definition)
                                .font(AppFont.regular(typ.footnote))
                                .foregroundColor(theme.muted)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.muted)
                        .padding(.top, 3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.definition)
                            .font(AppFont.regular(typ.body))
                            .foregroundColor(theme.text)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Источник: \(entry.source)")
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DictionaryLookupView()
}
