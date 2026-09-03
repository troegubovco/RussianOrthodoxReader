//
//  WhatsNewView.swift
//  RussianOrthodoxReader
//
//  «Что нового» — сплэш-лист, показываемый один раз после обновления
//  приложения (см. `whatsNewShownVersion` в ContentView.swift).
//

import SwiftUI

struct WhatsNewFeature: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let description: String
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private let features: [WhatsNewFeature] = [
        WhatsNewFeature(
            symbol: "book.closed",
            title: "Молитвослов",
            description: "250 молитв: утренние и вечерние, ко Причащению, каноны, акафисты, Псалтирь по кафизмам, молитвы на всякую потребу"
        ),
        WhatsNewFeature(
            symbol: "person.2",
            title: "Помянник",
            description: "Имена о здравии и о упокоении подставляются в молитвы; синхронизация через iCloud"
        ),
        WhatsNewFeature(
            symbol: "applewatch",
            title: "Apple Watch",
            description: "Моё правило, закладки и весь молитвослов на запястье"
        ),
        WhatsNewFeature(
            symbol: "magnifyingglass",
            title: "Поиск по смыслу",
            description: "«Когда болеет ребёнок», «перед экзаменом» — находит нужную молитву; поиск по Библии с переходом к стиху"
        ),
        WhatsNewFeature(
            symbol: "circle.dashed",
            title: "Планы чтения",
            description: "Акафист 40 дней, Псалтирь по кафизмам, Великий канон — с кольцом прогресса"
        ),
        WhatsNewFeature(
            symbol: "camera.viewfinder",
            title: "Распознавание икон",
            description: "Наведите камеру на икону — приложение узнает образ и покажет житие и молитву"
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ЧТО НОВОГО")
                            .font(AppFont.regular(typ.micro))
                            .foregroundColor(theme.muted)
                            .tracking(1)

                        Text("Синодал \(versionString)")
                            .font(AppFont.semiBold(typ.title))
                            .foregroundColor(theme.text)
                    }

                    VStack(spacing: 20) {
                        ForEach(features) { feature in
                            featureRow(feature)
                        }
                    }
                }
                .padding(24)
                .padding(.bottom, 16)
            }
            .background(theme.background.ignoresSafeArea())
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            #endif
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text("Продолжить")
                        .font(AppFont.medium(typ.callout))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(theme.accent)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .background(theme.background.ignoresSafeArea(edges: .bottom))
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #elseif os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    private func featureRow(_ feature: WhatsNewFeature) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: feature.symbol)
                .font(.system(size: 22))
                .foregroundColor(theme.accent)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(AppFont.bold(typ.callout))
                    .foregroundColor(theme.text)
                Text(feature.description)
                    .font(AppFont.regular(typ.footnote))
                    .foregroundColor(theme.muted)
            }

            Spacer(minLength: 0)
        }
    }
}

#Preview {
    WhatsNewView()
}
