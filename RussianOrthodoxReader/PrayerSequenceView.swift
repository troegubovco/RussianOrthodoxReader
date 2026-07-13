import SwiftUI

/// Сквозное чтение категории-последования (утренние, вечерние, ко Причащению):
/// все молитвы подряд, как в печатном молитвослове, с заголовками разделов.
struct PrayerSequenceView: View {
    let navTitle: String
    private let fetch: () -> [Prayer]

    init(category: PrayerCategory) {
        self.navTitle = category.title
        self.fetch = { PrayersRepository.shared.fullPrayers(inCategory: category.slug) }
    }

    init(title: String, slugs: [String]) {
        self.navTitle = title
        self.fetch = { PrayersRepository.shared.prayers(slugs: slugs) }
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    @State private var prayers: [Prayer] = []
    @State private var showTypography = false
    @AppStorage("prayerLanguage") private var languageRaw = PrayerLanguage.churchSlavonic.rawValue
    @AppStorage("prayerShowStress") private var showStress = true

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var language: PrayerLanguage {
        PrayerLanguage(rawValue: languageRaw) ?? .churchSlavonic
    }

    /// Перевод показываем, только если он есть у всех молитв последования.
    private var hasFullTranslation: Bool {
        !prayers.isEmpty && prayers.allSatisfy { $0.textRU != nil }
    }

    private func displayText(for prayer: Prayer) -> String {
        let base: String
        switch language {
        case .russian where prayer.textRU != nil:
            base = prayer.textRU ?? prayer.textCS
        default:
            base = prayer.textCS
        }
        return showStress ? base : StressMarks.strip(base)
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(navTitle)
                        .font(AppFont.medium(typ.title))
                        .foregroundColor(theme.text)
                        .padding(.top, isLandscape ? 12 : 8)

                    if hasFullTranslation {
                        SlidingSegmentedControl(
                            segments: PrayerLanguage.allCases.map {
                                .init(value: $0.rawValue, title: $0.shortTitle)
                            },
                            selection: $languageRaw,
                            font: AppFont.regular(typ.footnote)
                        )
                    }

                    ForEach(prayers) { prayer in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(prayer.title)
                                .font(AppFont.semiBold(typ.callout))
                                .foregroundColor(theme.accent)
                                .lineSpacing(4)
                                .padding(.top, 8)

                            PrayerTextView(text: displayText(for: prayer))
                        }
                    }

                    Spacer(minLength: 32)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableContentWidth()
                .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
            }
            .tabBarBottomClearance()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.background.ignoresSafeArea())
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTypography = true
                } label: {
                    Image(systemName: "textformat.size")
                        .foregroundColor(theme.accent)
                }
                .accessibilityLabel("Настройки текста")
            }
        }
        .sheet(isPresented: $showTypography) {
            ReaderTypographySheet(showStress: $showStress)
                .environmentObject(appState)
        }
        .prayerSearchToolbar()
        .task {
            if prayers.isEmpty {
                prayers = fetch()
            }
        }
    }
}
