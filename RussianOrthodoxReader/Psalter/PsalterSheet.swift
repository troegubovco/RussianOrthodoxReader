import SwiftUI

/// «Псалтирь по кафизмам» — 20 rows, each expandable into its three «Славы»,
/// plus the opening/closing Psalter prayers. Opened from `BibleView`'s
/// `PsalterCard`. `BibleView` isn't inside a `NavigationStack`, so — like its
/// existing chapter picker — this sheet reports the selection outward via a
/// closure and dismisses itself, rather than pushing.
///
/// See akathist_psalter_design.md §6.
struct PsalterSheet: View {
    /// (kathisma number, target «Слава» 1...3, or `nil` to open the whole
    /// kathisma from its first psalm).
    let onSelectKathisma: (Int, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    @State private var expandedKathismas: Set<Int> = []
    @State private var showOpeningPrayers = false
    @State private var showClosingPrayers = false
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    bookendRow("Молитвы перед чтением Псалтири") { showOpeningPrayers = true }

                    VStack(spacing: 6) {
                        ForEach(KathismaTable.all, id: \.number) { kathisma in
                            kathismaRow(kathisma)
                        }
                    }

                    bookendRow("Молитвы по окончании") { showClosingPrayers = true }
                }
                .padding(16)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Псалтирь по кафизмам")
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
        .sheet(isPresented: $showOpeningPrayers) {
            PsalterPrayerSheet(
                title: "Молитвы перед чтением Псалтири",
                text: PrayersRepository.shared.prayer(slug: "psaltir.molitvy-pered-chteniem")?.textCS
            )
        }
        .sheet(isPresented: $showClosingPrayers) {
            PsalterPrayerSheet(
                title: "Молитвы по окончании",
                text: PrayersRepository.shared.prayer(slug: "psaltir.molitvy-po-prochtenii")?.textCS
            )
        }
    }

    private func bookendRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(AppFont.regular(typ.footnote))
                    .foregroundColor(theme.accent)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func kathismaRow(_ kathisma: KathismaTable.Kathisma) -> some View {
        let isExpanded = expandedKathismas.contains(kathisma.number)
        return VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: Binding(
                get: { isExpanded },
                set: { newValue in
                    if newValue { expandedKathismas.insert(kathisma.number) }
                    else { expandedKathismas.remove(kathisma.number) }
                }
            )) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(kathisma.slavas.enumerated()), id: \.offset) { index, slava in
                        Button {
                            onSelectKathisma(kathisma.number, index + 1)
                            dismiss()
                        } label: {
                            HStack {
                                Text("Слава \(index + 1) · \(slava.label)")
                                    .font(AppFont.regular(typ.footnote))
                                    .foregroundColor(theme.text)
                                Spacer()
                            }
                            .padding(.vertical, 9)
                            .padding(.leading, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            } label: {
                Button {
                    onSelectKathisma(kathisma.number, nil)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Кафизма \(kathisma.number)")
                            .font(AppFont.medium(typ.subheadline))
                            .foregroundColor(theme.text)
                        Text(kathisma.psalmsLabel)
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .tint(theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card))
    }
}

/// Generic modal for a Church-Slavonic Psalter text sourced from the
/// молитвослов: the opening/closing Psalter prayers, a whole `psaltir.kafizma-N`
/// (the reader's «ЦС» button), or an already-extracted trailing block (the
/// reader's «Молитвы по кафизме» button). `text == nil` — slug missing, or
/// (for the trailing-block case) the rubric wasn't found — shows a
/// «Текст появится после обновления» note instead: content ingestion for
/// `psaltir` is still in progress (see akathist_psalter_design.md §7 Package A).
struct PsalterPrayerSheet: View {
    let title: String
    let text: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let text {
                    PrayerTextView(text: text)
                        .padding(20)
                } else {
                    Text("Текст появится после обновления")
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(title)
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
        .presentationDetents([.medium, .large])
        #endif
    }
}

#Preview {
    PsalterSheet(onSelectKathisma: { _, _ in })
}
