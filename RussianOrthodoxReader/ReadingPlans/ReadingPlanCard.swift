import SwiftUI

// MARK: - Русское склонение чисел (§5 akathist_psalter_design.md)

/// `internal`, не `private` — переиспользуется `ReadingPlanCard`,
/// `ReadingPlanSetupSheet`, `ReadingPlanCatchUpSheet` и `MyReadingsCard`:
/// у всех своя строка с числом дней, согласование одно и то же.
enum ReadingPlanWording {
    /// «1 день» / «2 дня» / «5 дней».
    static func days(_ n: Int) -> String {
        "\(n) \(daysWord(n))"
    }

    /// «Пропущено 2 дня» — «Пропущено» не согласуется с числом (краткая форма
    /// среднего рода, как «сделано», «отмечено»), только число дней внутри.
    static func missedDays(_ n: Int) -> String {
        "Пропущено \(days(n))"
    }

    private static func daysWord(_ n: Int) -> String {
        let mod100 = n % 100
        if (11...14).contains(mod100) { return "дней" }
        switch n % 10 {
        case 1: return "день"
        case 2, 3, 4: return "дня"
        default: return "дней"
        }
    }

    /// Строка-приглашение под заголовком «Читать ежедневно» на карточке-CTA
    /// (`ReadingPlanCard.ctaCard`) — та же формулировка §3.3, что и в
    /// `ReadingPlanSetupSheet.rubricText(for:)`, но короче, для одной строки
    /// на самом видном месте страницы, а не внутри листа настройки.
    static func ctaSubtitle(for prayer: Prayer) -> String {
        if prayer.categorySlug == "akafisty" {
            return "7, 12 или 40 дней — весь акафист каждый день"
        }
        if prayer.slug.hasPrefix("psaltir.kafizma-") {
            return "Псалтирь по кафизмам за 20 дней"
        }
        if prayer.categorySlug == "canons", prayer.slug.hasPrefix("canons.velikij-kanon-") {
            return "Четыре части — первая седмица поста"
        }
        return "Читать эту молитву каждый день"
    }
}

// MARK: - Карточка плана на экране молитвы

/// Карточка плана чтения — над `PrayerLanguagePicker` в `PrayerDetailView`,
/// видна только при активном плане по этой молитве (§5.2 п.1). Полностью
/// самодостаточна: сама находит план по `prayer.slug` через
/// `ReadingPlansStore.plan(forTarget:)` и подписана на его изменения — рисует
/// `EmptyView`, если плана нет.
///
/// Нажатие на карточку открывает `ReadingPlanSetupSheet` в режиме
/// «план уже есть» (прогресс + «Остановить чтение» / «Начать заново» — §5.3).
///
/// Если плана ещё нет, но текст подходит под план (см.
/// `ReadingPlanSetupSheet.isVisiblyEligible(prayer:)`), карточка вместо
/// `EmptyView` рисует компактный призыв «Читать ежедневно» — прежде эта
/// возможность была видна только тонкой строкой под текстом молитвы, что
/// пользователи не замечали.
struct ReadingPlanCard: View {
    let prayer: Prayer

    @ObservedObject private var store = ReadingPlansStore.shared
    @Environment(\.userFontSize) private var userFontSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let theme = OrthodoxColors.fallback

    @State private var showSetup = false
    @State private var showCatchUp = false
    @State private var staleAcknowledged = false
    /// Не-nil — открыт `confirmationDialog` подтверждения остановки плана
    /// с ellipsis-меню карточки (не путать со «Остановить» в блёклой
    /// «Давно не открывали», которая ничего не подтверждает, — короткий
    /// путь для стабильно пропускаемого плана и так достаточно осознан).
    @State private var stopCandidateUUID: String?

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    private var snapshot: ReadingPlanSnapshot? {
        store.plan(forTarget: prayer.slug)
    }

    var body: some View {
        Group {
            if let snapshot {
                card(for: snapshot)
            } else if ReadingPlanSetupSheet.isVisiblyEligible(prayer: prayer) {
                ctaCard
            }
        }
        .sheet(isPresented: $showSetup) {
            ReadingPlanSetupSheet(prayer: prayer, candidateKinds: ReadingPlanSetupSheet.candidateKinds(for: prayer))
        }
        .sheet(isPresented: $showCatchUp) {
            if let snapshot {
                ReadingPlanCatchUpSheet(snapshot: snapshot)
            }
        }
        .confirmationDialog(
            "Остановить чтение?",
            isPresented: Binding(
                get: { stopCandidateUUID != nil },
                set: { if !$0 { stopCandidateUUID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Остановить чтение", role: .destructive) {
                if let uuid = stopCandidateUUID {
                    store.stop(planUUID: uuid)
                }
                stopCandidateUUID = nil
            }
            Button("Отмена", role: .cancel) { stopCandidateUUID = nil }
        } message: {
            Text("Отметки сохранятся в истории, кольцо исчезнет.")
        }
    }

    // MARK: - Призыв начать план (плана ещё нет)

    private var ctaCard: some View {
        Button {
            showSetup = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(theme.accent)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Читать ежедневно")
                        .font(AppFont.medium(typ.callout))
                        .foregroundColor(theme.text)
                    Text(ReadingPlanWording.ctaSubtitle(for: prayer))
                        .font(AppFont.regular(typ.footnote))
                        .foregroundColor(theme.muted)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.muted)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Читать ежедневно")
        .accessibilityHint(ReadingPlanWording.ctaSubtitle(for: prayer))
    }

    // MARK: - Карточка активного плана

    private func card(for snapshot: ReadingPlanSnapshot) -> some View {
        let isComplete = snapshot.completedCount >= snapshot.totalUnits

        return ZStack(alignment: .topTrailing) {
            Button {
                showSetup = true
            } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 20) {
                        ring(for: snapshot, isComplete: isComplete)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(snapshot.title)
                                .font(AppFont.medium(typ.callout))
                                .foregroundColor(theme.text)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)

                            if isComplete {
                                Text("Завершено · \(ReadingPlanWording.days(snapshot.totalUnits))")
                                    .font(AppFont.regular(typ.footnote))
                                    .foregroundColor(theme.muted)
                            } else {
                                Text(snapshot.doneToday ? "Прочитано сегодня" : snapshot.nextUnitLabel)
                                    .font(AppFont.regular(typ.footnote))
                                    .foregroundColor(theme.muted)

                                if let endDate = snapshot.endDate {
                                    Text("до \(Self.endDateFormatter.string(from: endDate))")
                                        .font(AppFont.regular(typ.caption))
                                        .foregroundColor(theme.muted)
                                }
                            }
                        }

                        // minLength вместо 0 — резервирует место под кнопку
                        // «…» в углу карточки (overlay поверх, не часть этого
                        // HStack), чтобы заголовок не заезжал под неё; узкий
                        // экран iPhone и без того съедает ⌀108 кольцом, так
                        // что запас — минимальный, под сам значок, а не под
                        // весь тап-таргет кнопки.
                        Spacer(minLength: 22)
                    }

                    if !isComplete {
                        if snapshot.missedDays > 30 && !staleAcknowledged {
                            staleNotice(snapshot)
                        } else if snapshot.missedDays > 0 {
                            Button {
                                showCatchUp = true
                            } label: {
                                Text(ReadingPlanWording.missedDays(snapshot.missedDays))
                                    .font(AppFont.regular(typ.caption))
                                    .foregroundColor(theme.muted)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.title)
            .accessibilityValue(
                "Прочитано \(snapshot.completedCount) из \(snapshot.totalUnits) дней. "
                + (snapshot.doneToday ? "Сегодня уже прочитано." : "Сегодня ещё не прочитано.")
            )

            planMenu(for: snapshot)
                .padding(12)
        }
    }

    /// Кнопка «…» в углу карточки активного плана — отдельный элемент
    /// поверх карточки (`ZStack`, не вложенный `Button` внутри `Button`),
    /// чтобы не спорить с самой карточкой за жест нажатия.
    private func planMenu(for snapshot: ReadingPlanSnapshot) -> some View {
        Menu {
            Button(role: .destructive) {
                stopCandidateUUID = snapshot.uuid
            } label: {
                Label("Остановить чтение", systemImage: "stop.circle")
            }
            if snapshot.missedDays > 0 {
                Button {
                    showCatchUp = true
                } label: {
                    Label("Пропущенные дни…", systemImage: "calendar.badge.clock")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(theme.muted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Ещё")
    }

    /// «Давно не открывали» — план пропущен больше 30 дней подряд (§5.3):
    /// спокойная строка, никакого автоархивирования.
    private func staleNotice(_ snapshot: ReadingPlanSnapshot) -> some View {
        HStack(spacing: 12) {
            Text("Давно не открывали")
                .font(AppFont.regular(typ.caption))
                .foregroundColor(theme.muted)

            Spacer(minLength: 0)

            Button("Продолжить") {
                staleAcknowledged = true
            }
            .font(AppFont.medium(typ.caption))
            .foregroundColor(theme.accent)
            .buttonStyle(.plain)

            Button("Остановить") {
                store.stop(planUUID: snapshot.uuid)
            }
            .font(AppFont.medium(typ.caption))
            .foregroundColor(theme.muted)
            .buttonStyle(.plain)
        }
    }

    private func ring(for snapshot: ReadingPlanSnapshot, isComplete: Bool) -> some View {
        let todayHint = (snapshot.doneToday || isComplete || snapshot.totalUnits <= 0)
            ? 0.0 : (1.0 / Double(snapshot.totalUnits))

        return ProgressRingView(
            progress: snapshot.progress,
            diameter: 108,
            lineWidth: 8,
            stroke: theme.accent,
            todayHint: todayHint,
            isComplete: isComplete
        ) {
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(theme.accent)
            } else {
                VStack(spacing: 2) {
                    HStack(spacing: 3) {
                        Text("\(snapshot.nextUnitIndex + 1)")
                            .font(AppFont.semiBold(typ.title))
                            .foregroundColor(theme.text)
                        if snapshot.doneToday {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.accent)
                        }
                    }
                    Text("из \(snapshot.totalUnits)")
                        .font(AppFont.regular(typ.caption))
                        .foregroundColor(theme.muted)
                }
            }
        }
    }

    private static let endDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f
    }()
}

// MARK: - Кнопка «Прочитано сегодня»

/// Полноширинная кнопка под текстом молитвы (§5.2 п.5) — только при активном
/// плане и неотмеченном сегодняшнем дне. Лёгкая тактильная отдача при отметке
/// (§5.3) — платформенно и по доступности версии ОС, macOS не вибрирует, но
/// модификатор там безвреден (просто не производит эффекта).
struct MarkPlanDoneButton: View {
    let planUUID: String

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    @State private var successTrigger = false

    var body: some View {
        Button {
            ReadingPlansStore.shared.markDone(planUUID: planUUID)
            successTrigger.toggle()
        } label: {
            Text("Прочитано сегодня")
                .font(AppFont.medium(typ.callout))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.accent)
                )
        }
        .buttonStyle(.plain)
        .modifier(PlanDoneSensoryFeedback(trigger: successTrigger))
        .accessibilityHint("Отметить сегодняшнее чтение")
    }
}

/// `.sensoryFeedback(.success, trigger:)` — только iOS 17+ (проект целится в
/// iOS 18, так что доступность всегда выполнена, но модификатор явно
/// ограничен платформой и версией на случай понижения деплой-таргета).
private struct PlanDoneSensoryFeedback: ViewModifier {
    let trigger: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            content.sensoryFeedback(.success, trigger: trigger)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if DEBUG
#Preview("Карточка плана") {
    ScrollView {
        VStack(spacing: 20) {
            ReadingPlanCard(prayer: Prayer(
                id: 1, slug: "akafisty.akafist-iisusu-sladchajshemu", categorySlug: "akafisty",
                title: "Акафист Иисусу Сладчайшему", subtitle: nil,
                textCS: "", textRU: nil, takesNames: false, nameCase: nil, nameList: nil))
        }
        .padding(24)
    }
    .background(OrthodoxColors.fallback.background)
}
#endif
