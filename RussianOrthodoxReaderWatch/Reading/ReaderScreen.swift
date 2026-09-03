//
//  ReaderScreen.swift
//  RussianOrthodoxReaderWatch
//
//  Экран чтения: один фрагмент молитвы за раз. «Далее» переключает индекс на
//  месте (без push'а), последний фрагмент завершает чтение и возвращает к
//  корню. Позиция чтения сохраняется при каждой смене фрагмента.
//

import SwiftUI

struct ReaderScreen: View {
    let ref: ReadingUnitRef

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var nav: WatchNavigationController
    @ObservedObject private var userData = WatchUserDataStore.shared

    @AppStorage("watch.textStep") private var textStepRaw = WatchTheme.TextStep.regular.rawValue
    @AppStorage("watch.prayerLanguage") private var languageRaw = PrayerLanguage.churchSlavonic.rawValue
    @AppStorage("watch.showStress") private var showStress = true
    @AppStorage(PrayersRepository.feminineFormsKey) private var feminineForms = false

    @State private var loadedPrayers: [Prayer] = []
    @State private var fragments: [Fragment] = []
    @State private var index = 0
    @State private var loaded = false
    @State private var showContents = false
    @State private var showTextOptions = false
    @State private var planMarkSuccessTrigger = false

    private var textStep: WatchTheme.TextStep {
        WatchTheme.TextStep(rawValue: textStepRaw) ?? .regular
    }

    private var language: PrayerLanguage {
        PrayerLanguage(rawValue: languageRaw) ?? .churchSlavonic
    }

    private var hasFullTranslation: Bool {
        !loadedPrayers.isEmpty && loadedPrayers.allSatisfy { $0.textRU != nil }
    }

    private var currentFragment: Fragment? {
        fragments.indices.contains(index) ? fragments[index] : nil
    }

    /// Подзаголовок молитвы показываем только для одиночной молитвы на её первом фрагменте.
    private var showsSubtitle: Bool {
        !fragments.isEmpty && Set(fragments.map(\.prayerIndex)).count == 1 && index == 0
    }

    private var isLast: Bool { fragments.isEmpty || index >= fragments.count - 1 }

    /// План чтения, которому принадлежит читаемая молитва — только для
    /// одиночных молитв (`.prayer`), не для последований/правила/списков,
    /// где читается сразу несколько текстов. Ищем по `nextTargetSlug`
    /// (кафизма ЦС Псалтири, часть Великого канона) или `subjectSlug`
    /// (акафист как `dailyPrayer`) — оба поля указывают на один и тот же
    /// slug молитвы, которую сейчас читают (§4.6 akathist_psalter_design.md).
    /// `nil`, если сегодня уже отмечено — кнопка тогда не нужна.
    private var activePlanForCurrentUnit: WatchSnapshot.Plan? {
        guard case .prayer(let slug) = ref.kind else { return nil }
        return userData.plans.first { plan in
            !plan.doneToday && (plan.nextTargetSlug == slug || plan.subjectSlug == slug)
        }
    }

    private var unitTitle: String {
        switch ref.kind {
        case .sequence(_, let title): return title
        case .rule: return "Моё правило"
        case .list(let title, _): return title
        case .prayer: return loadedPrayers.first?.title ?? ""
        }
    }

    private var shortNavTitle: String {
        switch ref.kind {
        case .sequence(let slug, let title):
            switch slug {
            case "morning": return "Утренние"
            case "evening": return "Вечерние"
            case "communion": return "Причащение"
            case "thanksgiving": return "Благодар."
            default: return String(title.prefix(12))
            }
        case .rule:
            return "Правило"
        case .list(let title, _):
            return String(title.prefix(12))
        case .prayer:
            return String(unitTitle.prefix(12))
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("top")

                    header

                    if let current = currentFragment {
                        FragmentView(fragment: current, showsSubtitle: showsSubtitle, textStep: textStep)

                        if !userData.hasSnapshot, takesNames(current) {
                            Text("Имена появятся, когда откроете «Синодал» на iPhone")
                                .font(WatchTheme.chrome(12))
                                .foregroundStyle(WatchTheme.muted)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 8)
                        }
                    } else if loaded {
                        Text("Молитва не найдена")
                            .font(WatchTheme.chrome(15))
                            .foregroundStyle(WatchTheme.muted)
                            .padding(.top, 24)
                    }

                    footer
                }
                // 8 пт + системный отступ ≈ 11 пт от края: подобрано по снимкам
                // симулятора (42 и 49 мм) — текст не липнет к скруглённому углу.
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(WatchTheme.background)
            .onChange(of: index) { _, _ in
                withAnimation(nil) { proxy.scrollTo("top", anchor: .top) }
                savePosition()
            }
        }
        .navigationTitle(shortNavTitle)
        .task { load() }
        .onDisappear { savePosition() }
        .onChange(of: scenePhase) { _, _ in savePosition() }
        .onChange(of: languageRaw) { _, _ in rebuild() }
        .onChange(of: showStress) { _, _ in rebuild() }
        .onChange(of: userData.snapshot) { _, _ in rebuild() }
        .onChange(of: feminineForms) { _, _ in reloadUnit() }
        .sheet(isPresented: $showContents) {
            ContentsSheet(fragments: fragments, currentIndex: index) { newIndex in
                index = newIndex
            }
        }
        .sheet(isPresented: $showTextOptions) {
            ReaderTextOptionsSheet(
                textStepRaw: $textStepRaw,
                languageRaw: $languageRaw,
                showStress: $showStress,
                feminineForms: $feminineForms,
                hasFullTranslation: hasFullTranslation
            )
        }
    }

    // MARK: - Управление

    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                contentsButton
                if !isLuminanceReduced { counter }
                textOptionsButton
            }
            .padding(.bottom, 8)
        } else {
            HStack {
                contentsButton
                Spacer()
                if !isLuminanceReduced { counter }
                textOptionsButton
            }
            .padding(.bottom, 8)
        }
    }

    private var contentsButton: some View {
        Button {
            showContents = true
        } label: {
            Image(systemName: "list.bullet")
        }
        .buttonStyle(.plain)
        .foregroundStyle(WatchTheme.muted)
        .accessibilityLabel("Содержание")
        .accessibilityHint("Список молитв последования")
    }

    private var counter: some View {
        Text(fragments.isEmpty ? "" : "\(index + 1)/\(fragments.count)")
            .font(WatchTheme.chrome(13, weight: .medium))
            .foregroundStyle(WatchTheme.muted)
    }

    private var textOptionsButton: some View {
        Button {
            showTextOptions = true
        } label: {
            Image(systemName: "textformat.size")
        }
        .buttonStyle(.plain)
        .foregroundStyle(WatchTheme.muted)
        .accessibilityLabel("Настройки текста")
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: advance) {
                    Text(isLast ? "Готово" : "Далее: \(nextLabel)")
                        .font(WatchTheme.chrome(15, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(isLuminanceReduced ? WatchTheme.accent : Color.black)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isLuminanceReduced ? Color.clear : WatchTheme.accent)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(WatchTheme.accent, lineWidth: isLuminanceReduced ? 1 : 0)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLast ? "Готово" : "Далее: \(nextLabel)")

                Button {
                    showContents = true
                } label: {
                    Image(systemName: "list.bullet")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(WatchTheme.muted)
                .accessibilityLabel("Содержание")
                .accessibilityHint("Список молитв последования")
            }

            // Канал записи с часов (§4.6): на последнем фрагменте, если эта
            // молитва — цель активного плана чтения, который сегодня ещё не
            // отмечен. Отдельная строка, а не третья кнопка в HStack выше —
            // на 42-мм экране «Готово» + «Содержание» уже занимают всю ширину.
            if isLast, let plan = activePlanForCurrentUnit {
                Button {
                    markPlanDoneToday(plan)
                } label: {
                    Text("Прочитано сегодня")
                        .font(WatchTheme.chrome(14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(WatchTheme.accent)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(WatchTheme.accent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Прочитано сегодня")
                .accessibilityHint("Отметить сегодняшнее чтение по плану «\(plan.title)»")
            }
        }
        .padding(.top, 20)
        .sensoryFeedback(.success, trigger: planMarkSuccessTrigger)
    }

    /// Отмечает план оптимистично на часах и отправляет отметку на телефон
    /// (§4.6). После вызова `activePlanForCurrentUnit` вернёт `nil` (план
    /// помечен `doneToday` через оптимистичную надбавку в
    /// `WatchUserDataStore.plans`), и кнопка сама пропадёт.
    private func markPlanDoneToday(_ plan: WatchSnapshot.Plan) {
        userData.markPendingDone(planUUID: plan.uuid)
        WatchSessionReceiver.shared.sendPlanUnitDone(planId: plan.uuid)
        planMarkSuccessTrigger.toggle()
    }

    private var nextLabel: String {
        guard fragments.indices.contains(index + 1) else { return "" }
        return fragments[index + 1].label
    }

    private func advance() {
        if isLast {
            nav.popToRoot()
        } else {
            index += 1
        }
    }

    // MARK: - Загрузка и перестроение

    private func load() {
        guard !loaded else { return }
        let resolvedRef = resolveRuleRef(ref)
        loadedPrayers = ReadingUnit.loadPrayers(for: resolvedRef)
        fragments = ReadingUnit.build(
            prayers: loadedPrayers,
            language: language,
            showStress: showStress,
            names: { list in userData.entries(in: list) }
        )
        loaded = true
        guard !fragments.isEmpty else { return }
        index = min(max(ref.startFragment ?? 0, 0), fragments.count - 1)
        savePosition()
    }

    /// Перестраивает фрагменты без похода в БД — при смене языка, ударений
    /// или обновлении снимка помянника (уже загруженные молитвы не меняются).
    private func rebuild() {
        guard loaded, !loadedPrayers.isEmpty else { return }
        fragments = ReadingUnit.build(
            prayers: loadedPrayers,
            language: language,
            showStress: showStress,
            names: { list in userData.entries(in: list) }
        )
        index = min(index, max(fragments.count - 1, 0))
    }

    /// Заново прогоняет молитвы последования из БД (в отличие от rebuild())
    /// — нужно при смене «женской формы», так как меняется сам набор молитв.
    private func reloadUnit() {
        guard loaded else { return }
        let resolvedRef = resolveRuleRef(ref)
        loadedPrayers = ReadingUnit.loadPrayers(for: resolvedRef)
        fragments = ReadingUnit.build(
            prayers: loadedPrayers,
            language: language,
            showStress: showStress,
            names: { list in userData.entries(in: list) }
        )
        index = min(index, max(fragments.count - 1, 0))
    }

    /// Для «моего правила» подставляет актуальный набор slug'ов из снимка,
    /// если он отличается от закреплённого в маршруте (правило могло измениться
    /// на телефоне уже после того, как была сохранена позиция чтения).
    private func resolveRuleRef(_ ref: ReadingUnitRef) -> ReadingUnitRef {
        if case .rule = ref.kind, !userData.myRuleSlugs.isEmpty {
            return ReadingUnitRef(kind: .rule(slugs: userData.myRuleSlugs), startFragment: ref.startFragment)
        }
        return ref
    }

    private func takesNames(_ fragment: Fragment) -> Bool {
        loadedPrayers.first(where: { $0.slug == fragment.prayerSlug })?.takesNames ?? false
    }

    private func savePosition() {
        guard let current = currentFragment else { return }
        let resolved = resolveRuleRef(ref)
        ReadingPositionStore.save(
            ref: ReadingUnitRef(kind: resolved.kind, startFragment: nil),
            unitTitle: unitTitle,
            fragmentIndex: index,
            fragmentCount: fragments.count,
            fragmentLabel: current.label
        )
    }
}

// MARK: - Настройки текста (лист поверх экрана чтения)

private struct ReaderTextOptionsSheet: View {
    @Binding var textStepRaw: Int
    @Binding var languageRaw: String
    @Binding var showStress: Bool
    @Binding var feminineForms: Bool
    let hasFullTranslation: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Размер текста") {
                    ForEach(WatchTheme.TextStep.allCases, id: \.rawValue) { step in
                        Button {
                            textStepRaw = step.rawValue
                        } label: {
                            HStack {
                                Text("Аа")
                                    .font(WatchTheme.serif(step.basePt))
                                    .frame(width: 28, alignment: .leading)
                                Text(step.label)
                                Spacer()
                                if step.rawValue == textStepRaw {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(WatchTheme.accent)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                if hasFullTranslation {
                    Section("Язык") {
                        WatchSegmentedControl(
                            segments: PrayerLanguage.allCases.map { ($0.rawValue, $0.shortTitle) },
                            selection: $languageRaw
                        )
                    }
                }

                Toggle("Ударения", isOn: $showStress)
                Toggle("Женская форма", isOn: $feminineForms)
            }
            .navigationTitle("Текст")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
