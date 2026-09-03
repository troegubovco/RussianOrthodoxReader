//
//  WatchPlanRow.swift
//  RussianOrthodoxReaderWatch
//
//  Строка плана чтения в корневом списке часов — §5.2 п.4
//  akathist_psalter_design.md: кольцо ⌀26 + название + подпись следующей
//  единицы. Данные уже несут оптимистичную надбавку `WatchUserDataStore.plans`
//  (§4.6) — строка не знает о `pendingDone`, просто рисует переданный план.
//

import SwiftUI

struct WatchPlanRow: View {
    let plan: WatchSnapshot.Plan

    private var isComplete: Bool { plan.completedCount >= plan.totalUnits }

    private var progress: Double {
        guard plan.totalUnits > 0 else { return 0 }
        return Double(plan.completedCount) / Double(plan.totalUnits)
    }

    private var subtitle: String {
        if isComplete { return "Завершено" }
        return plan.doneToday ? "Прочитано сегодня" : plan.nextUnitLabel
    }

    var body: some View {
        NavigationLink(value: WatchRoute.plan(plan.uuid)) {
            HStack(spacing: 10) {
                ProgressRingView(progress: progress, diameter: 26, lineWidth: 3,
                                  stroke: WatchTheme.accent, isComplete: isComplete) {
                    EmptyView()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WatchTheme.body)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(plan.doneToday || isComplete ? WatchTheme.accent : WatchTheme.muted)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plan.title). Прочитано \(plan.completedCount) из \(plan.totalUnits).")
        .accessibilityHint(plan.doneToday ? "Прочитано сегодня" : "Открыть план чтения")
    }
}

#if DEBUG
#Preview {
    List {
        WatchPlanRow(plan: WatchSnapshot.Plan(
            uuid: "1", kind: "dailyPrayer", subjectSlug: "akafisty.akafist-iisusu-sladchajshemu",
            title: "Акафист Иисусу Сладчайшему", totalUnits: 40, completedCount: 12,
            doneToday: false, nextUnitIndex: 12, nextUnitLabel: "День 13 из 40",
            nextTargetSlug: "akafisty.akafist-iisusu-sladchajshemu"))
        WatchPlanRow(plan: WatchSnapshot.Plan(
            uuid: "2", kind: "psalterKathisma", subjectSlug: nil,
            title: "Псалтирь по кафизмам", totalUnits: 20, completedCount: 20,
            doneToday: true, nextUnitIndex: 20, nextUnitLabel: "Кафизма 1",
            nextTargetSlug: "psaltir.kafizma-1"))
    }
}
#endif
