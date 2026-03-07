import Foundation

struct OrthocalVerseDTO: Codable, Hashable {
    let book: String
    let chapter: Int
    let verse: Int
    let content: String?
}

struct OrthocalReadingDTO: Codable, Hashable {
    let source: String?
    let book: String?
    let description: String?
    let display: String?
    let shortDisplay: String?
    let passage: [OrthocalVerseDTO]

    enum CodingKeys: String, CodingKey {
        case source
        case book
        case description
        case display
        case shortDisplay = "short_display"
        case passage
    }
}

struct OrthocalStoryDTO: Codable, Hashable {
    let title: String
}

struct OrthocalDayDTO: Decodable, Hashable {
    let year: Int
    let month: Int
    let day: Int
    let tone: Int?
    let fastingDescription: String?
    let fastingException: String?
    let summaryTitle: String?
    let saints: [String]
    let readings: [OrthocalReadingDTO]

    enum CodingKeys: String, CodingKey {
        case year
        case month
        case day
        case tone
        case fastingDescription = "fast_level_desc"
        case fastingException = "fast_exception_desc"
        case summaryTitle = "summary_title"
        case saints
        case stories
        case readings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = try c.decode(Int.self, forKey: .year)
        month = try c.decode(Int.self, forKey: .month)
        day = try c.decode(Int.self, forKey: .day)

        tone = try c.decodeIfPresent(Int.self, forKey: .tone)
        fastingDescription = try c.decodeIfPresent(String.self, forKey: .fastingDescription)
        fastingException = try c.decodeIfPresent(String.self, forKey: .fastingException)
        summaryTitle = try c.decodeIfPresent(String.self, forKey: .summaryTitle)

        if let decodedSaints = try c.decodeIfPresent([String].self, forKey: .saints), !decodedSaints.isEmpty {
            saints = decodedSaints
        } else if let stories = try c.decodeIfPresent([OrthocalStoryDTO].self, forKey: .stories) {
            saints = stories.map(\.title)
        } else {
            saints = []
        }

        readings = (try c.decodeIfPresent([OrthocalReadingDTO].self, forKey: .readings)) ?? []
    }
}

enum OrthocalAPIError: Error {
    case invalidURL
    case invalidResponse
    case emptyPayload
}

struct OrthocalAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let baseURL = URL(string: "https://orthocal.info/api")

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = true  // Wait for network instead of failing immediately
        self.session = session ?? URLSession(configuration: configuration)
        self.decoder = JSONDecoder()
    }

    func fetchDay(date: Date) async throws -> OrthocalDayDTO {
        guard let url = makeURL(for: date) else {
            throw OrthocalAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw OrthocalAPIError.invalidResponse
            }
            guard !data.isEmpty else {
                throw OrthocalAPIError.emptyPayload
            }

            return try decoder.decode(OrthocalDayDTO.self, from: data)
        } catch {
            // Handle network errors more gracefully to avoid connection metadata logs
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                    throw OrthocalAPIError.invalidResponse  // Treat as response error to avoid low-level logs
                default:
                    throw error
                }
            }
            throw error
        }
    }

    private func makeURL(for date: Date) -> URL? {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: date)

        guard let year = comps.year,
              let month = comps.month,
              let day = comps.day,
              let baseURL else {
            return nil
        }

        return baseURL
            .appendingPathComponent("gregorian")
            .appendingPathComponent(String(year))
            .appendingPathComponent(String(month))
            .appendingPathComponent(String(day))
            .appendingPathComponent("")
    }
}

