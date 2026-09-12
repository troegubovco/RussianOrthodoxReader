import SwiftUI

// MARK: - Экран молитвы

struct PrayerDetailView: View {
    let slug: String

    @EnvironmentObject private var appState: AppState
    @Environment(\.userFontSize) private var userFontSize
    @ObservedObject private var userData = PrayersUserDataStore.shared
    /// Наблюдаем за планами здесь (а не только внутри `ReadingPlanCard`) —
    /// нижняя часть экрана переключается между кнопкой «Прочитано сегодня» и
    /// строкой «Читать ежедневно →» в зависимости от того, есть ли план, и
    /// это решение принимает сам `PrayerDetailView` (§5.2 akathist_psalter_design.md).
    @ObservedObject private var plansStore = ReadingPlansStore.shared
    private let theme = OrthodoxColors.fallback

    @State private var prayer: Prayer?
    @State private var showNamePicker = false
    @State private var showTypography = false
    @State private var showPlanSetup = false
    @State private var showContents = false
    /// Индекс абзаца (см. `PrayerTextView.Paragraph.id`), к которому нужно
    /// прокрутить после выбора указания в `PrayerContentsSheet`.
    @State private var scrollToParagraph: Int?
    /// nil — выбраны все имена соответствующего списка помянника.
    @State private var selectedNameUUIDs: Set<String>?
    @AppStorage("prayerLanguage") private var languageRaw = PrayerLanguage.churchSlavonic.rawValue
    @AppStorage("prayerShowStress") private var showStress = true

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var language: PrayerLanguage {
        PrayerLanguage(rawValue: languageRaw) ?? .churchSlavonic
    }

    /// Записи помянника, доступные для этой молитвы.
    private var availableEntries: [PomyannikEntryEntity] {
        guard let prayer, prayer.takesNames, let list = prayer.nameList else { return [] }
        return userData.entries(in: list)
    }

    /// Выбранные записи (по умолчанию — весь список).
    private var selectedEntries: [PomyannikEntryEntity] {
        guard let selectedNameUUIDs else { return availableEntries }
        return availableEntries.filter { selectedNameUUIDs.contains($0.uuid) }
    }

    private var namesToInsert: [PrayerTemplateRenderer.NameToInsert] {
        guard let prayer else { return [] }
        return selectedEntries.map { entry in
            let declined: String
            switch prayer.nameCase {
            case .accusative: declined = entry.canonicalAcc
            case .genitive, nil: declined = entry.canonicalGen
            }
            return PrayerTemplateRenderer.NameToInsert(
                declined: declined,
                gender: entry.gender
            )
        }
    }

    private var displayText: String {
        guard let prayer else { return "" }
        var base: String
        switch language {
        case .russian where prayer.textRU != nil:
            base = prayer.textRU ?? prayer.textCS
        default:
            base = prayer.textCS
        }
        if prayer.takesNames {
            base = PrayerTemplateRenderer.render(base, names: namesToInsert)
        }
        return showStress ? base : StressMarks.strip(base)
    }

    /// Активный план по этой молитве (либо по семейству — кафизма/часть
    /// канона, см. `ReadingPlansStore.plan(forTarget:)`), если есть.
    private var planSnapshot: ReadingPlanSnapshot? {
        guard let prayer else { return nil }
        return plansStore.plan(forTarget: prayer.slug)
    }

    /// Абзацы-указания текущего текста — порог показа кнопки «Содержание»
    /// (≥8) и содержимое `PrayerContentsSheet`.
    private var rubricParagraphs: [PrayerTextView.Paragraph] {
        PrayerTextView.rubricParagraphs(in: displayText)
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let prayer {
                            Text(prayer.title)
                                .font(AppFont.semiBold(typ.prayerTitle))
                                .foregroundColor(theme.text)
                                .lineSpacing(4)
                                .padding(.top, isLandscape ? 12 : 8)

                            ReadingPlanCard(prayer: prayer)

                            if prayer.textRU != nil {
                                PrayerLanguagePicker(selection: $languageRaw)
                            }

                            if prayer.takesNames {
                                namesBar
                            }

                            PrayerTextView(text: displayText)
                                .padding(.bottom, 12)

                            planFooter
                                .padding(.bottom, 32)
                        } else {
                            Text("Молитва не найдена")
                                .font(AppFont.regular(typ.body))
                                .foregroundColor(theme.muted)
                                .padding(.top, 24)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .readableContentWidth()
                    .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                    .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
                }
                .tabBarBottomClearance()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: scrollToParagraph) { _, target in
                    guard let target else { return }
                    withAnimation {
                        scrollProxy.scrollTo("p-\(target)", anchor: .top)
                    }
                    scrollToParagraph = nil
                }
            }
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    userData.toggleBookmark(slug)
                } label: {
                    Image(systemName: userData.isBookmarked(slug) ? "bookmark.fill" : "bookmark")
                        .foregroundColor(theme.accent)
                }
                .accessibilityLabel(userData.isBookmarked(slug)
                                    ? "Убрать закладку" : "Добавить закладку")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    userData.toggleMyRule(slug)
                } label: {
                    Image(systemName: userData.isInMyRule(slug)
                          ? "text.badge.checkmark" : "text.badge.plus")
                        .foregroundColor(theme.accent)
                }
                .accessibilityLabel(userData.isInMyRule(slug)
                                    ? "Убрать из моего правила" : "Добавить в моё правило")
            }
            // «Содержание» — только когда в тексте ≥8 указаний (акафист 25–28,
            // канон 9); список короче не стоит отдельной кнопки в тулбаре.
            if rubricParagraphs.count >= 8 {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showContents = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundColor(theme.accent)
                    }
                    .accessibilityLabel("Содержание")
                }
            }
            if let prayer {
                if ReadingPlanSetupSheet.isVisiblyEligible(prayer: prayer) {
                    // Видный вход в «Читать ежедневно» прямо в тулбаре — та же
                    // цель, что и у карточки-CTA сверху страницы (ReadingPlanCard),
                    // но доступна без прокрутки к тексту молитвы.
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showPlanSetup = true
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                                .foregroundColor(theme.accent)
                        }
                        .accessibilityLabel("Читать ежедневно")
                    }
                } else {
                    // «…» — «Читать ежедневно» для молитв, не показанных на виду
                    // (§8.10): доступно, но не рекламируется.
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showPlanSetup = true
                            } label: {
                                Label(planSnapshot == nil ? "Читать ежедневно" : "Моё чтение",
                                      systemImage: "calendar")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(theme.accent)
                        }
                        .accessibilityLabel("Ещё")
                    }
                }
            }
        }
        .sheet(isPresented: $showTypography) {
            ReaderTypographySheet(showStress: $showStress)
                .environmentObject(appState)
        }
        .prayerSearchToolbar()
        .sheet(isPresented: $showNamePicker) {
            if let prayer, let list = prayer.nameList {
                PrayerNamePickerSheet(
                    list: list,
                    selectedUUIDs: Binding(
                        get: { selectedNameUUIDs ?? Set(availableEntries.map(\.uuid)) },
                        set: { selectedNameUUIDs = $0 }
                    )
                )
            }
        }
        .sheet(isPresented: $showPlanSetup) {
            if let prayer {
                ReadingPlanSetupSheet(prayer: prayer, candidateKinds: ReadingPlanSetupSheet.candidateKinds(for: prayer))
            }
        }
        .sheet(isPresented: $showContents) {
            PrayerContentsSheet(entries: rubricParagraphs) { paragraphID in
                scrollToParagraph = paragraphID
            }
        }
        .task {
            if prayer == nil {
                prayer = PrayersRepository.shared.prayer(slug: slug)
            }
            #if DEBUG
            if let prayer, DebugLaunchHooks.openPlanSetupSlug == prayer.slug {
                showPlanSetup = true
            }
            if let prayer, DebugLaunchHooks.openContentsSlug == prayer.slug, rubricParagraphs.count >= 8 {
                showContents = true
            }
            if let prayer, DebugLaunchHooks.openTypographySlug == prayer.slug {
                showTypography = true
            }
            #endif
        }
    }

    /// Нижняя часть экрана под текстом (§5.2 п.5): при активном
    /// неполном/неотмеченном плане — полноширинная «Прочитано сегодня».
    /// Вход в план для текста без него — теперь карточка-CTA сверху
    /// страницы (`ReadingPlanCard`) и кнопка в тулбаре, а не скромная
    /// строка здесь: прежняя мелкая ссылка «Читать ежедневно →» под текстом
    /// была незаметна.
    @ViewBuilder
    private var planFooter: some View {
        if let snapshot = planSnapshot,
           snapshot.completedCount < snapshot.totalUnits, !snapshot.doneToday {
            MarkPlanDoneButton(planUUID: snapshot.uuid)
        }
    }

    /// Панель имён: кто поминается в молитве.
    private var namesBar: some View {
        Button {
            showNamePicker = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "person.2")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(theme.accent)

                if selectedEntries.isEmpty {
                    Text(availableEntries.isEmpty
                         ? "Добавьте имена в помянник"
                         : "Выберите имена")
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)
                } else {
                    Text(selectedEntries.map(\.canonicalName).joined(separator: ", "))
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.text)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.todayHighlight)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Имена для поминовения")
    }
}

// MARK: - Выбор имён из помянника

private struct PrayerNamePickerSheet: View {
    let list: PomyannikList
    @Binding var selectedUUIDs: Set<String>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    @ObservedObject private var userData = PrayersUserDataStore.shared
    private let theme = OrthodoxColors.fallback

    @State private var showAddSheet = false

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var entries: [PomyannikEntryEntity] {
        userData.entries(in: list)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if entries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.2")
                                .font(.system(size: 32, weight: .light))
                                .foregroundColor(theme.muted)
                            Text("В списке «\(list.title)» пока нет имён")
                                .font(AppFont.regular(typ.footnote))
                                .foregroundColor(theme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.uuid) { index, entry in
                                Button {
                                    if selectedUUIDs.contains(entry.uuid) {
                                        selectedUUIDs.remove(entry.uuid)
                                    } else {
                                        selectedUUIDs.insert(entry.uuid)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedUUIDs.contains(entry.uuid)
                                              ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundColor(selectedUUIDs.contains(entry.uuid)
                                                             ? theme.accent : theme.border)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.canonicalName)
                                                .font(AppFont.regular(typ.callout))
                                                .foregroundColor(theme.text)
                                            if entry.inputName.lowercased() != entry.canonicalName.lowercased() {
                                                Text(entry.inputName)
                                                    .font(AppFont.regular(typ.caption))
                                                    .foregroundColor(theme.muted)
                                            }
                                        }

                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if index < entries.count - 1 {
                                    Rectangle()
                                        .fill(theme.border)
                                        .frame(height: 0.5)
                                        .padding(.leading, 52)
                                }
                            }
                        }
                        .background(theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Button {
                        showAddSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Text("Добавить имя")
                                .font(AppFont.medium(typ.footnote))
                        }
                        .foregroundColor(theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(theme.accent.opacity(0.4),
                                              style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(list.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // См. комментарий у ReaderTypographySheet: без этого модификатора
            // системный заголовок листа красится по Dark Mode устройства и
            // теряется на светлом фоне.
            .toolbarColorScheme(.light, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                PomyannikAddSheet(list: list)
            }
        }
    }
}

// MARK: - Переключатель языка

private struct PrayerLanguagePicker: View {
    @Binding var selection: String

    @Environment(\.userFontSize) private var userFontSize

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        SlidingSegmentedControl(
            segments: PrayerLanguage.allCases.map {
                .init(value: $0.rawValue, title: $0.shortTitle)
            },
            selection: $selection,
            font: AppFont.regular(typ.footnote)
        )
    }
}

// MARK: - Текст молитвы

/// Отображает текст молитвы: абзацы разделены пустой строкой,
/// абзацы-указания (обёрнутые в *звёздочки*) — курсивом приглушённым цветом.
struct PrayerTextView: View {
    let text: String

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    /// `internal`, не `private` — переиспользуется `PrayerDetailView`
    /// (порог «Содержание» ≥8 указаний) и `PrayerContentsSheet` (список
    /// указаний), см. правки этих файлов в пакете «Содержание».
    struct Paragraph: Identifiable, Hashable {
        let id: Int
        let text: String
        let isRubric: Bool
    }

    /// Разбор текста на абзацы — вынесен в static-функцию, чтобы им могли
    /// пользоваться и `body` (через `paragraphs`), и внешний код, которому
    /// нужен список указаний без построения самого `PrayerTextView`
    /// (`PrayerDetailView.rubricParagraphs`).
    static func paragraphs(in text: String) -> [Paragraph] {
        text.components(separatedBy: "\n\n").enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("*") && trimmed.hasSuffix("*") && trimmed.count > 2 {
                return Paragraph(id: index,
                                 text: String(trimmed.dropFirst().dropLast()),
                                 isRubric: true)
            }
            return Paragraph(id: index, text: trimmed, isRubric: false)
        }
    }

    /// Абзацы-указания «Кондак N» / «Икос N» / «Песнь N» и т. п. — список для
    /// `PrayerContentsSheet` и порог показа тулбар-кнопки «Содержание».
    static func rubricParagraphs(in text: String) -> [Paragraph] {
        paragraphs(in: text).filter(\.isRubric)
    }

    private var paragraphs: [Paragraph] { Self.paragraphs(in: text) }

    var body: some View {
        // Обычный VStack (не Lazy: ленивый стек при 25 пт отрисовывал часть акафистов пустым экраном) — «Содержание» (PrayerContentsSheet) прокручивает
        // сюда через .id("p-\(i)") внутри ScrollViewReader, которым эту вьюху
        // оборачивает PrayerDetailView.
        VStack(alignment: .leading, spacing: 16) {
            ForEach(paragraphs) { paragraph in
                if paragraph.isRubric {
                    Text(paragraph.text)
                        .font(AppFont.italic(typ.footnote))
                        .foregroundColor(theme.muted)
                        .lineSpacing(6)
                        .id("p-\(paragraph.id)")
                } else {
                    Text(attributed(paragraph.text))
                        .font(AppFont.regular(typ.body))
                        .foregroundColor(theme.text)
                        .lineSpacing(8)
                        .id("p-\(paragraph.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Подсвечивает вставленные имена (маркеры ⟦…⟧) акцентным цветом.
    private func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        var remainder = Substring(text)
        while let open = remainder.range(of: PrayerTemplateRenderer.nameMarkerOpen),
              let close = remainder.range(of: PrayerTemplateRenderer.nameMarkerClose,
                                          range: open.upperBound..<remainder.endIndex) {
            result += AttributedString(String(remainder[..<open.lowerBound]))
            var name = AttributedString(String(remainder[open.upperBound..<close.lowerBound]))
            name.foregroundColor = theme.accent
            result += name
            remainder = remainder[close.upperBound...]
        }
        result += AttributedString(String(remainder))
        return result
    }
}

// MARK: - Настройки текста молитвы

/// Компактный лист настроек чтения: размер шрифта, начертание и ударения.
/// Управляет теми же настройками, что и раздел «Настройки» приложения.
struct ReaderTypographySheet: View {
    @Binding var showStress: Bool

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    @AppStorage(PrayersRepository.feminineFormsKey) private var feminineForms = false

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Размер шрифта
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Размер шрифта")
                            .font(AppFont.regular(typ.subheadline))
                            .foregroundColor(theme.text)

                        HStack(spacing: 16) {
                            sizeButton(systemName: "minus", delta: -2, label: "Уменьшить")

                            VStack(spacing: 2) {
                                Text("Аа")
                                    .font(AppFont.regular(CGFloat(appState.fontSize)))
                                    .foregroundColor(theme.text)
                                Text("\(Int(appState.fontSize)) пт")
                                    .font(AppFont.regular(typ.caption))
                                    .foregroundColor(theme.muted)
                            }
                            .frame(maxWidth: .infinity)

                            sizeButton(systemName: "plus", delta: 2, label: "Увеличить")
                        }
                    }

                    // Начертание
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Шрифт")
                            .font(AppFont.regular(typ.subheadline))
                            .foregroundColor(theme.text)

                        SlidingSegmentedControl(
                            segments: AppFontFamily.allCases.map {
                                .init(value: $0, title: $0.title)
                            },
                            selection: $appState.fontFamily,
                            font: AppFont.regular(typ.footnote)
                        )
                    }

                    // Ударения
                    Toggle(isOn: $showStress) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ударения")
                                .font(AppFont.regular(typ.subheadline))
                                .foregroundColor(theme.text)
                            Text("Знаки ударения в церковнославянском тексте")
                                .font(AppFont.regular(typ.caption))
                                .foregroundColor(theme.muted)
                        }
                    }
                    .tint(theme.accent)

                    // Женская форма молитв
                    Toggle(isOn: $feminineForms) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Женская форма молитв")
                                .font(AppFont.regular(typ.subheadline))
                                .foregroundColor(theme.text)
                            Text("В последовании ко Причащению и благодарственных молитвах")
                                .font(AppFont.regular(typ.caption))
                                .foregroundColor(theme.muted)
                        }
                    }
                    .tint(theme.accent)
                }
                .padding(24)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Текст")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // Корень бага «белый заголовок на кремовом фоне»: у приложения
            // нет тёмной темы — OrthodoxColors.fallback всегда светлая, но
            // системный .navigationTitle красится по реальной цветовой схеме
            // устройства. На устройстве в Dark Mode заголовок листа (в
            // отличие от кнопок, у которых есть явный .foregroundColor)
            // рисуется белым поверх светлого фона листа. Остальные экраны
            // раздела «Молитвы» не показывают заголовок этим системным
            // способом — они рисуют его сами как Text(theme.text) — поэтому
            // баг заметен только в шитах с .navigationTitle. Фикс — прибить
            // цветовую схему тулбара к светлой, как и весь остальной UI.
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
        .presentationDragIndicator(.visible)
        #endif
    }

    private func sizeButton(systemName: String, delta: Double, label: String) -> some View {
        Button {
            appState.fontSize = AppState.clampFontSize(appState.fontSize + delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(theme.card)
                .overlay(Circle().stroke(theme.border, lineWidth: 1))
                .clipShape(Circle())
        }
        .foregroundColor(theme.text)
        .accessibilityLabel(label)
    }
}

#Preview("Ударения") {
    ScrollView {
        PrayerTextView(text: """
        *Встав от сна, произнеси:*

        Го́споди Иису́се Христе́, Сы́не Бо́жий, моли́тв ра́ди Пречи́стыя \
        Твоея́ Ма́тере и всех святы́х, поми́луй нас. Ами́нь.

        Царю́ Небе́сный, Уте́шителю, Ду́ше и́стины, И́же везде́ сый и вся \
        исполня́яй, Сокро́вище благи́х и жи́зни Пода́телю, прииди́ и всели́ся \
        в ны, и очи́сти ны от вся́кия скве́рны, и спаси́, Бла́же, ду́ши на́ша.
        """)
        .padding(32)
    }
    .background(OrthodoxColors.fallback.background)
}
