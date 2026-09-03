import Foundation

/// Границы четырёх многодневных постов, посчитанные в коде (§8.1 —
/// `moveable_cycle.fasting` для этого непригодна: колонка неполна и как раз
/// не размечает первые четыре дня Великого поста, ровно те, что нужны плану
/// по Великому канону).
///
/// nonisolated enum ReadingPlanKind (`ReadingPlanModels.swift`) вызывает
/// `greatLentStart(year:)` из чисто вычислительных мест — держим весь этот
/// файл nonisolated по той же причине.
///
/// Пасхалия здесь **продублирована** из `PaschalCalculator`
/// (`RussianOrthodoxReader/LiturgicalCalendar.swift:86`), а не переиспользована:
/// этот файл лежит в `Shared/` и компилируется в часовую цель тоже, а
/// `LiturgicalCalendar.swift` — только в основной таргет
/// (`PBXFileSystemSynchronizedRootGroup` не включает папку `RussianOrthodoxReader/`
/// в watch-таргет, см. project.pbxproj). Алгоритм и формула
/// юлианско-григорианского смещения — те же самые; при правке одной копии
/// нужно поправить и вторую.
nonisolated enum FastKind: String, CaseIterable, Hashable {
    case greatLent = "greatLent"
    case apostles = "apostles"
    case dormition = "dormition"
    case nativity = "nativity"

    /// Именительный падеж («Великий пост») — для заголовков.
    var displayName: String {
        switch self {
        case .greatLent: return "Великий пост"
        case .apostles: return "Петров пост"
        case .dormition: return "Успенский пост"
        case .nativity: return "Рождественский пост"
        }
    }

    /// Родительный падеж («Великого поста») — для кнопки «до конца …».
    var genitiveName: String {
        switch self {
        case .greatLent: return "Великого поста"
        case .apostles: return "Петрова поста"
        case .dormition: return "Успенского поста"
        case .nativity: return "Рождественского поста"
        }
    }
}

/// Один период поста с границами (включительно).
nonisolated struct FastPeriod: Hashable {
    let kind: FastKind
    /// startOfDay первого дня поста.
    let start: Date
    /// startOfDay последнего дня поста (включительно).
    let end: Date

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= start && day <= end
    }

    /// Дней от `date` (включительно) до конца поста (включительно). Если
    /// `date` раньше начала поста, считает от `date`, а не от `start` — это
    /// ровно то число, что показывается под кнопкой «до конца поста»
    /// (§3.3): длина плана, если начать его сегодня.
    func daysRemaining(from date: Date = Date(), calendar: Calendar = .current) -> Int {
        let day = calendar.startOfDay(for: date)
        let span = calendar.dateComponents([.day], from: day, to: end).day ?? 0
        return max(1, span + 1)
    }
}

nonisolated enum FastPeriods {
    /// Четыре поста, «принадлежащих» году `year`: Великий и Петров — по
    /// Пасхе этого года; Успенский — фиксированные григорианские даты этого
    /// года; Рождественский — с 28 ноября `year` по 6 января `year + 1`
    /// (пересекает Новый год).
    static func periods(forYear year: Int) -> [FastPeriod] {
        let calendar = Calendar.current
        let easter = calendar.startOfDay(for: pascha(year: year))

        let greatLentStartDate = calendar.date(byAdding: .day, value: -48, to: easter)!
        let greatLentEndDate = calendar.date(byAdding: .day, value: -1, to: easter)!

        let apostlesStartDate = calendar.date(byAdding: .day, value: 57, to: easter)!
        let apostlesEndDate = calendar.startOfDay(for: dateFrom(year: year, month: 7, day: 11))

        let dormitionStart = calendar.startOfDay(for: dateFrom(year: year, month: 8, day: 14))
        let dormitionEnd = calendar.startOfDay(for: dateFrom(year: year, month: 8, day: 27))

        let nativityStart = calendar.startOfDay(for: dateFrom(year: year, month: 11, day: 28))
        let nativityEnd = calendar.startOfDay(for: dateFrom(year: year + 1, month: 1, day: 6))

        var result: [FastPeriod] = [
            FastPeriod(kind: .greatLent, start: greatLentStartDate, end: greatLentEndDate),
            FastPeriod(kind: .dormition, start: dormitionStart, end: dormitionEnd),
            FastPeriod(kind: .nativity, start: nativityStart, end: nativityEnd)
        ]
        // Петров пост может выродиться в ноль (или отрицательную длину) при
        // очень поздней Пасхе — тогда его в этом году нет (§8.1: 8…42 дня в
        // обычном случае).
        if apostlesStartDate <= apostlesEndDate {
            result.append(FastPeriod(kind: .apostles, start: apostlesStartDate, end: apostlesEndDate))
        }
        return result
    }

    /// Понедельник 1-й седмицы Великого поста — начало плана по Великому
    /// канону (§4.1).
    static func greatLentStart(year: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -48, to: Calendar.current.startOfDay(for: pascha(year: year)))!
    }

    /// Текущий пост (если `date` в его границах) либо ближайший, начинающийся
    /// не позже чем через `maxDaysAhead` дней. `nil`, если ни то, ни другое —
    /// правило показа кнопки «до конца поста» из §3.3.
    static func currentOrUpcoming(from date: Date = Date(), maxDaysAhead: Int = 14) -> FastPeriod? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: today)
        // Год ±1 — переход через Новый год (Рождественский пост) и случаи,
        // когда Пасха соседнего года кладёт Великий/Петров пост рядом с
        // календарной границей `year`.
        let candidates = (year - 1...year + 1).flatMap { periods(forYear: $0) }

        if let current = candidates.first(where: { $0.contains(today, calendar: calendar) }) {
            return current
        }

        return candidates
            .filter { $0.start > today }
            .filter { (calendar.dateComponents([.day], from: today, to: $0.start).day ?? .max) <= maxDaysAhead }
            .sorted { $0.start < $1.start }
            .first
    }

    /// «до конца Великого поста» и т. п. (§3.3).
    static func buttonTitle(for kind: FastKind) -> String {
        "до конца \(kind.genitiveName)"
    }

    /// «41 день» / «2 дня» / «5 дней» — подпись под кнопкой.
    static func daysRemainingLabel(for period: FastPeriod, from date: Date = Date()) -> String {
        let days = period.daysRemaining(from: date)
        return "\(days) \(daysWord(days))"
    }

    // MARK: - Пасхалия (продублирована — см. заголовок файла)

    private static func pascha(year: Int) -> Date {
        let a = year % 4
        let b = year % 7
        let c = year % 19
        let d = (19 * c + 15) % 30
        let e = (2 * a + 4 * b - d + 34) % 7
        let month = (d + e + 114) / 31
        let day = ((d + e + 114) % 31) + 1

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day + julianToGregorianOffset(year: year)
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func julianToGregorianOffset(year: Int) -> Int {
        let century = year / 100
        return century - century / 4 - 2
    }

    private static func dateFrom(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components) ?? Date()
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
}

#if DEBUG
extension FastPeriods {
    /// Проверяет расчёт границ поста на 2026 годе (Пасха 12 апреля):
    /// Великий пост 23 февраля — 11 апреля, Петров пост 8 июня — 11 июля
    /// (см. §8.1 проектной спецификации и задание пакета B).
    static func runSelfTest() {
        let df: DateFormatter = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        let periods2026 = periods(forYear: 2026)

        guard let lent = periods2026.first(where: { $0.kind == .greatLent }) else {
            assertionFailure("FastPeriods: не нашли Великий пост 2026")
            return
        }
        assert(df.string(from: lent.start) == "2026-02-23",
               "FastPeriods: Великий пост 2026 должен начаться 23 февраля, получили \(df.string(from: lent.start))")
        assert(df.string(from: lent.end) == "2026-04-11",
               "FastPeriods: Великий пост 2026 должен закончиться 11 апреля, получили \(df.string(from: lent.end))")

        guard let apostles = periods2026.first(where: { $0.kind == .apostles }) else {
            assertionFailure("FastPeriods: не нашли Петров пост 2026")
            return
        }
        assert(df.string(from: apostles.start) == "2026-06-08",
               "FastPeriods: Петров пост 2026 должен начаться 8 июня, получили \(df.string(from: apostles.start))")
        assert(df.string(from: apostles.end) == "2026-07-11",
               "FastPeriods: Петров пост 2026 должен закончиться 11 июля, получили \(df.string(from: apostles.end))")

        let dormition = periods2026.first { $0.kind == .dormition }
        assert(dormition != nil
               && df.string(from: dormition!.start) == "2026-08-14"
               && df.string(from: dormition!.end) == "2026-08-27",
               "FastPeriods: Успенский пост 2026 должен быть 14–27 августа")

        let nativity = periods2026.first { $0.kind == .nativity }
        assert(nativity != nil
               && df.string(from: nativity!.start) == "2026-11-28"
               && df.string(from: nativity!.end) == "2027-01-06",
               "FastPeriods: Рождественский пост 2026 должен быть 28 ноября — 6 января 2027")
    }
}
#endif
