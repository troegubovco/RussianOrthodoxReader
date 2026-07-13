import Foundation

// Общие DTO литургического дня. Имена «Orthocal» унаследованы от прежнего
// API orthocal.info; сейчас эти типы наполняются AzbykaAPIClient и
// BundledLiturgicalDB и потребляются LiturgicalRepository.

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

    init(source: String?, book: String?, description: String?, display: String?, shortDisplay: String?, passage: [OrthocalVerseDTO]) {
        self.source = source
        self.book = book
        self.description = description
        self.display = display
        self.shortDisplay = shortDisplay
        self.passage = passage
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

    /// Memberwise init for constructing from converted API data (used by AzbykaAPIClient)
    init(year: Int, month: Int, day: Int, tone: Int?, fastingDescription: String?, fastingException: String?, summaryTitle: String?, saints: [String], readings: [OrthocalReadingDTO]) {
        self.year = year
        self.month = month
        self.day = day
        self.tone = tone
        self.fastingDescription = fastingDescription
        self.fastingException = fastingException
        self.summaryTitle = summaryTitle
        self.saints = saints
        self.readings = readings
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

