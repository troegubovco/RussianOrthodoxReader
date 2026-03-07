import Foundation
import Combine

@MainActor
final class CalendarViewModel: ObservableObject {
    @Published var days: [Int: LiturgicalDay] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let repository: LiturgicalRepositoryProtocol

    init(repository: LiturgicalRepositoryProtocol? = nil) {
        self.repository = repository ?? LiturgicalRepository.shared
    }

    func loadMonth(year: Int, month: Int) async {
        isLoading = true
        defer { isLoading = false }

        let calendar = Calendar.current
        guard let startDate = calendar.date(from: DateComponents(year: year, month: month + 1, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: startDate) else {
            days = [:]
            errorMessage = "Не удалось вычислить диапазон дат"
            return
        }

        // Build date pairs and precompute fallback values on the main actor
        let dayDates: [(day: Int, date: Date, fallbackLevel: LiturgicalDay.FastingLevel, isSunday: Bool)] = range.compactMap { day in
            guard let date = calendar.date(from: DateComponents(year: year, month: month + 1, day: day)) else { return nil }
            let level = LiturgicalCalendar.fallbackFastingLevel(for: date)
            let sunday = LiturgicalCalendar.isSunday(date)
            return (day, date, level, sunday)
        }

        let repo = repository
        // Fetch all days concurrently (max 6 at a time to avoid overwhelming the server)
        let fetched: [(Int, LiturgicalDay)] = await withTaskGroup(of: (Int, LiturgicalDay).self) { group in
            var results: [(Int, LiturgicalDay)] = []
            var running = 0
            var index = 0

            while index < dayDates.count || running > 0 {
                // Launch up to 6 concurrent tasks
                while running < 6 && index < dayDates.count {
                    let entry = dayDates[index]
                    index += 1
                    running += 1
                    group.addTask {
                        do {
                            let liturgicalDay = try await repo.getDay(date: entry.date)
                            return (entry.day, liturgicalDay)
                        } catch {
                            return (entry.day, LiturgicalDay(
                                id: entry.date,
                                date: entry.date,
                                apostolReading: "—",
                                gospelReading: "—",
                                saintOfDay: "Нет оффлайн-данных",
                                tone: nil,
                                isSunday: entry.isSunday,
                                isFastDay: entry.fallbackLevel != .none,
                                fastingLevel: entry.fallbackLevel,
                                references: [],
                                isFromCache: true,
                                dataAvailabilityMessage: error.localizedDescription
                            ))
                        }
                    }
                }
                if let result = await group.next() {
                    results.append(result)
                    running -= 1
                }
            }
            return results
        }

        var result: [Int: LiturgicalDay] = [:]
        var encounteredErrors = false
        for (day, liturgicalDay) in fetched {
            result[day] = liturgicalDay
            if liturgicalDay.dataAvailabilityMessage != nil {
                encounteredErrors = true
            }
        }

        days = result
        errorMessage = encounteredErrors ? "Часть дат не загружена оффлайн" : nil

        Task { @MainActor in
            await repository.prefetchWindow(centerDate: startDate)
        }
    }
}
