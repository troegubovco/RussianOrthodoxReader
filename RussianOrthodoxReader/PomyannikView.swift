import SwiftUI

// MARK: - Помянник

struct PomyannikView: View {
    @Environment(\.userFontSize) private var userFontSize
    @ObservedObject private var userData = PrayersUserDataStore.shared
    private let theme = OrthodoxColors.fallback

    @State private var selectedList: PomyannikList = .health
    @State private var showAddSheet = false
    @State private var entryToEdit: PomyannikEntryEntity?
    @State private var entryToDelete: PomyannikEntryEntity?
    @State private var showGuidance = false

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var entries: [PomyannikEntryEntity] {
        userData.entries(in: selectedList)
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Помянник")
                        .font(AppFont.medium(typ.title))
                        .foregroundColor(theme.text)
                        .padding(.top, isLandscape ? 12 : 8)

                    PomyannikListPicker(selection: $selectedList)

                    if entries.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.uuid) { index, entry in
                                PomyannikEntryRow(
                                    entry: entry,
                                    onEdit: { entryToEdit = entry },
                                    onMove: {
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            userData.moveEntry(entry, to: entry.list == .health ? .repose : .health)
                                        }
                                    },
                                    onDelete: { entryToDelete = entry }
                                )

                                if index < entries.count - 1 {
                                    Rectangle()
                                        .fill(theme.border)
                                        .frame(height: 0.5)
                                        .padding(.leading, 20)
                                }
                            }
                        }
                        .background(theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    addButton

                    guidanceCard

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
        .sheet(isPresented: $showAddSheet) {
            PomyannikAddSheet(list: selectedList)
        }
        .sheet(item: $entryToEdit) { entry in
            PomyannikAddSheet(list: entry.list, editingEntry: entry)
        }
        .confirmationDialog(
            "Удалить имя из помянника?",
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { if !$0 { entryToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let entry = entryToDelete {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        userData.removeEntry(entry)
                    }
                }
                entryToDelete = nil
            }
            Button("Отмена", role: .cancel) { entryToDelete = nil }
        } message: {
            if let entry = entryToDelete {
                Text("«\(entry.canonicalName)» будет удалён из списка «\(entry.list.title)».")
            }
        }
    }

    private var emptyState: some View {
        Text(selectedList == .health
             ? "Добавьте имена живых,\nо ком молитесь"
             : "Добавьте имена усопших,\nо ком молитесь")
            .font(AppFont.regular(typ.footnote))
            .foregroundColor(theme.muted)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .cardStyle()
    }

    private var addButton: some View {
        Button {
            showAddSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                Text("Добавить имя")
                    .font(AppFont.medium(typ.callout))
            }
            .foregroundColor(theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showGuidance.toggle()
                }
            } label: {
                HStack {
                    Text("Как подавать записку в храме")
                        .font(AppFont.medium(typ.footnote))
                        .foregroundColor(theme.text)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.muted)
                        .rotationEffect(.degrees(showGuidance ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showGuidance {
                VStack(alignment: .leading, spacing: 8) {
                    guidanceRow("Перечисляйте имена в родительном падеже, отвечая на вопрос: о здравии или о упокоении кого? — Георгия, Фотинии.")
                    guidanceRow("Используйте полное церковное имя, данное при крещении: Иоанна (а не Ивана), Фотинии (а не Светланы).")
                    guidanceRow("Фамилии, отчества и мирские звания не пишутся.")
                    guidanceRow("«О здравии» подаётся о живых, «О упокоении» — об усопших. О некрещёных записки не подают.")
                    guidanceRow("Перед именем можно указать: болящего, путешествующего, воина; об усопших — новопреставленного (до 40 дней) или приснопамятного.")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func guidanceRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.accent)
            Text(text)
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Переключатель списков

struct PomyannikListPicker: View {
    @Binding var selection: PomyannikList

    @Environment(\.userFontSize) private var userFontSize

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        SlidingSegmentedControl(
            segments: PomyannikList.allCases.map { .init(value: $0, title: $0.title) },
            selection: $selection,
            font: AppFont.regular(typ.footnote)
        )
    }
}

// MARK: - Строка записи

private struct PomyannikEntryRow: View {
    let entry: PomyannikEntryEntity
    let onEdit: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var statusGenitive: String? {
        entry.status
            .flatMap(PomyannikStatus.init(rawValue:))
            .map { $0.genitive(for: entry.gender) }
    }

    /// «болящего Георгия» — как писать в записке.
    private var noteLine: String {
        if let statusGenitive {
            return "\(statusGenitive) \(entry.canonicalGen)"
        }
        return entry.canonicalGen
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(noteLine)
                    .font(AppFont.medium(typ.callout))
                    .foregroundColor(theme.text)

                if entry.inputName.lowercased() != entry.canonicalName.lowercased() {
                    Text("\(entry.inputName) → \(entry.canonicalName)")
                        .font(AppFont.regular(typ.caption))
                        .foregroundColor(theme.muted)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button(action: onEdit) {
                    Label("Изменить", systemImage: "pencil")
                }
                Button(action: onMove) {
                    Label(entry.list == .health
                          ? "Перенести в «О упокоении»"
                          : "Перенести в «О здравии»",
                          systemImage: "arrow.left.arrow.right")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Удалить", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(theme.muted)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Действия с именем \(entry.canonicalName)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

#Preview {
    NavigationStack {
        PomyannikView()
    }
    .environmentObject(AppState())
}
