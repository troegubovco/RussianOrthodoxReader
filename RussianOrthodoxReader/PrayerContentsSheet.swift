import SwiftUI

// MARK: - «Содержание» (§7 «Пакет C» akathist_psalter_design.md)

/// Список абзацев-указаний молитвы («Кондак 1», «Икос 1», «Песнь 1» …) —
/// тулбар-кнопка `list.bullet` в `PrayerDetailView` появляется при ≥8
/// указаниях (акафист — 25–28, канон — 9). Нажатие на строку прокручивает
/// текст молитвы к этому абзацу через `onSelect`, который `PrayerDetailView`
/// подключает к своему `ScrollViewReader` (`.id("p-\(i)")` на каждом абзаце
/// `PrayerTextView`, см. правки там).
struct PrayerContentsSheet: View {
    let entries: [PrayerTextView.Paragraph]
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            onSelect(entry.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(entry.text)
                                    .font(AppFont.regular(typ.callout))
                                    .foregroundColor(theme.text)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.muted)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < entries.count - 1 {
                            Rectangle().fill(theme.border).frame(height: 0.5).padding(.leading, 20)
                        }
                    }
                }
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(16)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Содержание")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // См. комментарий у ReaderTypographySheet (PrayerDetailView.swift):
            // без этого модификатора системный заголовок листа красится по
            // Dark Mode устройства и теряется на светлом фоне.
            .toolbarColorScheme(.light, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }
}
