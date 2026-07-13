import SwiftUI

/// Добавление имени в помянник (и редактирование существующей записи):
/// светское имя → церковное имя в родительном падеже, с живым предпросмотром.
struct PomyannikAddSheet: View {
    let list: PomyannikList
    /// Запись для редактирования; nil — добавление нового имени.
    var editingEntry: PomyannikEntryEntity?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    @ObservedObject private var userData = PrayersUserDataStore.shared
    private let theme = OrthodoxColors.fallback

    @State private var inputName = ""
    @State private var matches: [ChurchNameMatch] = []
    @State private var selectedMatchID: Int?
    @State private var gender: PersonGender = .male
    @State private var genderPickedManually = false
    @State private var status: PomyannikStatus?
    // Ручное редактирование форм (для имён, склонённых правилами)
    @State private var editedCanonical: String?
    @State private var editedGenitive: String?

    init(list: PomyannikList, editingEntry: PomyannikEntryEntity? = nil) {
        self.list = list
        self.editingEntry = editingEntry
        guard let entry = editingEntry else { return }
        let found = ChurchNamesRepository.shared.matches(for: entry.inputName)
        let matching = found.first {
            $0.canonical == entry.canonicalName && $0.gender == entry.gender
        }
        _inputName = State(initialValue: entry.inputName)
        _matches = State(initialValue: found)
        _selectedMatchID = State(initialValue: matching?.id)
        _gender = State(initialValue: entry.gender)
        _genderPickedManually = State(initialValue: true)
        _status = State(initialValue: entry.status.flatMap(PomyannikStatus.init(rawValue:)))
        // Если сохранённые формы не совпадают с базой — это ручные правки,
        // сохраняем их как переопределения.
        if matching == nil || matching?.genitive != entry.canonicalGen {
            _editedCanonical = State(initialValue: entry.canonicalName)
            _editedGenitive = State(initialValue: entry.canonicalGen)
        }
    }

    private var isEditing: Bool { editingEntry != nil }

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var selectedMatch: ChurchNameMatch? {
        guard !matches.isEmpty else { return nil }
        return matches.first(where: { $0.id == selectedMatchID }) ?? matches.first
    }

    /// Склонение по правилам — когда имени нет в базе.
    private var fallbackDeclined: DeclinedName? {
        RussianNameDecliner.decline(inputName, gender: gender)
    }

    private var isRuleDerived: Bool { selectedMatch == nil && fallbackDeclined != nil }

    private var canonicalName: String {
        if let editedCanonical { return editedCanonical }
        if let match = selectedMatch { return match.canonical }
        return fallbackDeclined?.nominative ?? inputName.trimmingCharacters(in: .whitespaces)
    }

    private var genitiveName: String {
        if let editedGenitive { return editedGenitive }
        if let match = selectedMatch { return match.genitive }
        return fallbackDeclined?.genitive ?? inputName.trimmingCharacters(in: .whitespaces)
    }

    private var accusativeName: String {
        // Ручные правки форм имеют приоритет — винительный строим от них.
        if editedCanonical != nil || editedGenitive != nil {
            return RussianNameDecliner.decline(canonicalName, gender: effectiveGender)?
                .accusative ?? canonicalName
        }
        if let match = selectedMatch { return match.accusative }
        return fallbackDeclined?.accusative ?? canonicalName
    }

    private var effectiveGender: PersonGender {
        if genderPickedManually { return gender }
        return selectedMatch?.gender ?? gender
    }

    private var canSave: Bool {
        !inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !canonicalName.isEmpty && !genitiveName.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameField

                    if !inputName.trimmingCharacters(in: .whitespaces).isEmpty {
                        previewCard

                        if matches.count > 1 {
                            alternativesSection
                        }

                        if selectedMatch == nil {
                            genderPicker
                        }

                        statusSection
                    }
                }
                .padding(24)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(isEditing ? "Изменить"
                             : (list == .health ? "О здравии" : "О упокоении"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Сохранить" : "Добавить") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    // MARK: - Поле ввода

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Имя")
                .sectionHeader()

            TextField("Например: Егор", text: $inputName)
                .font(AppFont.regular(typ.body))
                .foregroundColor(theme.text)
                .textFieldStyle(.plain)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.card)
                )
                .autocorrectionDisabled()
                .onChange(of: inputName) { _, newValue in
                    matches = ChurchNamesRepository.shared.matches(for: newValue)
                    selectedMatchID = matches.first?.id
                    editedCanonical = nil
                    editedGenitive = nil
                    if !genderPickedManually {
                        gender = matches.first?.gender
                            ?? RussianNameDecliner.guessGender(newValue)
                    }
                    if let status, !PomyannikStatus.statuses(for: list).contains(status) {
                        self.status = nil
                    }
                }
        }
    }

    // MARK: - Предпросмотр

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if canonicalName.lowercased() != inputName.trimmingCharacters(in: .whitespaces).lowercased() {
                HStack(spacing: 8) {
                    Text(inputName.trimmingCharacters(in: .whitespaces))
                        .font(AppFont.regular(typ.callout))
                        .foregroundColor(theme.muted)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.muted)
                    Text(canonicalName)
                        .font(AppFont.medium(typ.callout))
                        .foregroundColor(theme.text)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("В записке:")
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)

                Text(recordLine)
                    .font(AppFont.semiBold(typ.callout))
                    .foregroundColor(theme.accent)
            }

            if let note = selectedMatch?.note {
                Text(note)
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isRuleDerived || isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    if isRuleDerived {
                        Label("Форма построена автоматически — проверьте", systemImage: "exclamationmark.triangle")
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.fastText)
                    } else {
                        Text("Форма в записке (родительный падеж):")
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                    }

                    TextField("Родительный падеж", text: Binding(
                        get: { genitiveName },
                        set: { editedGenitive = $0 }
                    ))
                    .font(AppFont.regular(typ.footnote))
                    .foregroundColor(theme.text)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.background)
                    )
                    .autocorrectionDisabled()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var recordLine: String {
        let statusPart = status.map { "\($0.genitive(for: effectiveGender)) " } ?? ""
        return statusPart + genitiveName
    }

    // MARK: - Альтернативы

    private var alternativesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Варианты")
                .sectionHeader()

            VStack(spacing: 8) {
                ForEach(matches) { match in
                    Button {
                        selectedMatchID = match.id
                        editedCanonical = nil
                        editedGenitive = nil
                        if !genderPickedManually { gender = match.gender }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.canonical)
                                    .font(AppFont.medium(typ.footnote))
                                    .foregroundColor(theme.text)
                                Text(match.gender == .male ? "мужское имя" : "женское имя")
                                    .font(AppFont.regular(typ.caption))
                                    .foregroundColor(theme.muted)
                            }
                            Spacer()
                            if selectedMatch?.id == match.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(theme.accent)
                            }
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(theme.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selectedMatch?.id == match.id
                                              ? theme.accent.opacity(0.5) : .clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Пол

    private var genderPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Пол")
                .sectionHeader()

            SlidingSegmentedControl(
                segments: [
                    .init(value: PersonGender.male, title: "Мужское"),
                    .init(value: PersonGender.female, title: "Женское")
                ],
                selection: Binding(
                    get: { gender },
                    set: { newValue in
                        gender = newValue
                        genderPickedManually = true
                        editedGenitive = nil
                    }
                ),
                font: AppFont.regular(typ.footnote)
            )
        }
    }

    // MARK: - Статус

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Уточнение (необязательно)")
                .sectionHeader()

            FlowChips(
                statuses: PomyannikStatus.statuses(for: list),
                gender: effectiveGender,
                selection: $status
            )
        }
    }

    // MARK: - Сохранение

    private func save() {
        let trimmedInput = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editingEntry {
            userData.updateEntry(
                editingEntry,
                inputName: trimmedInput,
                canonicalName: canonicalName,
                canonicalGen: genitiveName,
                canonicalAcc: accusativeName,
                gender: effectiveGender,
                status: status?.rawValue
            )
        } else {
            userData.addEntry(
                list: list,
                inputName: trimmedInput,
                canonicalName: canonicalName,
                canonicalGen: genitiveName,
                canonicalAcc: accusativeName,
                gender: effectiveGender,
                status: status?.rawValue
            )
        }
        dismiss()
    }
}

// MARK: - Чипы статусов

private struct FlowChips: View {
    let statuses: [PomyannikStatus]
    let gender: PersonGender
    @Binding var selection: PomyannikStatus?

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        FlexibleWrap(spacing: 8) {
            ForEach(statuses) { status in
                let isSelected = selection == status
                Button {
                    selection = isSelected ? nil : status
                } label: {
                    Text(status.title(for: gender))
                        .font(AppFont.regular(typ.caption))
                        .foregroundColor(isSelected ? .white : theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(isSelected ? theme.accent : theme.card)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Простая обёртка-«поток»: располагает элементы по строкам.
private struct FlexibleWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    PomyannikAddSheet(list: .health)
        .environmentObject(AppState())
}
