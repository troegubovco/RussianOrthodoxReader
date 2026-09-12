import SwiftUI

@MainActor
private final class ReaderScrollObservationCoordinator {
    private var sectionFrames: [String: CGRect] = [:]
    private var latestVisibleRect: CGRect = .zero
    private var latestVisibleIDs: [String] = []
    private var isScheduled = false
    private var generation = 0

    func updateSectionFrame(id: String, frame: CGRect) {
        sectionFrames[id] = frame
    }

    func schedule(visibleRect: CGRect, apply: @escaping ([String]) -> Void) {
        latestVisibleRect = visibleRect
        let capturedGeneration = generation
        guard !isScheduled else { return }
        isScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == capturedGeneration else { return }
            self.isScheduled = false
            self.latestVisibleIDs = self.sectionFrames.compactMap { id, frame in
                guard frame.height > 0,
                      frame.maxY > self.latestVisibleRect.minY,
                      frame.minY < self.latestVisibleRect.maxY else { return nil }
                return id
            }
            apply(self.latestVisibleIDs)
        }
    }

    func reset() {
        generation += 1
        sectionFrames = [:]
        latestVisibleRect = .zero
        latestVisibleIDs = []
        isScheduled = false
    }
}

struct ReaderView: View {
    let route: ReaderRoute
    let onBack: (ReaderRoute?) -> Void
    /// Called when the user picks a tab via the swipe-up navigation overlay.
    var onSwitchTab: ((AppState.Tab, ReaderRoute?) -> Void)? = nil
    /// Reports the currently visible chapter so the parent can persist it.
    var onVisibleRouteChange: ((ReaderRoute) -> Void)? = nil
    /// bookId, chapter, verse — called when a Bible search result (opened
    /// from the reader header's magnifier button) is tapped, so the parent
    /// can re-point this same reader at the new verse.
    var onOpenVerse: ((String, Int, Int) -> Void)? = nil
    /// When set (and `route` is `.chapter`), the reader scrolls to and briefly
    /// highlights this verse instead of landing on the top of the chapter —
    /// set from a Bible search result tap. See search_design.md §4.5.
    var initialVerse: Int? = nil
    /// When set (and `route` is `.kathisma`), the reader scrolls to that
    /// «Слава» (1...3) instead of the top of the kathisma — set from a
    /// `PsalterSheet` «Слава» sub-row tap. See akathist_psalter_design.md §6.
    var initialSlava: Int? = nil

    @EnvironmentObject var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
    @StateObject private var viewModel = ReaderViewModel()
    @State private var showDictionary = false
    @State private var showBibleSearch = false
    @State private var selectedWord: String?
    @State private var showTabOverlay = false
    @State private var showSlavaPrayers = false
    @State private var showKathismaSlavonic = false
    @State private var showKathismaPrayers = false
    /// Local tracking of the visible chapter — updated from scroll target visibility.
    @State private var visibleBookId: String?
    @State private var visibleChapter: Int?
    @State private var pendingScrollTargetID: String?
    @State private var highlightedVerseID: String?
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var scrollObservationCoordinator = ReaderScrollObservationCoordinator()

    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    /// Includes `initialVerse`/`initialSlava` so re-tapping a different verse
    /// (or «Слава») in an already-open chapter/kathisma (same `route`) still
    /// re-triggers the scroll+task.
    private var taskID: String {
        "\(route.id)#\(initialVerse.map(String.init) ?? "")#\(initialSlava.map(String.init) ?? "")"
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            VStack(spacing: 0) {
                readerHeader(isLandscape: isLandscape)

                ScrollView {
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    } else {
                        // Flattened: headers and verses are siblings in ONE
                        // LazyVStack (not header-containing-a-nested-LazyVStack-
                        // of-verses), each with its own `.id()`. Verified on
                        // device that `ScrollPosition.scrollTo(id:)` does not
                        // reliably reach an id nested one lazy container deep
                        // (search_design.md §4.5) — the cheap `.id()`-on-the-
                        // inner-row variant landed at the top of the chapter
                        // instead of the target verse.
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                rowView(row, isFirst: index == 0)
                                    .id(row.id)
                                    .onGeometryChange(for: CGRect.self) { geometry in
                                        geometry.frame(in: .scrollView(axis: .vertical))
                                    } action: { frame in
                                        scrollObservationCoordinator.updateSectionFrame(id: row.id, frame: frame)
                                    }
                            }
                        }
                        .scrollTargetLayout()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .readableContentWidth()
                        .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                        .padding(.top, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
                        .padding(.bottom, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
                    }
                }
                .scrollPosition($scrollPosition, anchor: .top)
                .onScrollGeometryChange(for: CGRect.self, of: { geometry in
                    geometry.visibleRect
                }) { _, visibleRect in
                    scrollObservationCoordinator.schedule(visibleRect: visibleRect) { coalescedVisibleIDs in
                        handleVisibleSectionIDs(coalescedVisibleIDs)
                    }
                }
                .onChange(of: viewModel.scrollRequest) { _, newRequest in
                    guard let newRequest else { return }
                    pendingScrollTargetID = newRequest.id
                    Task { @MainActor in
                        scrollToSection(newRequest)
                    }
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        #if os(iOS)
        // Swipe-up tab navigation overlay (iOS only)
        .overlay { tabNavigationOverlay }
        #endif
        .task(id: taskID) {
            visibleBookId = nil
            visibleChapter = nil
            pendingScrollTargetID = nil
            highlightedVerseID = nil
            scrollPosition = ScrollPosition(idType: String.self)
            scrollObservationCoordinator.reset()
            if case let .chapter(bookId, chapter) = route {
                visibleBookId = bookId
                visibleChapter = chapter
                let sectionID = "\(bookId)-\(chapter)"
                if let initialVerse {
                    let verseID = "\(sectionID)#\(initialVerse)"
                    pendingScrollTargetID = verseID
                    highlightedVerseID = verseID
                } else {
                    pendingScrollTargetID = sectionID
                }
                onVisibleRouteChange?(ReaderRoute.chapter(bookId: bookId, chapter: chapter))
            }
            viewModel.load(route: route, targetVerse: initialVerse, targetSlava: initialSlava)

            #if DEBUG
            // `SINODAL_OPEN_KATHISMA_SHEET=cs|prayers` — see DebugLaunchHooks.swift.
            if kathismaNumber != nil {
                switch DebugLaunchHooks.openKathismaSheet {
                case .slavonic: showKathismaSlavonic = true
                case .prayers: showKathismaPrayers = true
                case nil: break
                }
            }
            #endif

            // Briefly highlight the target verse, then fade it back out.
            if highlightedVerseID != nil {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                withAnimation { highlightedVerseID = nil }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showDictionary) {
            DictionaryLookupView()
        }
        #else
        .sheet(isPresented: $showDictionary) {
            DictionaryLookupView()
        }
        #endif
        .sheet(isPresented: $showBibleSearch) {
            BibleSearchView(onSelectVerse: onOpenVerse)
        }
        .sheet(isPresented: .init(
            get: { selectedWord != nil },
            set: { if !$0 { selectedWord = nil } }
        )) {
            if let word = selectedWord {
                WordDefinitionSheet(word: word)
                    .presentationDetents([.medium, .large])
            }
        }
        // Псалтирь по кафизмам — header buttons and the «Слава» divider row's
        // sheets. See akathist_psalter_design.md §6.3.
        .sheet(isPresented: $showSlavaPrayers) {
            SlavaPrayersSheet()
        }
        .sheet(isPresented: $showKathismaSlavonic) {
            PsalterPrayerSheet(
                title: kathismaNumber.map { "Кафизма \($0), церковнославянский" } ?? "Кафизма",
                text: kathismaSlavonicText
            )
        }
        .sheet(isPresented: $showKathismaPrayers) {
            PsalterPrayerSheet(
                title: kathismaNumber.map { "Молитвы по кафизме \($0)" } ?? "Молитвы по кафизме",
                text: kathismaTrailingPrayerText
            )
        }
    }

    // MARK: - Tab navigation overlay

    #if os(iOS)
    @ViewBuilder
    private var tabNavigationOverlay: some View {
        ZStack(alignment: .bottom) {
            // Transparent hot zone at the very bottom — detects the swipe-up gesture.
            // Restricted to this zone so normal content scrolling is unaffected.
            if !showTabOverlay {
                VStack(spacing: 0) {
                    Spacer()
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .contentShape(Rectangle())
                        .gesture(swipeUpGesture)
                }
            }

            // Dimmed backdrop + floating tab bar, shown after a qualifying swipe.
            if showTabOverlay {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showTabOverlay = false
                        }
                    }
                    .transition(.opacity)

                floatingTabBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showTabOverlay)
    }

    private var swipeUpGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                let dy = value.translation.height      // negative = upward
                let dx = value.translation.width
                // Require: upward ≥ 40 pt, primarily vertical, sufficient velocity.
                guard dy < -40,
                      abs(dy) > abs(dx) * 1.3,
                      value.predictedEndTranslation.height < -90
                else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showTabOverlay = true
                }
            }
    }

    private var floatingTabBar: some View {
        VStack(spacing: 0) {
            // Drag handle
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(theme.muted.opacity(0.45))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)

            HStack(spacing: 0) {
                ForEach(AppState.Tab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showTabOverlay = false
                        }
                        onSwitchTab?(tab, currentChapterRoute())
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 22))
                            Text(tab.rawValue)
                                .font(AppFont.regular(11))
                        }
                        .foregroundColor(appState.selectedTab == tab ? theme.accent : theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.rawValue)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(
            theme.background.opacity(0.97)
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: -6)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
    #endif

    // MARK: - Header

    private func readerHeader(isLandscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    onBack(currentChapterRoute())
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                        Text("Назад")
                    }
                    .font(AppFont.regular(typ.footnote))
                    .foregroundColor(theme.accent)
                }
                .accessibilityLabel("Назад")

                Spacer()

                HStack(spacing: 8) {
                    // Bible search — the reader already teaches "the header is
                    // where lookups live", and "where else does it say this"
                    // is the most common mid-reading search. See §4.5.
                    Button {
                        showBibleSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(theme.card)
                            .foregroundColor(theme.muted)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .accessibilityLabel("Поиск по Библии")

                    // Dictionary lookup
                    Button {
                        showDictionary = true
                    } label: {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(theme.card)
                            .foregroundColor(theme.muted)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .accessibilityLabel("Открыть словарь")

                    Button {
                        appState.fontSize = AppState.clampFontSize(appState.fontSize - 2)
                    } label: {
                        Text("A-")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .foregroundColor(theme.text)
                    .accessibilityLabel("Уменьшить шрифт")

                    Button {
                        appState.fontSize = AppState.clampFontSize(appState.fontSize + 2)
                    } label: {
                        Text("A+")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .foregroundColor(theme.text)
                    .accessibilityLabel("Увеличить шрифт")
                }
            }

            Text(viewModel.title)
                .font(AppFont.medium(typ.headline))
                .foregroundColor(theme.text)

            // Translation badge
            translationBadge("Синодальный", active: true)

            // Псалтирь по кафизмам: ЦС text + this kathisma's own troparia/
            // prayer, both from the молитвослов (`psaltir.kafizma-N`).
            // See akathist_psalter_design.md §1.2/§6.3.
            if kathismaNumber != nil {
                HStack(spacing: 8) {
                    kathismaHeaderButton("ЦС") { showKathismaSlavonic = true }
                    kathismaHeaderButton("Молитвы по кафизме") { showKathismaPrayers = true }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readableContentWidth()
        .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
        .padding(.top, isLandscape ? 8 : 6)
        .padding(.bottom, isLandscape ? 8 : 0)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func translationBadge(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(AppFont.regular(typ.caption))
            .foregroundColor(active ? theme.accent : theme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(active ? theme.accent.opacity(0.1) : theme.card)
            )
    }

    private func kathismaHeaderButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(AppFont.regular(typ.caption))
                .foregroundColor(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.accent.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Псалтирь по кафизмам

    private var kathismaNumber: Int? {
        if case let .kathisma(number) = route { return number }
        return nil
    }

    private var kathismaSlavonicText: String? {
        guard let kathismaNumber else { return nil }
        return PrayersRepository.shared.prayer(slug: "psaltir.kafizma-\(kathismaNumber)")?.textCS
    }

    /// The paragraphs from the rubric that announces "По N-й кафисме…" /
    /// "По кафисме…" onward — this kathisma's own troparia and prayer, which
    /// sit in the tail of the same `psaltir.kafizma-N` prayer text, right
    /// after its third «Слава». `nil` when the slug is missing or the rubric
    /// can't be found — content ingestion is still in progress (see
    /// akathist_psalter_design.md §7 Package A); the sheet shows a
    /// «Текст появится после обновления» note in that case.
    private var kathismaTrailingPrayerText: String? {
        guard let full = kathismaSlavonicText else { return nil }
        let paragraphs = full.components(separatedBy: "\n\n")
        guard let index = paragraphs.firstIndex(where: { paragraph in
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("*"), trimmed.hasSuffix("*"), trimmed.count > 2 else { return false }
            let inner = trimmed.dropFirst().dropLast()
            return inner.hasPrefix("По") && inner.contains("кафис")
        }) else { return nil }
        return paragraphs[index...].joined(separator: "\n\n")
    }

    // MARK: - Rows (flattened sections/verses — see the comment in `body`)

    /// One row per section header, plus one row per verse — all as direct
    /// siblings of the same outer `LazyVStack`/`scrollTargetLayout()`, so
    /// every id (section OR verse) is a valid `scrollPosition.scrollTo` target.
    private struct ReaderRow: Identifiable {
        enum Kind {
            case header(title: String, subtitle: String?)
            case verse(BibleVerse)
            /// A kathisma «Слава» boundary — thin rule + muted small-caps
            /// label, tappable to open `SlavaPrayersSheet`. See
            /// akathist_psalter_design.md §6.3.
            case divider(text: String)
        }
        let id: String
        let sectionID: String
        let kind: Kind
    }

    private var rows: [ReaderRow] {
        viewModel.sections.flatMap { section -> [ReaderRow] in
            var sectionRows: [ReaderRow] = [
                ReaderRow(id: section.id, sectionID: section.id,
                          kind: .header(title: section.title, subtitle: section.subtitle))
            ]
            sectionRows.append(contentsOf: section.verses.map { verse in
                ReaderRow(id: "\(section.id)#\(verse.number)", sectionID: section.id, kind: .verse(verse))
            })
            if let dividerText = section.trailingDivider {
                sectionRows.append(ReaderRow(id: "\(section.id)-divider", sectionID: section.id,
                                              kind: .divider(text: dividerText)))
            }
            return sectionRows
        }
    }

    @ViewBuilder
    private func rowView(_ row: ReaderRow, isFirst: Bool) -> some View {
        switch row.kind {
        case let .header(title, subtitle):
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .sectionHeader()
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.regular(typ.caption))
                        .foregroundColor(theme.muted)
                }
            }
            .padding(.top, isFirst ? 0 : 18)
        case let .verse(verse):
            verseBlock(verse: verse, isHighlighted: highlightedVerseID == row.id)
        case let .divider(text):
            Button {
                showSlavaPrayers = true
            } label: {
                VStack(spacing: 6) {
                    Rectangle()
                        .fill(theme.border)
                        .frame(height: 0.5)
                    Text(text.uppercased())
                        .font(AppFont.medium(typ.micro))
                        .tracking(1.5)
                        .foregroundColor(theme.muted)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text)
            .accessibilityHint("Молитвы после «Слава»")
        }
    }

    /// Solid pre-blend of `theme.accent` at ~12% over `theme.background` —
    /// `SelectableTextView` sets this straight on the underlying
    /// UITextView/NSTextView's opaque `backgroundColor`, so a translucent
    /// SwiftUI `.background()` modifier behind it would just get painted
    /// over and never show. Same visual result, computed once.
    private static let highlightBackground = Color(red: 0.928, green: 0.906, blue: 0.855)

    @ViewBuilder
    private func verseBlock(verse: BibleVerse, isHighlighted: Bool = false) -> some View {
        let clean = cleanVerseText(verse.synodal)

        SelectableTextView(
            attributedText: verseNSAttributedString(number: verse.number, text: clean),
            backgroundColor: PlatformColor(isHighlighted ? Self.highlightBackground : theme.background),
            onWordSelected: { word in
                selectedWord = word
            }
        )
        .padding(.horizontal, isHighlighted ? 6 : 0)
        .padding(.vertical, isHighlighted ? 4 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Self.highlightBackground : .clear)
        )
        .accessibilityLabel("Стих \(verse.number). \(clean)")
    }

    // MARK: - Text helpers

    private func cleanVerseText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func verseNSAttributedString(number: Int, text: String) -> NSAttributedString {
        let fontSize = typ.body
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = fontSize * 0.4

        let result = NSMutableAttributedString(
            string: "\(number) ",
            attributes: [
                .font: AppFont.platformFont(size: fontSize - 4, weight: .bold),
                .foregroundColor: PlatformColor(theme.accent),
                .paragraphStyle: paragraphStyle,
            ]
        )
        result.append(NSMutableAttributedString(
            string: text,
            attributes: [
                .font: AppFont.platformFont(size: fontSize, weight: .regular),
                .foregroundColor: PlatformColor(theme.text),
                .paragraphStyle: paragraphStyle,
            ]
        ))
        return result
    }

    private func scrollToSection(_ request: ReaderScrollRequest) {
        var transaction = Transaction()
        transaction.disablesAnimations = !request.animated
        withTransaction(transaction) {
            scrollPosition.scrollTo(id: request.id, anchor: .top)
        }
    }

    /// Strips a trailing "#verse" suffix, if any, from a row id — both
    /// section-header rows ("joh-3") and verse rows ("joh-3#16") are tracked
    /// individually now that sections/verses are flattened into one
    /// `LazyVStack` (see `rows`), but "which chapter is visible" only cares
    /// about the section part.
    private func stripVerseSuffix(_ id: String) -> String {
        id.split(separator: "#", maxSplits: 1).first.map(String.init) ?? id
    }

    private func handleVisibleSectionIDs(_ visibleIDs: [String]) {
        guard case .chapter = route else { return }

        let visibleSectionIDs = Set(visibleIDs.map(stripVerseSuffix))
        guard !visibleSectionIDs.isEmpty else { return }

        guard let section = viewModel.sections.first(where: { visibleSectionIDs.contains($0.id) }),
              let bookId = section.bookId,
              let chapter = section.chapter else { return }

        if let pendingScrollTargetID {
            guard section.id == stripVerseSuffix(pendingScrollTargetID) else { return }
            self.pendingScrollTargetID = nil
        }

        guard visibleBookId != bookId || visibleChapter != chapter else { return }
        visibleBookId = bookId
        visibleChapter = chapter
        onVisibleRouteChange?(ReaderRoute.chapter(bookId: bookId, chapter: chapter))
    }

    private func currentChapterRoute() -> ReaderRoute? {
        guard case let .chapter(bookId, chapter) = route else { return nil }
        return .chapter(
            bookId: visibleBookId ?? bookId,
            chapter: visibleChapter ?? chapter
        )
    }
}

#Preview {
    ReaderView(route: .chapter(bookId: "mat", chapter: 5), onBack: { _ in })
        .environmentObject(AppState())
}
