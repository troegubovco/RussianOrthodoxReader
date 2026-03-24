import Foundation

// MARK: - Azbyka API Response Models

/// Response from the widget endpoint (no auth required)
/// GET https://azbyka.ru/days/widgets/presentations.json?date=YYYY-MM-DD&image=1&prevNextLinks=1
struct AzbykaWidgetResponse: Codable {
    let title: String?
    let abstractDate: String?
    let saints: [AzbykaSaintWidget]?
    let holidays: [AzbykaHolidayWidget]?
    let image: AzbykaImageWidget?
    let prevLink: String?
    let nextLink: String?
    
    enum CodingKeys: String, CodingKey {
        case title, saints, holidays, image
        case abstractDate = "abstract_date"
        case prevLink = "prev_link"
        case nextLink = "next_link"
    }
}

struct AzbykaSaintWidget: Codable {
    let title: String?
    let url: String?
}

struct AzbykaHolidayWidget: Codable {
    let title: String?
    let url: String?
}

struct AzbykaImageWidget: Codable {
    let src: String?
    let title: String?
}

// MARK: - Full API Response Models (requires registration + API key)

/// Response from /days/api/daytype/YYYY-MM-DD.json
struct AzbykaDayTypeResponse: Codable {
    let date: String?
    let dateOldStyle: String?
    let weekDay: String?
    let fastingLevel: Int?
    let fastingName: String?
    let weekName: String?
    let tone: Int?
    let readings: [AzbykaReading]?
    let saints: [AzbykaSaint]?
    let holidays: [AzbykaHoliday]?
    let ikons: [AzbykaIkon]?
    
    enum CodingKeys: String, CodingKey {
        case date, weekDay, tone, readings, saints, holidays, ikons
        case dateOldStyle = "date_old_style"
        case fastingLevel = "fasting_level"
        case fastingName = "fasting_name"
        case weekName = "week_name"
    }
}

struct AzbykaReading: Codable {
    let book: String?
    let chapter: String?
    let verse: String?
    let display: String?
    let type: String?  // "apostol", "gospel", etc.
}

struct AzbykaSaint: Codable {
    let id: Int?
    let title: String?
    let url: String?
    let saintType: String?
    
    enum CodingKeys: String, CodingKey {
        case id, title, url
        case saintType = "saint_type"
    }
}

struct AzbykaHoliday: Codable {
    let id: Int?
    let title: String?
    let url: String?
    let level: Int?
}

struct AzbykaIkon: Codable {
    let id: Int?
    let title: String?
    let url: String?
}

/// Response from /days/api/saints/YYYY-MM-DD.json
struct AzbykaSaintsResponse: Codable {
    let saints: [AzbykaSaint]?
}

/// Response from /days/api/holidays/YYYY-MM-DD.json
struct AzbykaHolidaysResponse: Codable {
    let holidays: [AzbykaHoliday]?
}

// MARK: - Unified Liturgical Day (internal model)

struct LiturgicalDay: Identifiable, Equatable {
    let id: Date
    let date: Date
    let dateOldStyle: String
    let weekName: String
    let apostolReadings: [String]
    let gospelReadings: [String]
    let saints: [String]
    let holidays: [String]
    let ikons: [String]
    let tone: Int?
    let isSunday: Bool
    let fastingLevel: FastingLevel
    let fastingName: String
    let imageURL: String?
    
    enum FastingLevel: Int, Equatable {
        case none = 0
        case regular = 1
        case strict = 2
        case fish = 3
        case oil = 4
        case unknown = -1
        
        var displayName: String {
            switch self {
            case .none: return ""
            case .regular: return "Постный день"
            case .strict: return "Строгий пост"
            case .fish: return "Разрешается рыба"
            case .oil: return "Разрешается елей"
            case .unknown: return "Пост"
            }
        }
    }
    
    static func == (lhs: LiturgicalDay, rhs: LiturgicalDay) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Azbyka Calendar Service

@MainActor
class AzbykaCalendarService: ObservableObject {
    
    @Published var todayData: LiturgicalDay?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    /// Cached data by date string "YYYY-MM-DD"
    private var cache: [String: LiturgicalDay] = [:]
    
    /// API key for the full API (set after registration approval)
    /// Store in Keychain in production; UserDefaults for dev
    var apiKey: String? {
        get { UserDefaults.standard.string(forKey: "azbyka_api_key") }
        set { UserDefaults.standard.set(newValue, forKey: "azbyka_api_key") }
    }
    
    private let session: URLSession
    private let baseURL = "https://azbyka.ru/days"
    
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Public API
    
    /// Fetch liturgical data for today
    func fetchToday() async {
        await fetchDay(date: Date())
        todayData = cache[Self.dateFormatter.string(from: Date())]
    }
    
    /// Fetch liturgical data for a specific date
    func fetchDay(date: Date) async {
        let dateString = Self.dateFormatter.string(from: date)
        
        // Return cached if available
        if cache[dateString] != nil { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let day: LiturgicalDay
            
            if let key = apiKey, !key.isEmpty {
                // Use the full authenticated API
                day = try await fetchDayFromFullAPI(dateString: dateString, date: date, apiKey: key)
            } else {
                // Fallback to widget endpoint (no auth)
                day = try await fetchDayFromWidget(dateString: dateString, date: date)
            }
            
            cache[dateString] = day
            
            if Calendar.current.isDateInToday(date) {
                todayData = day
            }
        } catch {
            errorMessage = "Ошибка загрузки: \(error.localizedDescription)"
            print("[AzbykaService] Error fetching \(dateString): \(error)")
        }
        
        isLoading = false
    }
    
    /// Fetch an entire month of data (for calendar view)
    func fetchMonth(year: Int, month: Int) async {
        let calendar = Calendar.current
        guard let startOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: startOfMonth) else { return }
        
        // Fetch all days in parallel with a TaskGroup, throttled
        await withTaskGroup(of: Void.self) { group in
            for day in range {
                if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                    let dateString = Self.dateFormatter.string(from: date)
                    // Skip already cached
                    if cache[dateString] != nil { continue }
                    
                    group.addTask { [weak self] in
                        await self?.fetchDay(date: date)
                    }
                }
            }
        }
    }
    
    /// Get cached data for a specific date (returns nil if not fetched yet)
    func getCachedDay(date: Date) -> LiturgicalDay? {
        cache[Self.dateFormatter.string(from: date)]
    }
    
    /// Get cached data for a day number within a month
    func getCachedDay(year: Int, month: Int, day: Int) -> LiturgicalDay? {
        let dateString = String(format: "%04d-%02d-%02d", year, month, day)
        return cache[dateString]
    }
    
    // MARK: - Widget Endpoint (No Auth)
    
    private func fetchDayFromWidget(dateString: String, date: Date) async throws -> LiturgicalDay {
        var components = URLComponents(string: "\(baseURL)/widgets/presentations.json")!
        components.queryItems = [
            URLQueryItem(name: "date", value: dateString),
            URLQueryItem(name: "image", value: "1"),
            URLQueryItem(name: "prevNextLinks", value: "1")
        ]
        
        guard let url = components.url else {
            throw AzbykaError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AzbykaError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        let widget = try JSONDecoder().decode(AzbykaWidgetResponse.self, from: data)
        
        let calendar = Calendar.current
        let isSunday = calendar.component(.weekday, from: date) == 1
        
        return LiturgicalDay(
            id: date,
            date: date,
            dateOldStyle: "",
            weekName: widget.title ?? "",
            apostolReadings: [],  // Widget doesn't provide readings
            gospelReadings: [],
            saints: widget.saints?.compactMap { $0.title } ?? [],
            holidays: widget.holidays?.compactMap { $0.title } ?? [],
            ikons: [],
            tone: nil,
            isSunday: isSunday,
            fastingLevel: .unknown,
            fastingName: "",
            imageURL: widget.image?.src
        )
    }
    
    // MARK: - Full API (Requires Auth)
    
    private func fetchDayFromFullAPI(dateString: String, date: Date, apiKey: String) async throws -> LiturgicalDay {
        // Fetch daytype which includes most info
        let dayTypeURL = URL(string: "\(baseURL)/api/daytype/\(dateString).json")!
        var request = URLRequest(url: dayTypeURL)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AzbykaError.httpError(0)
        }
        
        // If auth fails, fall back to widget
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            print("[AzbykaService] Auth failed (\(httpResponse.statusCode)), falling back to widget")
            return try await fetchDayFromWidget(dateString: dateString, date: date)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AzbykaError.httpError(httpResponse.statusCode)
        }
        
        let dayType = try JSONDecoder().decode(AzbykaDayTypeResponse.self, from: data)
        
        let calendar = Calendar.current
        let isSunday = calendar.component(.weekday, from: date) == 1
        
        // Separate readings by type
        let apostol = dayType.readings?
            .filter { $0.type?.lowercased() == "apostol" }
            .compactMap { $0.display } ?? []
        let gospel = dayType.readings?
            .filter { $0.type?.lowercased() == "gospel" }
            .compactMap { $0.display } ?? []
        
        return LiturgicalDay(
            id: date,
            date: date,
            dateOldStyle: dayType.dateOldStyle ?? "",
            weekName: dayType.weekName ?? "",
            apostolReadings: apostol,
            gospelReadings: gospel,
            saints: dayType.saints?.compactMap { $0.title } ?? [],
            holidays: dayType.holidays?.compactMap { $0.title } ?? [],
            ikons: dayType.ikons?.compactMap { $0.title } ?? [],
            tone: dayType.tone,
            isSunday: isSunday,
            fastingLevel: LiturgicalDay.FastingLevel(rawValue: dayType.fastingLevel ?? 0) ?? .none,
            fastingName: dayType.fastingName ?? "",
            imageURL: nil
        )
    }
    
    // MARK: - Errors
    
    enum AzbykaError: LocalizedError {
        case invalidURL
        case httpError(Int)
        case decodingError
        
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Неверный URL"
            case .httpError(let code): return "Ошибка сервера: \(code)"
            case .decodingError: return "Ошибка разбора данных"
            }
        }
    }
}
