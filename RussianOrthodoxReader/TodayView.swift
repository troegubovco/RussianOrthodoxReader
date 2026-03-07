import SwiftUI

// MARK: - Reading group helper (for .other / extra readings)

struct ExtraReadingGroup: Identifiable {
    let id: String          // = displayRef (unique per scripture range)
    let sourceLabel: String // e.g. "6th Hour", "Vespers"
    let displayRef: String  // e.g. "Isaiah 2.11-21"
    let references: [ReadingReference]

    /// Collapses references into unique displayRef groups, preserving ordinal order.
    static func grouped(from refs: [ReadingReference]) -> [ExtraReadingGroup] {
        var seen: Set<String> = []
        var groups: [ExtraReadingGroup] = []
        for ref in refs {
            guard !seen.contains(ref.displayRef) else { continue }
            seen.insert(ref.displayRef)
            let matching = refs.filter { $0.displayRef == ref.displayRef }
            groups.append(ExtraReadingGroup(
                id: ref.displayRef,
                sourceLabel: ref.sourceLabel,
                displayRef: ref.displayRef,
                references: matching
            ))
        }
        return groups
    }

    /// Maps the API's English `source` strings to Russian display labels.
    static func russianSourceLabel(_ source: String) -> String {
        let s = source.lowercased()
        if s.contains("liturgy")       { return "Литургия" }
        if s.contains("matins gospel") { return "Утреннее Евангелие" }
        if s.contains("matins")        { return "Утреня" }
        if s.contains("vespers")       { return "Вечерня" }
        if s.contains("6th hour")      { return "6-й час" }
        if s.contains("3rd hour")      { return "3-й час" }
        if s.contains("9th hour")      { return "9-й час" }
        if s.contains("1st hour")      { return "1-й час" }
        if s.contains("compline")      { return "Повечерие" }
        if s.isEmpty                   { return "Чтение" }
        return "Чтение"
    }
}

// MARK: - TodayView

struct TodayView: View {
    let onOpenReading: (ReaderRoute) -> Void

    @Environment(\.userFontSize) private var userFontSize
    @StateObject private var viewModel = TodayViewModel()
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter
    }()

    private var formattedDate: String {
        let s = Self.dateFormatter.string(from: viewModel.day?.date ?? Date())
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Сегодня")
                            .sectionHeader()

                        Text(formattedDate)
                            .font(AppFont.medium(typ.title))
                            .foregroundColor(theme.text)

                        if let data = viewModel.day, data.isFastDay {
                            Text(data.fastingLevel.rawValue)
                                .font(AppFont.regular(typ.caption))
                                .foregroundColor(theme.fastText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(theme.fastBackground))
                        }

                        if viewModel.day?.isFromCache == true {
                            Text("Оффлайн кеш")
                                .font(AppFont.regular(typ.caption))
                                .foregroundColor(theme.muted)
                        }
                    }
                    .padding(.top, isLandscape ? 12 : 8)

                    if let data = viewModel.day {
                        readingsCard(for: data)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Память")
                                .sectionHeader()

                            Text(data.saintOfDay)
                                .font(AppFont.regular(typ.body))
                                .foregroundColor(theme.text)
                                .lineSpacing(4)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()

                        if let tone = data.tone {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Глас")
                                    .sectionHeader()

                                Text("\(tone)")
                                    .font(AppFont.semiBold(typ.callout))
                                    .foregroundColor(theme.accent)
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle()
                        }
                    } else if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.background.ignoresSafeArea())
        .task {
            await viewModel.loadToday()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                await viewModel.prefetch()
            }
        }
    }

    // MARK: - Readings card

    @ViewBuilder
    private func readingsCard(for data: LiturgicalDay) -> some View {
        let rows = buildReadingRows(for: data)

        VStack(alignment: .leading, spacing: 0) {
            Text("Чтения дня")
                .sectionHeader()
                .padding(.bottom, 16)

            if rows.isEmpty {
                Text("В этот день особые чтения не указаны")
                    .font(AppFont.regular(typ.footnote))
                    .foregroundColor(theme.muted)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().background(theme.border)
                    }
                    ReadingButton(
                        label: row.label,
                        reference: row.reference,
                        isEnabled: row.isEnabled
                    ) {
                        onOpenReading(.references(title: row.label, references: row.references))
                    }
                }
            }
        }
        .padding(24)
        .cardStyle()
    }

    // MARK: - Row model

    private struct ReadingRow: Identifiable {
        let id: String
        let label: String
        let reference: String
        let isEnabled: Bool
        let references: [ReadingReference]
    }

    private func buildReadingRows(for data: LiturgicalDay) -> [ReadingRow] {
        var rows: [ReadingRow] = []

        if data.apostolReading != "—" {
            rows.append(ReadingRow(
                id: "apostol",
                label: "Апостол",
                reference: data.apostolReading,
                isEnabled: !data.apostolReferences.isEmpty,
                references: data.apostolReferences
            ))
        }

        if data.gospelReading != "—" {
            rows.append(ReadingRow(
                id: "gospel",
                label: "Евангелие",
                reference: data.gospelReading,
                isEnabled: !data.gospelReferences.isEmpty,
                references: data.gospelReferences
            ))
        }

        for group in ExtraReadingGroup.grouped(from: data.extraReferences) {
            rows.append(ReadingRow(
                id: group.id,
                label: ExtraReadingGroup.russianSourceLabel(group.sourceLabel),
                reference: group.displayRef,
                isEnabled: true,
                references: group.references
            ))
        }

        return rows
    }

}

// MARK: - ReadingButton

struct ReadingButton: View {
    let label: String
    let reference: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)

                    Text(reference)
                        .font(AppFont.medium(typ.callout))
                        .foregroundColor(theme.text)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .foregroundColor(isEnabled ? theme.accent : theme.muted)
                    .font(.system(size: 16, weight: .medium))
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(label): \(reference)")
        .accessibilityHint(isEnabled ? "Нажмите, чтобы прочитать" : "Отрывок недоступен в оффлайне")
    }
}

#Preview {
    TodayView(onOpenReading: { _ in })
        .environmentObject(AppState())
}
