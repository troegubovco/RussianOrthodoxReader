#if os(iOS)
import SwiftUI
import UIKit

/// Full detail screen for a single recognized/suggested icon subject —
/// compare strip, title, alternatives, житие, история, молитвы.
struct IconSubjectDetailView: View {
    let userImage: UIImage?
    let match: IconMatch
    var showsMatchPercent: Bool = false
    var alternatives: [IconMatch] = []
    /// Only true when this view is the ROOT of `IconResultView` (the `.recognized`
    /// case) — pushed detail screens never repeat the attribution line.
    var showsAttribution: Bool = false

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private struct Loaded {
        let subject: IconSubjectInfo?
        let life: IconLifeEntry?
        let history: IconHistoryEntry?
        let prayers: [IconPrayerEntry]
    }

    @State private var loaded: Loaded?
    @State private var expandedPrayers: Set<Int> = []
    @State private var expandedTranslations: Set<Int> = []

    private var typ: AppTypography { AppTypography.iconScreen(userFontSize: userFontSize) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                compareStrip

                titleBlock

                if !alternatives.isEmpty {
                    alternativesSection
                }

                if let loaded {
                    if let life = loaded.life {
                        CollapsibleTextSection(title: "Житие", text: life.life, source: life.source)
                    }

                    if let history = loaded.history {
                        CollapsibleTextSection(title: "История иконы", text: history.history, source: history.source)
                    }

                    if !loaded.prayers.isEmpty {
                        prayersSection(loaded.prayers)
                    }

                    if let azbykaURL = loaded.subject?.azbykaURL, let url = URL(string: azbykaURL) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Text("Открыть на azbyka.ru")
                                Image(systemName: "arrow.up.right.square")
                            }
                            .font(AppFont.regular(typ.footnote))
                            .foregroundColor(theme.accent)
                        }
                    }

                    if loaded.life == nil && loaded.history == nil && loaded.prayers.isEmpty {
                        Text("Тексты для этого образа пока не добавлены в оффлайн базу.")
                            .font(AppFont.regular(typ.footnote))
                            .foregroundColor(theme.muted)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }

                if showsAttribution {
                    IconAttributionLine()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: match.iconId) {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        let repository = IconMetaRepository.shared
        let id = match.iconId
        let value = await Task.detached(priority: .userInitiated) {
            Loaded(
                subject: repository.subject(iconId: id),
                life: repository.life(iconId: id),
                history: repository.history(iconId: id),
                prayers: repository.prayers(iconId: id)
            )
        }.value
        loaded = value
        expandedPrayers = value.prayers.count == 1 ? Set(value.prayers.map(\.id)) : []
    }

    // MARK: - Compare strip

    @ViewBuilder
    private var compareStrip: some View {
        if let userImage {
            HStack(alignment: .top, spacing: 12) {
                compareTile(caption: "Ваше фото") {
                    Image(uiImage: userImage)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                }
                compareTile(caption: "Образец") {
                    IconThumbnailView(iconId: match.iconId)
                        .padding(6)
                }
            }
        } else {
            HStack {
                Spacer()
                compareTile(caption: "Образец") {
                    IconThumbnailView(iconId: match.iconId)
                        .padding(6)
                }
                .frame(maxWidth: 180)
                Spacer()
            }
        }
    }

    private func compareTile<Content: View>(caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.fastBackground)
                .frame(height: 132)
                .overlay(content())
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(caption)
                .font(AppFont.regular(typ.micro))
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Title block

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loaded?.subject?.name ?? match.name)
                .font(AppFont.medium(typ.headline))
                .foregroundColor(theme.text)

            if showsMatchPercent {
                Text("Совпадение: \(Int(match.score * 100))%")
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
            }

            if let category = loaded?.subject?.category, let label = categoryLabel(category) {
                Text(label)
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.accent)
            }

            if let feastDays = loaded?.subject?.feastDays, !feastDays.isEmpty {
                Text("Память: \(feastDays.joined(separator: ", "))")
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
            }
        }
    }

    private func categoryLabel(_ category: String) -> String? {
        switch category {
        case "saints": return nil
        case "theotokos": return "Богородичная икона"
        case "christ": return "Образ Спасителя"
        case "angels": return "Ангельский чин"
        default: return nil
        }
    }

    // MARK: - Alternatives

    private var alternativesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Не она? Возможно:")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)

            HStack(spacing: 12) {
                ForEach(alternatives.prefix(2)) { alt in
                    NavigationLink(value: alt) {
                        VStack(alignment: .leading, spacing: 6) {
                            IconThumbnailView(iconId: alt.iconId)
                                .frame(width: 54, height: 70)
                            Text(alt.name)
                                .font(AppFont.regular(typ.caption))
                                .foregroundColor(theme.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Prayers

    private func prayersSection(_ prayers: [IconPrayerEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Молитвы").sectionHeader()

            ForEach(prayers) { prayer in
                prayerCard(prayer)
            }
        }
    }

    private func prayerCard(_ prayer: IconPrayerEntry) -> some View {
        let isExpanded = expandedPrayers.contains(prayer.id)
        let showsTranslation = expandedTranslations.contains(prayer.id)

        return VStack(spacing: 12) {
            Button {
                if isExpanded {
                    expandedPrayers.remove(prayer.id)
                } else {
                    expandedPrayers.insert(prayer.id)
                }
            } label: {
                HStack {
                    Text(prayerTitle(prayer))
                        .font(AppFont.medium(typ.subheadline))
                        .foregroundColor(theme.accent)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.muted)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(liturgicalLines(prayer.body))
                    .font(AppFont.regular(typ.body))
                    .foregroundColor(theme.text)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let translation = prayer.translation {
                    Divider().background(theme.border)

                    Button {
                        if showsTranslation {
                            expandedTranslations.remove(prayer.id)
                        } else {
                            expandedTranslations.insert(prayer.id)
                        }
                    } label: {
                        Text(showsTranslation ? "Скрыть перевод" : "Перевод")
                            .font(AppFont.medium(typ.footnote))
                            .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if showsTranslation {
                        Text(translation)
                            .font(AppFont.italic(typ.callout))
                            .foregroundColor(theme.muted)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func prayerTitle(_ p: IconPrayerEntry) -> String {
        guard let glas = p.glas, !glas.isEmpty else { return p.kind }
        return "\(p.kind), \(glas)"
    }

    private func liturgicalLines(_ s: String) -> String {
        s.replacingOccurrences(of: "//", with: "\n")
         .replacingOccurrences(of: "/", with: "\n")
         .split(separator: "\n", omittingEmptySubsequences: false)
         .map { $0.trimmingCharacters(in: .whitespaces) }
         .filter { !$0.isEmpty }
         .joined(separator: "\n")
    }
}

// MARK: - Collapsible long-form text (Житие / История иконы)

private struct CollapsibleTextSection: View {
    let title: String
    let text: String
    let source: String              // "azbyka" | "pravicon"

    @Environment(\.userFontSize) private var userFontSize
    @State private var expanded = false
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography.iconScreen(userFontSize: userFontSize) }

    private var sourceLabel: String {
        switch source {
        case "azbyka": return "azbyka.ru"
        case "pravicon": return "pravicon.com"
        default: return source
        }
    }

    private var previewText: String {
        guard text.count > 260 else { return text }
        let cut = text.prefix(220)
        let end = cut.lastIndex(where: { $0.isWhitespace }) ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).sectionHeader()
                Spacer()
                Text(sourceLabel)
                    .font(AppFont.regular(typ.micro))
                    .foregroundColor(theme.muted.opacity(0.6))
            }

            Text(expanded ? text : previewText)
                .font(AppFont.regular(typ.body))
                .foregroundColor(theme.text)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .bottom) {
                    if !expanded && previewText.count < text.count {
                        LinearGradient(colors: [theme.background.opacity(0), theme.background],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 48)
                            .allowsHitTesting(false)
                    }
                }

            if previewText.count < text.count {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "Свернуть" : "Читать далее")
                        .font(AppFont.medium(typ.footnote))
                        .foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
    }
}
#endif
