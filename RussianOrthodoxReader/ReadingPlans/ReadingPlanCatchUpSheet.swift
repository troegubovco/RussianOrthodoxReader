import SwiftUI
import SwiftData

// MARK: - Лист «Пропущенные дни» (§5.3 akathist_psalter_design.md)

/// Последние 14 календарных дней плана: отмеченные — галочкой, неотмеченные —
/// нажимаемые (отметка задним числом через `markDone(planUUID:on:)`). Никакого
/// красного цвета, никакого «план провален» — только нейтральный пустой кружок.
///
/// `ReadingPlanSnapshot` не хранит список отмеченных дней (только агрегаты —
/// `completedCount`/`doneToday`/`missedDays`), поэтому здесь читаем
/// `ReadingPlanUnitEntity` напрямую через `PersistenceController.shared` —
/// то же хранилище, которым пишет `ReadingPlansStore`, только на чтение.
struct ReadingPlanCatchUpSheet: View {
    let snapshot: ReadingPlanSnapshot

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    @ObservedObject private var store = ReadingPlansStore.shared
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    @State private var completedDayKeys: Set<String> = []

    /// Текущее состояние плана (может отличаться от `snapshot`, переданного
    /// в момент открытия листа, если что-то отметили, пока лист открыт).
    private var currentSnapshot: ReadingPlanSnapshot {
        store.plans.first { $0.uuid == snapshot.uuid } ?? snapshot
    }

    private var last14Days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<14).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Последние 14 дней — можно отметить задним числом, если забыли.")
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)

                    VStack(spacing: 0) {
                        ForEach(Array(last14Days.enumerated()), id: \.offset) { index, day in
                            dayRow(day)
                            if index < last14Days.count - 1 {
                                Rectangle().fill(theme.border).frame(height: 0.5).padding(.leading, 52)
                            }
                        }
                    }
                    .background(theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(24)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Пропущенные дни")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
        .onAppear { refresh() }
    }

    private func dayRow(_ day: Date) -> some View {
        let key = ISO8601DayFormatter.string(from: day)
        let done = completedDayKeys.contains(key)
        let canMark = !done && currentSnapshot.completedCount < currentSnapshot.totalUnits

        return Button {
            guard canMark else { return }
            store.markDone(planUUID: snapshot.uuid, on: day)
            refresh()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(done ? theme.accent : theme.border)

                Text(Self.dayFormatter.string(from: day))
                    .font(AppFont.regular(typ.callout))
                    .foregroundColor(theme.text)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canMark)
        .accessibilityLabel(Self.dayFormatter.string(from: day))
        .accessibilityValue(done ? "Отмечено" : "Не отмечено")
    }

    /// Перечитывает отметки плана из SwiftData — вызывается при открытии и
    /// после каждой отметки задним числом (без этого локальный `Set` не
    /// узнал бы про только что вставленную запись).
    private func refresh() {
        let planUUID = snapshot.uuid
        let context = PersistenceController.shared.container.mainContext
        let descriptor = FetchDescriptor<ReadingPlanUnitEntity>(
            predicate: #Predicate<ReadingPlanUnitEntity> { $0.planUUID == planUUID })
        let units = (try? context.fetch(descriptor)) ?? []
        completedDayKeys = Set(units.map { ISO8601DayFormatter.string(from: $0.completedOn) })
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, EEEE"
        return f
    }()
}
