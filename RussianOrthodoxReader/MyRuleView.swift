import SwiftUI

// MARK: - Карточка «Моё правило» (на корневом экране)

struct MyRuleCard: View {
    let count: Int

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "list.star")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(theme.accent)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text("Моё правило")
                    .font(AppFont.medium(typ.callout))
                    .foregroundColor(theme.text)
                Text("Молитв: \(count)")
                    .font(AppFont.regular(typ.footnote))
                    .foregroundColor(theme.muted)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Моё правило, молитв: \(count)")
    }
}

// MARK: - Экран «Моё правило»

/// Пользовательское молитвенное правило: свой набор молитв,
/// перестановка перетаскиванием, чтение подряд.
struct MyRuleView: View {
    @Binding var path: [PrayersRoute]

    @Environment(\.userFontSize) private var userFontSize
    @ObservedObject private var userData = PrayersUserDataStore.shared
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var prayers: [PrayerSummary] {
        PrayersRepository.shared.prayers(slugs: userData.myRuleSlugs).map {
            PrayerSummary(id: $0.id, slug: $0.slug, title: $0.title,
                          subtitle: $0.subtitle, takesNames: $0.takesNames)
        }
    }

    var body: some View {
        List {
            Section {
                if !userData.myRuleSlugs.isEmpty {
                    Button {
                        path.append(.myRuleRead(userData.myRuleSlugs))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "text.justify.leading")
                                .font(.system(size: 17, weight: .medium))
                            Text("Читать подряд")
                                .font(AppFont.medium(typ.callout))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(theme.accent)
                    )
                }
            }

            Section {
                ForEach(prayers) { prayer in
                    Button {
                        path.append(.prayer(slug: prayer.slug))
                    } label: {
                        HStack {
                            Text(prayer.title)
                                .font(AppFont.regular(typ.callout))
                                .foregroundColor(theme.text)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)
                        }
                    }
                    .listRowBackground(theme.card)
                }
                .onMove { source, destination in
                    userData.moveMyRule(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    for index in offsets {
                        userData.toggleMyRule(userData.myRuleSlugs[index])
                    }
                }
            } footer: {
                Text(userData.myRuleSlugs.isEmpty
                     ? "Добавляйте молитвы в своё правило кнопкой на странице молитвы."
                     : "Перетащите, чтобы изменить порядок. Свайп влево — убрать из правила.")
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Моё правило")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        #endif
        .tabBarBottomClearance()
    }
}
