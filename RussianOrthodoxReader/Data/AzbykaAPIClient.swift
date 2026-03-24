import Foundation

// MARK: - Azbyka API Response Models

/// Current response from the public widget endpoint.
/// GET https://azbyka.ru/days/widgets/presentations.json?date=YYYY-MM-DD&image=1&prevNextLinks=1
struct AzbykaWidgetResponse: Codable {
    let imgs: [String]?
    let presentations: String?
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
    let type: String?
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

// MARK: - Azbyka API Client

enum AzbykaAPIError: Error {
    case invalidURL
    case invalidResponse
    case emptyPayload
}

private enum AzbykaPublicReadingSection: String {
    case matins = "Matins"
    case liturgy = "Liturgy"
    case sixthHour = "6th Hour"
    case thirdHour = "3rd Hour"
    case ninthHour = "9th Hour"
    case firstHour = "1st Hour"
    case vespers = "Vespers"
    case compline = "Compline"
}

struct AzbykaAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let baseURL = "https://azbyka.ru/days"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var apiKey: String? {
        UserDefaults.standard.string(forKey: "azbyka_api_key")
    }

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = true
        self.session = session ?? URLSession(configuration: configuration)
        self.decoder = JSONDecoder()
    }

    func fetchDay(date: Date) async throws -> OrthocalDayDTO {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else {
            throw AzbykaAPIError.invalidURL
        }

        let dateString = Self.dateFormatter.string(from: date)

        if let key = apiKey, !key.isEmpty {
            do {
                return try await fetchFromFullAPI(
                    dateString: dateString,
                    year: year,
                    month: month,
                    day: day,
                    apiKey: key
                )
            } catch {
                print("[AzbykaAPI] Full API failed, falling back to public page: \(error)")
            }
        }

        do {
            return try await fetchFromPublicPage(dateString: dateString, year: year, month: month, day: day)
        } catch {
            print("[AzbykaAPI] Public page failed, falling back to widget: \(error)")
        }

        return try await fetchFromWidget(dateString: dateString, year: year, month: month, day: day)
    }

    // MARK: - Full API (Requires Auth)

    private func fetchFromFullAPI(
        dateString: String,
        year: Int,
        month: Int,
        day: Int,
        apiKey: String
    ) async throws -> OrthocalDayDTO {
        guard let url = URL(string: "\(baseURL)/api/daytype/\(dateString).json") else {
            throw AzbykaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AzbykaAPIError.invalidResponse
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if http.url?.path.contains("/days/login") == true || contentType.contains("text/html") {
                throw AzbykaAPIError.invalidResponse
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                throw AzbykaAPIError.invalidResponse
            }

            guard (200...299).contains(http.statusCode) else {
                throw AzbykaAPIError.invalidResponse
            }
            guard !data.isEmpty else {
                throw AzbykaAPIError.emptyPayload
            }
            guard contentType.contains("application/json") else {
                throw AzbykaAPIError.invalidResponse
            }

            let dayType: AzbykaDayTypeResponse
            do {
                dayType = try decoder.decode(AzbykaDayTypeResponse.self, from: data)
            } catch {
                throw AzbykaAPIError.invalidResponse
            }

            return convertFullAPIResponse(dayType, year: year, month: month, day: day)
        } catch {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                    throw AzbykaAPIError.invalidResponse
                default:
                    throw error
                }
            }
            throw error
        }
    }

    // MARK: - Public Day Page (No Auth)

    private func fetchFromPublicPage(dateString: String, year: Int, month: Int, day: Int) async throws -> OrthocalDayDTO {
        guard let url = URL(string: "\(baseURL)/\(dateString)") else {
            throw AzbykaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw AzbykaAPIError.invalidResponse
            }
            guard !data.isEmpty else {
                throw AzbykaAPIError.emptyPayload
            }

            guard let html = String(data: data, encoding: .utf8) else {
                throw AzbykaAPIError.invalidResponse
            }

            let dto = convertPublicPageResponse(html, year: year, month: month, day: day)
            let hasUsefulContent = !dto.saints.isEmpty || !dto.readings.isEmpty || dto.summaryTitle != nil || dto.tone != nil
            guard hasUsefulContent else {
                throw AzbykaAPIError.invalidResponse
            }

            return dto
        } catch {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                    throw AzbykaAPIError.invalidResponse
                default:
                    throw error
                }
            }
            throw error
        }
    }

    // MARK: - Widget Endpoint (No Auth)

    private func fetchFromWidget(dateString: String, year: Int, month: Int, day: Int) async throws -> OrthocalDayDTO {
        var components = URLComponents(string: "\(baseURL)/widgets/presentations.json")!
        components.queryItems = [
            URLQueryItem(name: "date", value: dateString),
            URLQueryItem(name: "image", value: "1"),
            URLQueryItem(name: "prevNextLinks", value: "1")
        ]

        guard let url = components.url else {
            throw AzbykaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw AzbykaAPIError.invalidResponse
            }
            guard !data.isEmpty else {
                throw AzbykaAPIError.emptyPayload
            }

            let widget: AzbykaWidgetResponse
            do {
                widget = try decoder.decode(AzbykaWidgetResponse.self, from: data)
            } catch {
                throw AzbykaAPIError.invalidResponse
            }

            return convertWidgetResponse(widget, year: year, month: month, day: day)
        } catch {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                    throw AzbykaAPIError.invalidResponse
                default:
                    throw error
                }
            }
            throw error
        }
    }

    // MARK: - Conversion to OrthocalDayDTO

    private func convertFullAPIResponse(_ dayType: AzbykaDayTypeResponse, year: Int, month: Int, day: Int) -> OrthocalDayDTO {
        let saints = dayType.saints?.compactMap { $0.title } ?? []
        let holidays = dayType.holidays?.compactMap { $0.title } ?? []

        var allSaints = saints
        if !holidays.isEmpty {
            allSaints = holidays + allSaints
        }

        let readings: [OrthocalReadingDTO] = dayType.readings?.compactMap { reading in
            let display = normalizedReferenceDisplay(reading.display ?? composeDisplay(book: reading.book, chapter: reading.chapter, verse: reading.verse))
            guard !display.isEmpty else { return nil }
            return OrthocalReadingDTO(
                source: reading.type,
                book: reading.book,
                description: nil,
                display: display,
                shortDisplay: nil,
                passage: []
            )
        } ?? []

        return OrthocalDayDTO(
            year: year,
            month: month,
            day: day,
            tone: dayType.tone,
            fastingDescription: dayType.fastingName,
            fastingException: nil,
            summaryTitle: dayType.weekName,
            saints: allSaints,
            readings: readings
        )
    }

    private func convertPublicPageResponse(_ html: String, year: Int, month: Int, day: Int) -> OrthocalDayDTO {
        let summaryTitle = extractWeekName(from: html)
        let daySection = slice(html, after: #"<div class="text day__text">"#, before: #"<div id="chteniya""#) ?? ""
        let infoText = firstCapture(pattern: #"(?s)<p>\s*(.*?)\s*</p>"#, in: daySection).map(htmlToText) ?? ""

        return OrthocalDayDTO(
            year: year,
            month: month,
            day: day,
            tone: extractTone(from: infoText),
            fastingDescription: extractFastingDescription(from: infoText),
            fastingException: nil,
            summaryTitle: summaryTitle,
            saints: extractSaints(from: daySection),
            readings: extractReadings(from: html)
        )
    }

    private func convertWidgetResponse(_ widget: AzbykaWidgetResponse, year: Int, month: Int, day: Int) -> OrthocalDayDTO {
        let presentations = widget.presentations ?? ""
        return OrthocalDayDTO(
            year: year,
            month: month,
            day: day,
            tone: nil,
            fastingDescription: nil,
            fastingException: nil,
            summaryTitle: nil,
            saints: extractSaints(from: presentations),
            readings: []
        )
    }

    // MARK: - HTML Parsing

    private func extractWeekName(from html: String) -> String? {
        guard let raw = firstCapture(
            pattern: #"(?s)<div class="day__post-wp[^"]*">.*?<div class="shadow">.*?<div class="lc">&nbsp;</div>(.*?)<div class="rc">&nbsp;</div>"#,
            in: html
        ) else {
            return nil
        }

        let value = htmlToText(raw)
        return value.isEmpty ? nil : value
    }

    private func extractTone(from infoText: String) -> Int? {
        guard let match = firstCapture(pattern: #"Глас\s+(\d+)"#, in: infoText) else {
            return nil
        }
        return Int(match)
    }

    private func extractFastingDescription(from infoText: String) -> String? {
        let knownValues = [
            "Строгий пост",
            "Постный день",
            "Разрешается рыба",
            "Разрешается елей"
        ]

        for value in knownValues where infoText.localizedCaseInsensitiveContains(value) {
            return value
        }

        return nil
    }

    private func extractSaints(from html: String) -> [String] {
        allCaptures(pattern: #"(?s)<li class="ideograph-[^"]*">(.*?)</li>"#, in: html)
            .map(htmlToText)
            .filter { !$0.isEmpty }
    }

    private func extractReadings(from html: String) -> [OrthocalReadingDTO] {
        guard let readingsSection = slice(html, after: #"<div class="readings-text">"#, before: #"<div class="scripture-sub">"#),
              let paragraphHTML = firstCapture(pattern: #"(?s)<p[^>]*>.*?class="bibref".*?</p>"#, in: readingsSection) else {
            return []
        }

        let markerHTML = paragraphHTML.replacingOccurrences(
            of: #"(?s)<a class="bibref"[^>]*>(.*?)</a>"#,
            with: "[[REF:$1]]",
            options: .regularExpression
        )
        let text = htmlToText(markerHTML)
        let refMatches = regexMatches(pattern: #"\[\[REF:(.*?)\]\]"#, in: text)

        var readings: [OrthocalReadingDTO] = []
        var currentSection: AzbykaPublicReadingSection?
        var liturgyIndex = 0
        var cursor = text.startIndex

        for match in refMatches {
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            let preamble = String(text[cursor..<fullRange.lowerBound])
            if let section = lastReadingSection(in: preamble) {
                if section != currentSection {
                    liturgyIndex = 0
                }
                currentSection = section
            }

            let display = normalizedReferenceDisplay(String(text[valueRange]))
            guard !display.isEmpty else {
                cursor = fullRange.upperBound
                continue
            }

            let source: String
            switch currentSection {
            case .liturgy:
                liturgyIndex += 1
                switch liturgyIndex {
                case 1:
                    source = "apostol"
                case 2:
                    source = "gospel"
                default:
                    source = AzbykaPublicReadingSection.liturgy.rawValue
                }
            case let section?:
                source = section.rawValue
            case nil:
                source = ""
            }

            readings.append(
                OrthocalReadingDTO(
                    source: source,
                    book: nil,
                    description: nil,
                    display: display,
                    shortDisplay: nil,
                    passage: []
                )
            )

            cursor = fullRange.upperBound
        }

        return readings
    }

    private func lastReadingSection(in text: String) -> AzbykaPublicReadingSection? {
        let markers: [(String, AzbykaPublicReadingSection)] = [
            ("на 6-м часе", .sixthHour),
            ("на 3-м часе", .thirdHour),
            ("на 9-м часе", .ninthHour),
            ("на 1-м часе", .firstHour),
            ("на веч", .vespers),
            ("повечер", .compline),
            ("утр", .matins),
            ("лит", .liturgy)
        ]

        let lowered = text.lowercased()
        var best: (String.Index, AzbykaPublicReadingSection)?

        for (marker, section) in markers {
            guard let range = lowered.range(of: marker, options: [.caseInsensitive, .backwards]) else {
                continue
            }
            if best == nil || range.lowerBound > best!.0 {
                best = (range.lowerBound, section)
            }
        }

        return best?.1
    }

    private func composeDisplay(book: String?, chapter: String?, verse: String?) -> String {
        let pieces = [book, chapter, verse]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return pieces.joined(separator: " ")
    }

    private func normalizedReferenceDisplay(_ raw: String) -> String {
        var value = htmlToText(raw)
        value = value.replacingOccurrences(of: #"\s*\(\s*зач[^)]*\)\.?"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?<=\p{L}|\d)\.(?=\d)"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?<=\p{L})\.$"#, with: "", options: .regularExpression)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " .,\n\t"))
        return collapseWhitespace(value)
    }

    private func htmlToText(_ html: String) -> String {
        let decoded = decodeHTMLEntities(html)
        let stripped = decoded.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return collapseWhitespace(stripped)
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        let replacements: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#039;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&laquo;", "«"),
            ("&raquo;", "»"),
            ("&ndash;", "–"),
            ("&mdash;", "—"),
            ("&hellip;", "…"),
            ("&minus;", "−"),
            ("&shy;", "")
        ]

        var result = value
        for (entity, replacement) in replacements {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#, options: []) else {
            return result
        }

        let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range(at: 0), in: result) else {
                continue
            }

            let token = String(result[tokenRange])
            let scalarValue: UInt32?
            if token.hasPrefix("x") || token.hasPrefix("X") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }

            guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else {
                continue
            }

            result.replaceSubrange(fullRange, with: String(scalar))
        }

        return result
    }

    private func collapseWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func slice(_ value: String, after startToken: String, before endToken: String) -> String? {
        guard let startRange = value.range(of: startToken) else {
            return nil
        }
        let suffix = value[startRange.upperBound...]
        guard let endRange = suffix.range(of: endToken) else {
            return nil
        }
        return String(suffix[..<endRange.lowerBound])
    }

    private func firstCapture(pattern: String, in value: String) -> String? {
        regexMatches(pattern: pattern, in: value)
            .first
            .flatMap { extractedRange(from: $0, in: value) }
            .map { String(value[$0]) }
    }

    private func allCaptures(pattern: String, in value: String) -> [String] {
        regexMatches(pattern: pattern, in: value).compactMap { match in
            guard let range = extractedRange(from: match, in: value) else {
                return nil
            }
            return String(value[range])
        }
    }

    private func extractedRange(from match: NSTextCheckingResult, in value: String) -> Range<String.Index>? {
        let captureIndex = match.numberOfRanges > 1 ? 1 : 0
        let nsRange = match.range(at: captureIndex)
        guard nsRange.location != NSNotFound else {
            return nil
        }
        return Range(nsRange, in: value)
    }

    private func regexMatches(pattern: String, in value: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, options: [], range: range)
    }
}
