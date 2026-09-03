import SwiftUI

/// The fixed prayer said after each «Слава» while reading the Psalter —
/// the same three lines every time, so (unlike the kathisma texts
/// themselves) this isn't a `prayers.sqlite` entry: it's the traditional
/// Psalter rubric, hardcoded here. Opened by tapping a «Слава» divider row
/// in `ReaderView`. See akathist_psalter_design.md §6.3.
struct SlavaPrayersSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let theme = OrthodoxColors.fallback

    private static let text = """
    Сла́ва Отцу́ и Сы́ну и Свято́му Ду́ху, и ны́не и при́сно и во ве́ки веко́в. Ами́нь.

    *Трижды:*

    Аллилу́иа, аллилу́иа, аллилу́иа, сла́ва Тебе́, Бо́же.

    *Трижды:*

    Го́споди, поми́луй.

    Сла́ва Отцу́ и Сы́ну и Свято́му Ду́ху, и ны́не и при́сно и во ве́ки веко́в. Ами́нь.
    """

    var body: some View {
        NavigationStack {
            ScrollView {
                PrayerTextView(text: Self.text)
                    .padding(20)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Слава")
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
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}

#Preview {
    SlavaPrayersSheet()
}
