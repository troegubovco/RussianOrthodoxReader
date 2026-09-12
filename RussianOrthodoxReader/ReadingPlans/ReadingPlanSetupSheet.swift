import SwiftUI

// MARK: - Лист запуска плана «Читать ежедневно» (§5.3 akathist_psalter_design.md)

/// Заголовок «Читать ежедневно» (для Псалтири — «План чтения Псалтири»).
/// Если по этой молитве уже есть план соответствующего вида — вместо выбора
/// длительности показывает прогресс и «Остановить чтение» / «Начать заново».
///
/// `candidateKinds` — какие виды плана вообще можно предложить для этой
/// молитвы (см. `candidateKinds(for:)`/`isVisiblyEligible(for:)` ниже,
/// единая точка правды для `PrayerDetailView` и `ReadingPlanCard`):
///  * акафист → один вид, `.dailyPrayer(slug)`;
///  * кафизма Псалтири → два вида одновременно, `.psalterKathisma` и
///    `.psalterSlava` — переключатель сверху листа (§3.3: «обе двери»);
///  * часть Великого канона → один вид, `.greatCanon`, без выбора длительности
///    (даты жёсткие);
///  * любая другая молитва (только из меню «…», §8.10) → `.dailyPrayer(slug)`.
struct ReadingPlanSetupSheet: View {
    let prayer: Prayer
    let candidateKinds: [ReadingPlanKind]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    @ObservedObject private var store = ReadingPlansStore.shared
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    @State private var selectedKindIndex = 0
    @State private var selectedOption: DurationOption
    @State private var customDays: Double = 40
    @State private var reminderEnabled = false
    @State private var reminderTimeDate: Date
    /// Открыт ли `confirmationDialog` подтверждения «Остановить чтение» —
    /// необратимая (хоть и не разрушительная — история отметок сохраняется)
    /// операция не должна срабатывать от одного касания.
    @State private var showStopConfirm = false

    init(prayer: Prayer, candidateKinds: [ReadingPlanKind]) {
        self.prayer = prayer
        self.candidateKinds = candidateKinds
        let firstKind = candidateKinds.first ?? .dailyPrayer(slug: prayer.slug)
        _selectedOption = State(initialValue: Self.defaultOption(for: firstKind, prayer: prayer))
        _reminderTimeDate = State(initialValue: Self.defaultReminderTime())
    }

    private var selectedKind: ReadingPlanKind {
        candidateKinds.indices.contains(selectedKindIndex)
            ? candidateKinds[selectedKindIndex]
            : (candidateKinds.first ?? .dailyPrayer(slug: prayer.slug))
    }

    /// Активный план ровно этого вида (не любой план по этой молитве — у
    /// кафизмы Псалтири «по кафизмам» и «по Славам» независимы друг от
    /// друга, переключение сегмента должно показывать состояние ИМЕННО
    /// выбранного вида).
    private var existingSnapshot: ReadingPlanSnapshot? {
        store.plans.first { $0.kind == selectedKind }
    }

    private var sheetTitle: String {
        if candidateKinds.contains(.psalterKathisma) || candidateKinds.contains(.psalterSlava) {
            return "План чтения Псалтири"
        }
        return "Читать ежедневно"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if candidateKinds.count > 1 {
                        SlidingSegmentedControl(
                            segments: candidateKinds.indices.map { i in
                                .init(value: i, title: segmentTitle(for: candidateKinds[i]))
                            },
                            selection: $selectedKindIndex,
                            font: AppFont.regular(typ.footnote)
                        )
                        .onChange(of: selectedKindIndex) { _, newIndex in
                            selectedOption = Self.defaultOption(for: candidateKinds[newIndex], prayer: prayer)
                        }
                    }

                    if let existingSnapshot {
                        existingPlanSection(existingSnapshot)
                    } else {
                        newPlanSection
                    }
                }
                .padding(24)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(sheetTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // См. комментарий у ReaderTypographySheet (PrayerDetailView.swift):
            // без этого модификатора системный заголовок листа красится по
            // Dark Mode устройства и теряется на светлом фоне.
            .toolbarColorScheme(.light, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }

    // MARK: - Новый план

    @ViewBuilder
    private var newPlanSection: some View {
        Text(rubricText(for: selectedKind))
            .font(AppFont.regular(typ.footnote))
            .foregroundColor(theme.muted)

        let options = presetOptions(for: selectedKind)
        if !options.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    optionRow(option)
                    if index < options.count - 1 {
                        Rectangle().fill(theme.border).frame(height: 0.5).padding(.leading, 52)
                    }
                }
            }
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if selectedOption == .custom {
                customStepper
            }
        }

        reminderSection

        if !store.canStartNewPlan {
            Text("Больше трёх чтений одновременно — уже не правило, а список дел.")
                .font(AppFont.regular(typ.caption))
                .foregroundColor(theme.muted)
        }

        Button {
            startPlan()
        } label: {
            Text("Начать")
                .font(AppFont.medium(typ.callout))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(store.canStartNewPlan ? theme.accent : theme.muted)
                )
        }
        .buttonStyle(.plain)
        .disabled(!store.canStartNewPlan)
    }

    private func optionRow(_ option: DurationOption) -> some View {
        let isSelected = option == selectedOption
        return Button {
            selectedOption = option
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? theme.accent : theme.border)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: option))
                        .font(AppFont.regular(typ.callout))
                        .foregroundColor(theme.text)
                    if let subtitle = subtitle(for: option) {
                        Text(subtitle)
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
    }

    private var customStepper: some View {
        HStack {
            Text("Дней:")
                .font(AppFont.regular(typ.callout))
                .foregroundColor(theme.text)
            Spacer(minLength: 0)
            Stepper(value: $customDays, in: 3...100) {
                Text("\(Int(customDays))")
                    .font(AppFont.medium(typ.callout))
                    .foregroundColor(theme.text)
                    .frame(minWidth: 36)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Напоминать", isOn: $reminderEnabled)
                .font(AppFont.regular(typ.callout))
                .foregroundColor(theme.text)
                .tint(theme.accent)

            if reminderEnabled {
                DatePicker("Время напоминания", selection: $reminderTimeDate, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        }
        .padding(16)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Существующий план

    private func existingPlanSection(_ snapshot: ReadingPlanSnapshot) -> some View {
        let isComplete = snapshot.completedCount >= snapshot.totalUnits
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                ProgressRingView(
                    progress: snapshot.progress, diameter: 72, lineWidth: 6, stroke: theme.accent,
                    todayHint: (snapshot.doneToday || isComplete || snapshot.totalUnits <= 0)
                        ? 0 : 1.0 / Double(snapshot.totalUnits),
                    isComplete: isComplete
                ) {
                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(theme.accent)
                    } else {
                        Text("\(snapshot.nextUnitIndex + 1)")
                            .font(AppFont.semiBold(typ.callout))
                            .foregroundColor(theme.text)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.title)
                        .font(AppFont.medium(typ.callout))
                        .foregroundColor(theme.text)
                    Text(isComplete
                         ? "Завершено · \(ReadingPlanWording.days(snapshot.totalUnits))"
                         : snapshot.nextUnitLabel)
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)
                }

                Spacer(minLength: 0)
            }

            Button {
                store.stop(planUUID: snapshot.uuid)
            } label: {
                Text("Начать заново")
                    .font(AppFont.medium(typ.callout))
                    .foregroundColor(theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                showStopConfirm = true
            } label: {
                Text("Остановить чтение")
                    .font(AppFont.regular(typ.callout))
                    .foregroundColor(theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
        }
        .confirmationDialog(
            "Остановить чтение?",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("Остановить чтение", role: .destructive) {
                store.stop(planUUID: snapshot.uuid)
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Отметки сохранятся в истории, кольцо исчезнет.")
        }
    }

    // MARK: - Запуск плана

    private func startPlan() {
        let units: Int
        let rule: String?
        let end: Date?
        switch selectedKind {
        case .greatCanon:
            units = 4
            rule = nil
            end = nil
        default:
            units = totalUnits(for: selectedOption)
            rule = endDateRule(for: selectedOption)
            end = endDate(for: selectedOption)
        }
        let reminder = reminderEnabled ? Self.timeFormatter.string(from: reminderTimeDate) : nil
        store.start(kind: selectedKind, totalUnits: units, endDateRule: rule, endDate: end, reminderTime: reminder)
        dismiss()
    }

    // MARK: - Варианты длительности

    private enum DurationOption: Hashable {
        case fixed(Int)
        case untilFast(FastPeriod)
        case custom
    }

    private func presetOptions(for kind: ReadingPlanKind) -> [DurationOption] {
        var options: [DurationOption]
        switch kind {
        case .dailyPrayer:
            options = [.fixed(7), .fixed(12), .fixed(40)]
        case .psalterKathisma:
            options = [.fixed(20)]
        case .psalterSlava:
            options = [.fixed(60)]
        case .greatCanon:
            return []
        }
        if let fast = FastPeriods.currentOrUpcoming() {
            options.append(.untilFast(fast))
        }
        options.append(.custom)
        return options
    }

    private func title(for option: DurationOption) -> String {
        switch option {
        case .fixed(let n):
            return ReadingPlanWording.days(n)
        case .untilFast(let period):
            return FastPeriods.buttonTitle(for: period.kind)
        case .custom:
            return "Своё число"
        }
    }

    private func subtitle(for option: DurationOption) -> String? {
        switch option {
        case .untilFast(let period):
            return FastPeriods.daysRemainingLabel(for: period)
        default:
            return nil
        }
    }

    private func totalUnits(for option: DurationOption) -> Int {
        switch option {
        case .fixed(let n): return n
        case .untilFast(let period): return period.daysRemaining()
        case .custom: return max(3, min(100, Int(customDays.rounded())))
        }
    }

    private func endDateRule(for option: DurationOption) -> String? {
        if case .untilFast(let period) = option { return period.kind.rawValue }
        return nil
    }

    private func endDate(for option: DurationOption) -> Date? {
        if case .untilFast(let period) = option { return period.end }
        return nil
    }

    private static func defaultOption(for kind: ReadingPlanKind, prayer: Prayer) -> DurationOption {
        switch kind {
        case .dailyPrayer:
            return .fixed(prayer.categorySlug == "akafisty" ? 40 : 7)
        case .psalterKathisma:
            return .fixed(20)
        case .psalterSlava:
            return .fixed(60)
        case .greatCanon:
            return .fixed(4)
        }
    }

    private static func defaultReminderTime() -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 8
        components.minute = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Строки (§3.3 — дословно)

    private func segmentTitle(for kind: ReadingPlanKind) -> String {
        switch kind {
        case .psalterKathisma: return "По кафизмам"
        case .psalterSlava: return "По «Славам»"
        default: return ""
        }
    }

    private func rubricText(for kind: ReadingPlanKind) -> String {
        switch kind {
        case .dailyPrayer:
            if prayer.categorySlug == "akafisty" {
                return "Акафист — единое песнопение и читается целиком за один раз; продолжительное чтение — это повторение всего акафиста каждый день."
            }
            return "Читать эту молитву каждый день выбранное число дней."
        case .psalterKathisma:
            return "Псалтирь читается по кафизмам: по одной в день вся Псалтирь прочитывается за двадцать дней."
        case .psalterSlava:
            return "Каждая кафизма делится на три „Славы“: по одной в день Псалтирь прочитывается за два месяца."
        case .greatCanon:
            return "Великий канон читается на повечерии в первые четыре дня Великого поста — по одной части в день, и целиком в четверг пятой седмицы."
        }
    }
}

// MARK: - Правило показа (§3.3/§8.10)

extension ReadingPlanSetupSheet {
    /// Какие виды плана вообще можно предложить для этой молитвы. Общая точка
    /// правды для `PrayerDetailView` (условие показа строки/меню) и
    /// `ReadingPlanCard` (какой лист открыть при перезапуске).
    static func candidateKinds(for prayer: Prayer) -> [ReadingPlanKind] {
        if prayer.categorySlug == "akafisty" {
            return [.dailyPrayer(slug: prayer.slug)]
        }
        if prayer.slug.hasPrefix("psaltir.kafizma-") {
            return [.psalterKathisma, .psalterSlava]
        }
        if prayer.categorySlug == "canons", prayer.slug.hasPrefix("canons.velikij-kanon-") {
            return [.greatCanon]
        }
        return [.dailyPrayer(slug: prayer.slug)]
    }

    /// `true` — строка «Читать ежедневно →» видна прямо под текстом.
    /// `false` — доступно только из меню «…» (§8.10: приложение не должно
    /// рекламировать сорокадневное обязательство для любой молитвы подряд).
    static func isVisiblyEligible(prayer: Prayer) -> Bool {
        prayer.categorySlug == "akafisty"
            || prayer.slug.hasPrefix("psaltir.kafizma-")
            || (prayer.categorySlug == "canons" && prayer.slug.hasPrefix("canons.velikij-kanon-"))
    }
}
