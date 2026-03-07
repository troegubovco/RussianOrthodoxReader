import SwiftUI
import UIKit

struct ReaderView: View {
    let route: ReaderRoute
    let onBack: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
    @StateObject private var viewModel = ReaderViewModel()
    @State private var showDictionary = false
    @State private var selectedWord: String?

    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            VStack(spacing: 0) {
                readerHeader(isLandscape: isLandscape)

                ScrollViewReader { proxy in
                    ScrollView {
                        if viewModel.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 32)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                if viewModel.hasPreviousChapter {
                                    Button {
                                        let oldFirstID = viewModel.sections.first?.id
                                        viewModel.loadPreviousChapter()
                                        if let oldFirstID {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                proxy.scrollTo(oldFirstID, anchor: .top)
                                            }
                                        }
                                    } label: {
                                        Text("Загрузить предыдущую главу")
                                            .font(AppFont.regular(typ.footnote))
                                            .foregroundColor(theme.accent)
                                            .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                }

                                ForEach(viewModel.sections) { section in
                                    sectionView(section)
                                        .id(section.id)
                                        .onAppear {
                                            viewModel.loadNextChapterIfNeeded(after: section)
                                        }
                                }

                                if viewModel.hasNextChapter {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text("Подгружаем следующую главу")
                                            .font(AppFont.regular(typ.caption))
                                            .foregroundColor(theme.muted)
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                            .padding(.top, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
                            .padding(.bottom, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
                        }
                    }
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .task(id: route.id) {
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
