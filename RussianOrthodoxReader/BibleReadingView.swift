// Hypothetical existing file - modify as needed
import SwiftUI

struct BibleReadingView: View {
    let chapter: BibleChapter // Assuming you have this model
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(chapter.verses) { verse in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(verse.number)")
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                        // Replace this Text with SelectableTextView for word selection
                        SelectableTextView(
                            text: verse.synodal,
                            font: AppFont.regular(typ.body),
                            textColor: theme.text,
                            backgroundColor: theme.background
                        )
                    }
                }
            }
            .padding(.horizontal, AppLayout.horizontalInset(isLandscape: false))
        }
        .background(theme.background.ignoresSafeArea())
    }
}
