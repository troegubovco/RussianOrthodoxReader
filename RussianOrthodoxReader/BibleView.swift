import SwiftUI

struct BibleView: View {
    let onSelectChapter: (ReaderRoute) -> Void
    /// When non-nil, a "Resume reading" banner is shown at the top of the list.
    var onResume: (() -> Void)? = nil
    /// bookId, chapter, verse — called when a Bible search result is tapped.
    /// Optional so existing call sites and `#Preview` keep compiling unchanged.
    var onSelectVerse: ((String, Int, Int) -> Void)? = nil
    /// (kathisma number, target «Слава» 1...3 or nil) — called from
    /// `PsalterSheet` when a kathisma or one of its «Славы» is tapped.
    /// Optional so existing call sites and `#Preview` keep compiling
    /// unchanged. See akathist_psalter_design.md §6.
    var onSelectKathisma: ((Int, Int?) -> Void)? = nil

    @EnvironmentObject var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
    @State private var selectedTestament: Testament = .new
    @State private var chapterPickerBook: BibleBook?
    @State private var showSearch = false
    @State private var showPsalter = false
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var books: [BibleBook] {
        BibleDataProvider.books(for: selectedTestament)
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Библия")
                        .font(AppFont.medium(typ.title))
                        .foregroundColor(theme.text)
                        .padding(.top, isLandscape ? 12 : 8)

                    BibleSearchPill { showSearch = true }

                    if let onResume {
                        ResumeReadingBanner(onResume: onResume)
                    }

                    // План чтения Псалтири виден там, где Псалтирь (§5.2 п. 3).
                    // onOpen — переход к текущей кафизме плана; у `.psalterSlava`
                    // цель уже несёт номер кафизмы (`kathismaSlava`), у
                    // `.psalterKathisma` цель — это slug молитвы вида
                    // "psaltir.kafizma-N", номер достаём из него.
                    MyReadingsCard(filter: { plan in
                        switch plan.kind {
                        case .psalterKathisma, .psalterSlava: return true
                        default: return false
                        }
                    }, onOpen: { plan in
                        let target = plan.kind.target(for: plan.nextUnitIndex)
                        switch target {
                        case .kathismaSlava(let kathisma, _):
                            onSelectChapter(.kathisma(number: kathisma))
                        case .prayer(let slug):
                            if let number = Self.kathismaNumber(fromSlug: slug) {
                                onSelectChapter(.kathisma(number: number))
                            }
                        }
                    })

                    PsalterCard(action: { showPsalter = true })

                    TestamentPicker(selected: $selectedTestament)

                    LazyVStack(spacing: 2) {
                        ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                            let hasData = BibleDataProvider.hasChapter(bookId: book.id)

                            BibleBookRow(
                                book: book,
                                hasData: hasData,
                                shape: bookRowShape(index: index, total: books.count),
                                onOpenFirstChapter: {
                                    onSelectChapter(.chapter(bookId: book.id, chapter: 1))
                                },
                                onOpenPicker: {
                                    chapterPickerBook = book
                                }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableContentWidth()
                .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.background.ignoresSafeArea())
        .sheet(item: $chapterPickerBook) { book in
            ChapterPickerSheet(book: book) { chapter in
                onSelectChapter(.chapter(bookId: book.id, chapter: chapter))
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSearch) {
            BibleSearchView(onSelectVerse: onSelectVerse)
        }
        .sheet(isPresented: $showPsalter) {
            PsalterSheet(onSelectKathisma: { number, slava in
                onSelectKathisma?(number, slava)
            })
        }
        .onChange(of: appState.bibleResetTrigger) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTestament = .new
                chapterPickerBook = nil
            }
        }
        #if DEBUG
        .onAppear {
            // `SINODAL_OPEN_PSALTER=1` — see DebugLaunchHooks.swift.
            if DebugLaunchHooks.openPsalter {
                showPsalter = true
            }
        }
        #endif
    }

    /// Достаёт номер кафизмы из slug'а вида "psaltir.kafizma-13" — цель
    /// `.psalterKathisma`-плана хранит только slug молитвы, без отдельного
    /// поля с номером (см. `ReadingPlanKind.target(for:)`).
    private static func kathismaNumber(fromSlug slug: String) -> Int? {
        let prefix = "psaltir.kafizma-"
        guard slug.hasPrefix(prefix) else { return nil }
        return Int(slug.dropFirst(prefix.count))
    }

    private func bookRowShape(index: Int, total: Int) -> UnevenRoundedRectangle {
        let topRadius: CGFloat = index == 0 ? 14 : 2
        let bottomRadius: CGFloat = index == total - 1 ? 14 : 2
        return UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
    }
}

private struct BibleBookRow: View {
    let book: BibleBook
    let hasData: Bool
    let shape: UnevenRoundedRectangle
    let onOpenFirstChapter: () -> Void
    let onOpenPicker: () -> Void

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenFirstChapter) {
                HStack(spacing: 14) {
                    Text(book.abbreviation)
                        .font(AppFont.semiBold(typ.micro))
                        .foregroundColor(theme.accent)
                        .frame(width: 52, alignment: .center)

                    Text(book.name)
                        .font(AppFont.regular(typ.subheadline))
                        .foregroundColor(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasData)
            .accessibilityLabel("\(book.name), открыть первую главу")

            Button(action: onOpenPicker) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.muted)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasData)
            .accessibilityLabel("\(book.name), выбрать главу")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(theme.card)
        .clipShape(shape)
        .opacity(hasData ? 1 : 0.45)
    }
}

private struct ChapterPickerSheet: View {
    let book: BibleBook
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chapter: Int

    init(book: BibleBook, onSelect: @escaping (Int) -> Void) {
        self.book = book
        self.onSelect = onSelect
        _chapter = State(initialValue: 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(book.name)) {
                    Picker("Глава", selection: $chapter) {
                        ForEach(1...max(1, book.chapterCount), id: \.self) { value in
                            Text("Глава \(value)").tag(value)
                        }
                    }
                    #if os(iOS)
                    .pickerStyle(.wheel)
                    .frame(maxHeight: 180)
                    #else
                    .pickerStyle(.menu)
                    #endif
                }
            }
            .navigationTitle("Выбор главы")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Открыть") {
                        onSelect(chapter)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TestamentPicker: View {
    @Binding var selected: Testament

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Testament.allCases) { testament in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selected = testament
                    }
                } label: {
                    Text(testament.rawValue)
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(selected == testament ? .white : theme.muted)
                        .fontWeight(selected == testament ? .semibold : .regular)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected == testament ? theme.accent : .clear)
                        )
                }
                .accessibilityLabel(testament.rawValue)
                .accessibilityAddTraits(selected == testament ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.card)
        )
    }
}

// MARK: - Search pill

/// Tappable search entry point, shown between the "Библия" title and the
/// resume-reading banner — BibleView is the browse/find surface, so search
/// belongs at its top. See search_design.md §4.5.
private struct BibleSearchPill: View {
    let action: () -> Void
    private let theme = OrthodoxColors.fallback

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                Text("Поиск по Библии")
                    .font(AppFont.regular(14))
                Spacer()
            }
            .foregroundColor(theme.muted)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Поиск по Библии")
    }
}

// MARK: - Resume banner

private struct ResumeReadingBanner: View {
    let onResume: () -> Void
    private let theme = OrthodoxColors.fallback

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 12) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 14))
                Text("Продолжить чтение")
                    .font(AppFont.regular(14))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.accent.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.2), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Продолжить чтение")
        .accessibilityHint("Вернуться к последнему месту чтения")
    }
}

// MARK: - Псалтирь по кафизмам

/// Entry point into `PsalterSheet`, shown above `TestamentPicker` — "Библия"
/// is the natural place to look for the Psalter's kathisma navigation over
/// the Synodal text (the молитвослов owns the Church-Slavonic text itself).
/// See akathist_psalter_design.md §1.2/§6.
private struct PsalterCard: View {
    let action: () -> Void
    private let theme = OrthodoxColors.fallback

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "book.pages")
                    .font(.system(size: 14))
                Text("Псалтирь по кафизмам · 20 кафизм")
                    .font(AppFont.regular(14))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.accent.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.2), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Псалтирь по кафизмам")
        .accessibilityHint("Открыть список из 20 кафизм")
    }
}

#Preview {
    BibleView(onSelectChapter: { _ in })
        .environmentObject(AppState())
}
