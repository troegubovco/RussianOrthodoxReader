import SwiftUI

struct BibleReadingView: View {
    let chapter: BibleChapter
    @Environment(\.userFontSize) private var userFontSize
    @State private var selectedWord: String?

    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(chapter.verses) { verse in
                    let paragraphStyle = NSMutableParagraphStyle()
                    let _ = paragraphStyle.lineSpacing = typ.body * 0.4

                    SelectableTextView(
                        attributedText: {
                            let result = NSMutableAttributedString(
                                string: "\(verse.number) ",
                                attributes: [
                                    .font: AppFont.platformFont(size: typ.body - 4, weight: .bold),
                                    .foregroundColor: PlatformColor(theme.accent),
                                    .paragraphStyle: paragraphStyle,
                                ]
                            )
                            result.append(NSAttributedString(
                                string: verse.synodal,
                                attributes: [
                                    .font: AppFont.platformFont(size: typ.body, weight: .regular),
                                    .foregroundColor: PlatformColor(theme.text),
                                    .paragraphStyle: paragraphStyle,
                                ]
                            ))
                            return result
                        }(),
                        backgroundColor: PlatformColor(theme.background),
                        onWordSelected: { word in
                            selectedWord = word
                        }
                    )
                }
            }
            .padding(.horizontal, AppLayout.horizontalInset(isLandscape: false))
        }
        .background(theme.background.ignoresSafeArea())
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
}
