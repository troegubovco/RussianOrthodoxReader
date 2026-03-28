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

    @EnvironmentObject var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
    @StateObject private var viewModel = ReaderViewModel()
    @State private var showDictionary = false
    @State private var selectedWord: String?
    @State private var showTabOverlay = false
    /// Local tracking of the visible chapter — updated from scroll target visibility.
    @State private var visibleBookId: String?
    @State private var visibleChapter: Int?
    @State private var pendingScrollTargetID: String?
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var scrollObservationCoordinator = ReaderScrollObservationCoordinator()

    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

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
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(viewModel.sections) { section in
                                sectionView(section)
                                    .id(section.id)
                                    .onGeometryChange(for: CGRect.self) { geometry in
                                        geometry.frame(in: .scrollView(axis: .vertical))
                                    } action: { frame in
                                        scrollObservationCoordinator.updateSectionFrame(id: section.id, frame: frame)
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
        .task(id: route.id) {
            visibleBookId = nil
            visibleChapter = nil
            pendingScrollTargetID = nil
            scrollPosition = ScrollPosition(idType: String.self)
            scrollObservationCoordinator.reset()
            if case let .chapter(bookId, chapter) = route {
                visibleBookId = bookId
                visibleChapter = chapter
                pendingScrollTargetID = "\(bookId)-\(chapter)"
                onVisibleRouteChange?(ReaderRoute.chapter(bookId: bookId, chapter: chapter))
            }
            viewModel.load(route: route)
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
        .sheet(isPresented: .init(
            get: { selectedWord != nil },
            set: { if !$0 { selectedWord = nil } }
        )) {
            if let word = selectedWord {
                WordDefinitionSheet(word: word)
                    .presentationDetents([.medium, .large])
            }
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

    // MARK: - Section

    private func sectionView(_ section: ReaderSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .sectionHeader()

            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
            }

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(section.verses) { verse in
                    verseBlock(verse: verse)
                }
            }
        }
    }

    @ViewBuilder
    private func verseBlock(verse: BibleVerse) -> some View {
        let clean = cleanVerseText(verse.synodal)

        SelectableTextView(
            attributedText: verseNSAttributedString(number: verse.number, text: clean),
            backgroundColor: PlatformColor(theme.background),
            onWordSelected: { word in
                selectedWord = word
            }
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

    private func handleVisibleSectionIDs(_ visibleIDs: [String]) {
        guard case .chapter = route else { return }

        let visibleIDSet = Set(visibleIDs)
        guard !visibleIDSet.isEmpty else { return }

        guard let section = viewModel.sections.first(where: { visibleIDSet.contains($0.id) }),
              let bookId = section.bookId,
              let chapter = section.chapter else { return }

        if let pendingScrollTargetID {
            guard section.id == pendingScrollTargetID else { return }
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
