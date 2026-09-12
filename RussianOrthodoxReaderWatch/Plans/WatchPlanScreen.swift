//
//  WatchPlanScreen.swift
//  RussianOrthodoxReaderWatch
//
//  Экран одного плана чтения — §5.2 п.4/§5.3 akathist_psalter_design.md:
//  большое кольцо, следующая единица, «Читать» и «Прочитано сегодня».
//  Никакого «Остановить»/«Начать заново» и снятия отметок — это только на
//  телефоне (§4.6: с часов уходит исключительно добавление отметки).
//
//  Все виды плана (`dailyPrayer`, `psalterKathisma`, `psalterSlava`,
//  `greatCanon`) открываются одинаково: `nextTargetSlug` — всегда slug
//  молитвы в молитвослове (для Псалтири по «Славам» это slug кафизмы,
//  внутри которой лежит нужная «Слава» — часы просто открывают её целиком,
//  без прокрутки к конкретной «Славе»).
//

import SwiftUI

struct WatchPlanScreen: View {
    let planUUID: String

    @ObservedObject private var userData = WatchUserDataStore.shared
    @State private var markSuccessTrigger = false

    private var plan: WatchSnapshot.Plan? {
        userData.plans.first { $0.uuid == planUUID }
    }

    var body: some View {
        Group {
            if let plan {
                content(for: plan)
            } else {
                Text("План не найден")
                    .font(WatchTheme.chrome(15))
                    .foregroundStyle(WatchTheme.muted)
                    .padding(.top, 24)
            }
        }
        .navigationTitle("Чтение")  // полное название — в теле экрана; верхняя полоса часов вмещает ~12 знаков
        .sensoryFeedback(.success, trigger: markSuccessTrigger)
    }

    @ViewBuilder
    private func content(for plan: WatchSnapshot.Plan) -> some View {
        let isComplete = plan.completedCount >= plan.totalUnits
        ScrollView {
            VStack(spacing: 10) {
                // ⌀96/6pt — таблица §5.1 akathist_psalter_design.md
                // («Экран плана на часах»): на 41/42-мм экране ring+подпись+
                // «Читать»+«Прочитано сегодня» не помещаются без прокрутки
                // даже при этом размере — прокрутка тут ожидаема (как и в
                // ReaderScreen), но лишний вес кольца её только усугубляет.
                ProgressRingView(progress: progress(plan), diameter: 96, lineWidth: 6,
                                  stroke: WatchTheme.accent, isComplete: isComplete) {
                    ringLabel(plan, isComplete: isComplete)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(plan.title)
                .accessibilityValue(ringAccessibilityValue(plan, isComplete: isComplete))

                if isComplete {
                    Text("Завершено · \(plan.totalUnits) \(daysWord(plan.totalUnits))")
                        .font(WatchTheme.chrome(13))
                        .foregroundStyle(WatchTheme.muted)
                        .multilineTextAlignment(.center)
                } else {
                    Text(plan.doneToday ? "Прочитано сегодня" : plan.nextUnitLabel)
                        .font(WatchTheme.chrome(14, weight: .medium))
                        .foregroundStyle(plan.doneToday ? WatchTheme.accent : WatchTheme.body)
                        .multilineTextAlignment(.center)

                    if let target = plan.nextTargetSlug {
                        NavigationLink(value: WatchRoute.read(ReadingUnitRef(kind: .prayer(slug: target)))) {
                            Text("Читать")
                                .font(WatchTheme.chrome(15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .foregroundStyle(Color.black)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(WatchTheme.accent)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Читать: \(plan.nextUnitLabel)")
                    }

                    doneButton(plan)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .background(WatchTheme.background)
    }

    @ViewBuilder
    private func ringLabel(_ plan: WatchSnapshot.Plan, isComplete: Bool) -> some View {
        if isComplete {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(WatchTheme.accent)
        } else {
            VStack(spacing: 2) {
                Text("\(plan.completedCount)/\(plan.totalUnits)")
                    .font(WatchTheme.serif(20, weight: .semibold))
                    .foregroundStyle(WatchTheme.body)
                if plan.doneToday {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WatchTheme.accent)
                }
            }
        }
    }

    @ViewBuilder
    private func doneButton(_ plan: WatchSnapshot.Plan) -> some View {
        if plan.doneToday {
            Text("Прочитано ✓")
                .font(WatchTheme.chrome(14, weight: .semibold))
                .foregroundStyle(WatchTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
        } else {
            Button {
                markDone(plan)
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
            .accessibilityHint("Отметить сегодняшнее чтение")
        }
    }

    // MARK: - Отметка

    private func markDone(_ plan: WatchSnapshot.Plan) {
        userData.markPendingDone(planUUID: plan.uuid)
        WatchSessionReceiver.shared.sendPlanUnitDone(planId: plan.uuid)
        markSuccessTrigger.toggle()
    }

    // MARK: - Вспомогательное

    private func progress(_ plan: WatchSnapshot.Plan) -> Double {
        guard plan.totalUnits > 0 else { return 0 }
        return Double(plan.completedCount) / Double(plan.totalUnits)
    }

    private func ringAccessibilityValue(_ plan: WatchSnapshot.Plan, isComplete: Bool) -> String {
        if isComplete {
            return "Завершено, \(plan.totalUnits) \(daysWord(plan.totalUnits))."
        }
        let doneText = plan.doneToday ? "Сегодня уже прочитано." : "Сегодня ещё не прочитано."
        return "Прочитано \(plan.completedCount) из \(plan.totalUnits). \(doneText)"
    }

    /// «1 день», «2 дня», «12 дней» — только для этого экрана (не общий
    /// хелпер вроде `Int.molitvCount` в WatchTheme.swift, чтобы не трогать
    /// файл вне зоны правки пакета E).
    private func daysWord(_ n: Int) -> String {
        let mod100 = abs(n) % 100
        let mod10 = mod100 % 10
        if (11...19).contains(mod100) { return "дней" }
        if mod10 == 1 { return "день" }
        if (2...4).contains(mod10) { return "дня" }
        return "дней"
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        WatchPlanScreen(planUUID: "demo-plan-akathist")
    }
}
#endif
