import SwiftUI
import UIKit

struct ReaderView: View {
    let route: ReaderRoute
    let onBack: () -> Void
    /// Called when the user picks a tab via the swipe-up navigation overlay.
    var onSwitchTab: ((AppState.Tab) -> Void)? = nil

    @EnvironmentObject var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
    @StateObject private var viewModel = ReaderViewModel()
    @State private var showDictionary = false
    @State private var selectedWord: String?
    @State private var showTabOverlay = false
    /// Tracks the currently visible section for scroll position.
    @State private var scrolledSectionID: String?

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
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                        .padding(.top, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
                        .padding(.bottom, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
                    }
                }
                .scrollPosition(id: $scrolledSectionID, anchor: .top)
                .onChange(of: viewModel.scrollToSectionID) { _, newID in
                    scrolledSectionID = newID
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        // Swipe-up tab navigation overlay
        .overlay { tabNavigationOverlay }
        .task(id: route.id) {
            scrolledSectionID = nil
            await viewModel.load(route: route)
        }
        .fullScreenCover(isPresented: $showDictionary) {
            DictionaryLookupView()
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
    }

    // MARK: - Tab navigation overlay

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
                        onSwitchTab?(tab)
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

    // MARK: - Header

    private func readerHeader(isLandscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onBack) {
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
            backgroundColor: UIColor(theme.background),
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
                .font: AppFont.uiFont(size: fontSize - 4, weight: .bold),
                .foregroundColor: UIColor(theme.accent),
                .paragraphStyle: paragraphStyle,
            ]
        )
        result.append(NSMutableAttributedString(
            string: text,
            attributes: [
                .font: AppFont.uiFont(size: fontSize, weight: .regular),
                .foregroundColor: UIColor(theme.text),
                .paragraphStyle: paragraphStyle,
            ]
        ))
        return result
    }
}

#Preview {
    ReaderView(route: .chapter(bookId: "mat", chapter: 5), onBack: {})
        .environmentObject(AppState())
}
