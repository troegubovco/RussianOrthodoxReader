import Foundation

// MARK: - Вид плана чтения

/// Вид плана чтения «Мои чтения» — см. §3.3/§4 проектной спецификации
/// (akathist_psalter_design.md). Определяет, как считать текущую единицу
/// плана (счётчик, не календарная сетка — §4.1), что открывать по ней и
/// какой подписью её показывать.
///
/// nonisolated: используется как из MainActor-кода (ReadingPlansStore,
/// SwiftUI-экраны на обеих платформах), так и в чисто вычислительных
/// местах, где изоляция по умолчанию (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor)
/// была бы лишней связью.
nonisolated enum ReadingPlanKind: Hashable {
    /// Любая молитва, читаемая ежедневно оговорённое число дней: акафист,
    /// покаянный канон, Псалтирь по кафизмам через молитвослов и т. п.
    case dailyPrayer(slug: String)
    /// Псалтирь по кафизмам, единица — одна кафизма в день (20 единиц на круг).
    case psalterKathisma
    /// Псалтирь по «Славам», единица — одна «Слава» (60 единиц на круг).
    case psalterSlava
    /// Великий покаянный канон прп. Андрея Критского, 4 части с жёсткими датами.
    case greatCanon

    /// Строковый код для хранения (`ReadingPlanEntity.kindRaw`,
    /// `WatchSnapshot.Plan.kind`) и для маршрутизации в `make(rawKind:subjectSlug:)`.
    var rawKind: String {
        switch self {
        case .dailyPrayer: return "dailyPrayer"
        case .psalterKathisma: return "psalterKathisma"
        case .psalterSlava: return "psalterSlava"
        case .greatCanon: return "greatCanon"
        }
    }

    /// slug молитвы — есть только у `dailyPrayer`.
    var subjectSlug: String? {
        if case .dailyPrayer(let slug) = self { return slug }
        return nil
    }

    /// Восстанавливает вид плана из хранимых полей. `nil`, если `rawKind`
    /// не распознан или `dailyPrayer` пришёл без `subjectSlug`.
    static func make(rawKind: String, subjectSlug: String?) -> ReadingPlanKind? {
        switch rawKind {
        case "dailyPrayer":
            guard let subjectSlug else { return nil }
            return .dailyPrayer(slug: subjectSlug)
        case "psalterKathisma":
            return .psalterKathisma
        case "psalterSlava":
            return .psalterSlava
        case "greatCanon":
            return .greatCanon
        default:
            return nil
        }
    }

    /// Жёсткая календарная дата единицы, если она есть (только `greatCanon`:
    /// части читаются в конкретные дни 1-й седмицы Великого поста, а не по
    /// личному счёту — см. §4.1). `nil` для остальных видов.
    func dueDate(for unitIndex: Int, planStart: Date) -> Date? {
        guard self == .greatCanon else { return nil }
        let calendar = Calendar.current
        let year = calendar.component(.year, from: planStart)
        // Если startDate плана почему-то не попал точно в год, к которому
        // относится Великий пост (пограничные случаи создания плана на
        // стыке лет), берём понедельник 1-й седмицы, ближайший к planStart.
        let candidates = [year - 1, year, year + 1].map { FastPeriods.greatLentStart(year: $0) }
        let start = candidates.min {
            abs($0.timeIntervalSince(planStart)) < abs($1.timeIntervalSince(planStart))
        } ?? candidates[1]
        return calendar.date(byAdding: .day, value: unitIndex, to: calendar.startOfDay(for: start))
    }

    /// Что открыть по этой единице плана.
    func target(for unitIndex: Int) -> ReadingPlanTarget {
        switch self {
        case .dailyPrayer(let slug):
            return .prayer(slug: slug)
        case .psalterKathisma:
            let kathisma = (unitIndex % 20) + 1
            return .prayer(slug: "psaltir.kafizma-\(kathisma)")
        case .psalterSlava:
            let kathisma = (unitIndex / 3 % 20) + 1
            let slava = (unitIndex % 3) + 1
            return .kathismaSlava(kathisma: kathisma, slava: slava)
        case .greatCanon:
            let index = min(max(unitIndex, 0), Self.greatCanonSlugs.count - 1)
            return .prayer(slug: Self.greatCanonSlugs[index])
        }
    }

    /// Подпись единицы («Кафизма 13», «День 12 из 40»).
    func unitLabel(for unitIndex: Int, total: Int) -> String {
        switch self {
        case .dailyPrayer:
            return "День \(unitIndex + 1) из \(total)"
        case .psalterKathisma:
            let kathisma = (unitIndex % 20) + 1
            return "Кафизма \(kathisma)"
        case .psalterSlava:
            let kathisma = (unitIndex / 3 % 20) + 1
            let slava = (unitIndex % 3) + 1
            return "Кафизма \(kathisma), Слава \(slava)"
        case .greatCanon:
            let index = min(max(unitIndex, 0), Self.greatCanonLabels.count - 1)
            return Self.greatCanonLabels[index]
        }
    }

    // Slug'и и подписи частей Великого канона — Пн…Чт 1-й седмицы (§2.3/A3).
    private static let greatCanonSlugs = [
        "canons.velikij-kanon-ponedelnik",
        "canons.velikij-kanon-vtornik",
        "canons.velikij-kanon-sredu",
        "canons.velikij-kanon-chetverg"
    ]
    private static let greatCanonLabels = [
        "Понедельник 1-й седмицы",
        "Вторник 1-й седмицы",
        "Среда 1-й седмицы",
        "Четверг 1-й седмицы"
    ]
}

// MARK: - Цель единицы плана

/// Что открывает кнопка «Читать» для конкретной единицы плана.
nonisolated enum ReadingPlanTarget: Hashable {
    /// Открыть молитву целиком (акафист, часть канона, кафизма ЦС).
    case prayer(slug: String)
    /// Открыть кафизму ЦС и прокрутить к конкретной «Славе» внутри неё
    /// (используется `psalterSlava` — своей молитвы на «Славу» нет, все три
    /// лежат внутри текста кафизмы).
    case kathismaSlava(kathisma: Int, slava: Int)

    /// slug молитвы в молитвослове, которую нужно открыть — для `prayer`
    /// напрямую, для `kathismaSlava` это slug кафизмы, содержащей эту «Славу».
    var prayerSlug: String {
        switch self {
        case .prayer(let slug):
            return slug
        case .kathismaSlava(let kathisma, _):
            return "psaltir.kafizma-\(kathisma)"
        }
    }
}

// MARK: - Снимок плана для отрисовки

/// Плоская структура для UI — готова к отрисовке без обращения к SwiftData.
/// Строится `ReadingPlansStore.reload()` из `ReadingPlanEntity` + его единиц.
struct ReadingPlanSnapshot: Identifiable, Hashable {
    let uuid: String
    let kind: ReadingPlanKind
    /// Готовая строка названия («Акафист Иисусу Сладчайшему», «Псалтирь по
    /// кафизмам») — экран не ходит за ней в БД молитв повторно.
    let title: String
    let totalUnits: Int
    let completedCount: Int
    /// Есть ли отметка с `completedOn`, чей календарный день (см.
    /// `ISO8601DayFormatter`) совпадает с сегодняшним.
    let doneToday: Bool
    /// `max(0, дней_с_начала − completedCount)` — сколько дней пропущено;
    /// ничем не наказывает, только для отображения.
    let missedDays: Int
    /// Следующая свободная единица (`max(index) + 1`, где index — индексы
    /// уже существующих отметок; см. `ReadingPlansStore`).
    let nextUnitIndex: Int
    let nextUnitLabel: String
    /// Материализованная дата окончания плана, если задана (см. §4.3 —
    /// пересчитывается только при создании плана, не при каждом чтении).
    let endDate: Date?
    /// `completedCount / totalUnits`, clamped к [0, 1].
    let progress: Double

    var id: String { uuid }
}

// MARK: - Данные для напоминаний (§4.7)

/// Всё, что нужно `ReadingReminderScheduler.applyPlanReminders(_:)`, чтобы
/// спланировать уведомления по одному плану — без обращения к SwiftData.
struct ReadingPlanReminderInfo: Hashable {
    let uuid: String
    /// Заголовок уведомления («Акафист Иисусу Сладчайшему»).
    let title: String
    /// Тело уведомления («День 12 из 40», «Кафизма 13»).
    let nextUnitLabel: String
    /// "HH:mm"
    let reminderTime: String
    /// Если уже отмечено сегодня — сегодняшнее уведомление не планируется
    /// (снимается сразу отдельным вызовом `cancelTodayPlanReminder`, здесь
    /// же просто не создаётся заново при пересборке очереди).
    let doneToday: Bool
}

// MARK: - Маршрутизация CloudKit-записей (§4.5)

/// Префиксы `recordName`, по которым `PrayersSyncService` определяет тип
/// записи. Вынесены сюда (а не продублированы в сервисе и в
/// `ReadingPlansStore`), чтобы обе стороны не могли разойтись в написании.
enum ReadingPlanSync {
    /// CKRecord.recordName для `ReadingPlan` = `planPrefix + ReadingPlanEntity.uuid`.
    static let planPrefix = "plan-"
    /// `ReadingPlanUnitEntity.recordName` уже содержит этот префикс целиком
    /// (`"planunit-<planUUID>-<index>"`) — используется как есть, без
    /// дополнительной склейки.
    static let planUnitPrefix = "planunit-"
}

// MARK: - Календарный день устройства (§8.7)

/// Форматирует дату в календарный день устройства (`"yyyy-MM-dd"`) и обратно.
/// Единицы плана дедуплицируются по этой строке, а не по `Date` — часы и
/// телефон могут быть в разных часовых поясах, и сравнение по `Date` дало бы
/// ложное расхождение на границе суток. Общий формат с
/// `LiturgicalRepository.dateKey(from:)` (RussianOrthodoxReader/Data/…, не
/// доступен часам), поэтому продублирован здесь, в Shared/.
nonisolated enum ISO8601DayFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
