import SwiftUI

// MARK: - «Мои чтения» (§5.2 п.2/3 akathist_psalter_design.md)

/// Список активных планов чтения — на корне «Молитвы» сразу под помянником
/// (без фильтра), и позже, во вкладке «Библия», отфильтрованный только на
/// псалтирные планы (`filter:` подготовлен для этого — см. заголовок задания
/// пакета C, вкладку Библии подключает другой пакет). Строки: кольцо ⌀44 +
/// название + подпись следующей единицы + кнопка «Отметить», если сегодня ещё
/// не отмечено. Пустой массив (после фильтра) — карточки нет вовсе.
///
/// Строки навигируемы: нажатие на кольцо/название вызывает `onOpen` с
/// текущей единицей плана (кто и куда ведёт — решает вызывающий экран:
/// `PrayersView` открывает молитву, `BibleView` — кафизму). Кнопка
/// «Отметить» — отдельный `Button` со своим `contentShape`, работает
/// независимо от нажатия на саму строку.
struct MyReadingsCard: View {
    var filter: ((ReadingPlanSnapshot) -> Bool)? = nil
    var onOpen: ((ReadingPlanSnapshot) -> Void)? = nil

    @ObservedObject private var store = ReadingPlansStore.shared
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    /// Не-nil — план, для которого показан `confirmationDialog` остановки
    /// (открыт из `contextMenu` строки).
    @State private var stopCandidate: ReadingPlanSnapshot?
    /// Не-nil — план, для которого открыт `ReadingPlanCatchUpSheet` (тоже
    /// из `contextMenu`).
    @State private var catchUpTarget: ReadingPlanSnapshot?

    private var plans: [ReadingPlanSnapshot] {
        guard let filter else { return store.plans }
        return store.plans.filter(filter)
    }

    var body: some View {
        if !plans.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Мои чтения")
                    .sectionHeader()

                VStack(spacing: 0) {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        row(for: plan)
                        if index < plans.count - 1 {
                            Rectangle().fill(theme.border).frame(height: 0.5).padding(.leading, 20)
                        }
                    }
                }
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .confirmationDialog(
                "Остановить чтение?",
                isPresented: Binding(
                    get: { stopCandidate != nil },
                    set: { if !$0 { stopCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Остановить чтение", role: .destructive) {
                    if let plan = stopCandidate {
                        store.stop(planUUID: plan.uuid)
                    }
                    stopCandidate = nil
                }
                Button("Отмена", role: .cancel) { stopCandidate = nil }
            } message: {
                Text("Отметки сохранятся в истории, кольцо исчезнет.")
            }
            .sheet(item: $catchUpTarget) { plan in
                ReadingPlanCatchUpSheet(snapshot: plan)
            }
        }
    }

    private func row(for plan: ReadingPlanSnapshot) -> some View {
        let isComplete = plan.completedCount >= plan.totalUnits
        let todayHint = (plan.doneToday || isComplete || plan.totalUnits <= 0)
            ? 0.0 : (1.0 / Double(plan.totalUnits))

        return HStack(spacing: 14) {
            Button {
                onOpen?(plan)
            } label: {
                HStack(spacing: 14) {
                    ProgressRingView(
                        progress: plan.progress, diameter: 44, lineWidth: 4, stroke: theme.accent,
                        todayHint: todayHint, isComplete: isComplete
                    ) {
                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(theme.accent)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.title)
                            .font(AppFont.regular(typ.callout))
                            .foregroundColor(theme.text)
                            .lineLimit(2)
                        Text(isComplete ? "Завершено · \(ReadingPlanWording.days(plan.totalUnits))" : plan.nextUnitLabel)
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(plan.title)
            .accessibilityValue(
                isComplete
                ? "Завершено, \(ReadingPlanWording.days(plan.totalUnits))"
                : plan.nextUnitLabel
            )
            .accessibilityHint("Открыть")

            if !isComplete && !plan.doneToday {
                Button {
                    ReadingPlansStore.shared.markDone(planUUID: plan.uuid)
                } label: {
                    Text("Отметить")
                        .font(AppFont.medium(typ.caption))
                        .foregroundColor(theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Отметить сегодняшнее чтение")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contextMenu {
            Button {
                onOpen?(plan)
            } label: {
                Label("Открыть", systemImage: "arrow.right")
            }
            Button(role: .destructive) {
                stopCandidate = plan
            } label: {
                Label("Остановить чтение", systemImage: "stop.circle")
            }
            if plan.missedDays > 0 {
                Button {
                    catchUpTarget = plan
                } label: {
                    Label("Пропущенные дни…", systemImage: "calendar.badge.clock")
                }
            }
        }
    }
}

#if DEBUG
#Preview("Мои чтения") {
    ScrollView {
        MyReadingsCard()
            .padding(24)
    }
    .background(OrthodoxColors.fallback.background)
}
#endif
