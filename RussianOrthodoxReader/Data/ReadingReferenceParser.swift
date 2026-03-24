import Foundation

struct ReadingReferenceParser {
    func parse(raw: String, kind: ReadingKind, sourceLabel: String = "", ordinalStart: Int = 0) -> [ReadingReference] {
        let normalized = raw
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: #"(\d+)\.(\d+)"#, with: "$1:$2", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }
        guard let (bookPart, bodyPart) = splitBookAndBody(normalized) else { return [] }
        guard let bookId = BookAliasMapper.bookId(for: bookPart) else {
            // Skip non-Bible books like "Composite" or empty strings without logging
            if bookPart != "Composite" && !bookPart.isEmpty {
                #if DEBUG
                print("[ReadingReferenceParser] unknown book alias: \(bookPart)")
                #endif
            }
            return []
        }
        
        // Parse the bodyPart into [ReadingReference]. Azbyka often uses commas to
        // continue the same chapter, e.g. "21:1-11,15-17" or "1:39-49,56".
        let tokens = bodyPart.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var results: [ReadingReference] = []
        var ordinal = ordinalStart
        
        for tokenGroup in tokens {
            let subTokens = tokenGroup
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var currentChapter: Int?

            for token in subTokens {
                if let range = parseChapterVerseRange(token) {
                    currentChapter = range.chapter
                    results.append(ReadingReference(
                        kind: kind,
                        sourceLabel: sourceLabel,
                        displayRef: displayRef(bookPart: bookPart, token: token, chapter: range.chapter),
                        bookId: bookId,
                        chapter: range.chapter,
                        verseStart: range.start,
                        verseEnd: range.end,
                        ordinal: ordinal
                    ))
                    ordinal += 1
                } else if let single = parseChapterSingleVerse(token) {
                    currentChapter = single.chapter
                    results.append(ReadingReference(
                        kind: kind,
                        sourceLabel: sourceLabel,
                        displayRef: displayRef(bookPart: bookPart, token: token, chapter: single.chapter),
                        bookId: bookId,
                        chapter: single.chapter,
                        verseStart: single.verse,
                        verseEnd: single.verse,
                        ordinal: ordinal
                    ))
                    ordinal += 1
                } else if let cross = parseCrossChapterRange(token) {
                    currentChapter = cross.endChapter
                    if cross.startChapter == cross.endChapter {
                        results.append(ReadingReference(
                            kind: kind,
                            sourceLabel: sourceLabel,
                            displayRef: displayRef(bookPart: bookPart, token: token, chapter: cross.startChapter),
                            bookId: bookId,
                            chapter: cross.startChapter,
                            verseStart: cross.startVerse,
                            verseEnd: cross.endVerse,
                            ordinal: ordinal
                        ))
                        ordinal += 1
                    } else {
                        // Split cross-chapter range into per-chapter ReadingReference instances.
                        // E.g., "8:28-9:5" → chapter 8 verses 28-end, chapter 9 verses 1-5.
                        let maxVersePerChapter = 200 // safe upper bound
                        for ch in cross.startChapter...cross.endChapter {
                            let vStart = (ch == cross.startChapter) ? cross.startVerse : 1
                            let vEnd = (ch == cross.endChapter) ? cross.endVerse : maxVersePerChapter
                            results.append(ReadingReference(
                                kind: kind,
                                sourceLabel: sourceLabel,
                                displayRef: displayRef(bookPart: bookPart, token: token, chapter: ch),
                                bookId: bookId,
                                chapter: ch,
                                verseStart: vStart,
                                verseEnd: vEnd,
                                ordinal: ordinal
                            ))
                            ordinal += 1
                        }
                    }
                } else if let chapter = currentChapter, let range = parseVerseRange(token) {
                    results.append(ReadingReference(
                        kind: kind,
                        sourceLabel: sourceLabel,
                        displayRef: displayRef(bookPart: bookPart, token: token, chapter: chapter),
                        bookId: bookId,
                        chapter: chapter,
                        verseStart: range.start,
                        verseEnd: range.end,
                        ordinal: ordinal
                    ))
                    ordinal += 1
                } else if let chapter = currentChapter, let verse = parseSingleVerse(token) {
                    results.append(ReadingReference(
                        kind: kind,
                        sourceLabel: sourceLabel,
                        displayRef: displayRef(bookPart: bookPart, token: token, chapter: chapter),
                        bookId: bookId,
                        chapter: chapter,
                        verseStart: verse,
                        verseEnd: verse,
                        ordinal: ordinal
                    ))
                    ordinal += 1
                } else if let chapter = currentChapter,
                          let cross = parseImplicitCrossChapterRange(token, startChapter: chapter) {
                    currentChapter = cross.endChapter
                    let maxVersePerChapter = 200
                    for ch in cross.startChapter...cross.endChapter {
                        let vStart = (ch == cross.startChapter) ? cross.startVerse : 1
                        let vEnd = (ch == cross.endChapter) ? cross.endVerse : maxVersePerChapter
                        results.append(ReadingReference(
                            kind: kind,
                            sourceLabel: sourceLabel,
                            displayRef: implicitCrossDisplayRef(
                                bookPart: bookPart,
                                token: token,
                                startChapter: cross.startChapter
                            ),
                            bookId: bookId,
                            chapter: ch,
                            verseStart: vStart,
                            verseEnd: vEnd,
                            ordinal: ordinal
                        ))
                        ordinal += 1
                    }
                } else if parseVerseRange(token) != nil || parseSingleVerse(token) != nil {
                    #if DEBUG
                    print("[ReadingReferenceParser] Skipping ambiguous verse token without chapter: \(token)")
                    #endif
                } else {
                    #if DEBUG
                    print("[ReadingReferenceParser] Unparseable token: \(tokenGroup)")
                    #endif
                }
            }
        }
        
        return results
    }

    private func splitBookAndBody(_ raw: String) -> (String, String)? {
        guard let match = captureGroups(
            pattern: #"^(.+?)\s+([0-9].*)$"#,
            in: raw
        ), match.count == 3 else {
            return nil
        }

        return (
            match[1].trimmingCharacters(in: .whitespacesAndNewlines),
            match[2].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func parseChapterVerseRange(_ token: String) -> (chapter: Int, start: Int, end: Int)? {
        guard let r = token.range(of: #"^(\d+):(\d+)-(\d+)$"#, options: .regularExpression) else {
            return nil
        }
        let parts = String(token[r]).split(separator: ":")
        guard parts.count == 2,
              let chapter = Int(parts[0]) else { return nil }
        let verseBounds = parts[1].split(separator: "-")
        guard verseBounds.count == 2,
              let start = Int(verseBounds[0]),
              let end = Int(verseBounds[1]) else { return nil }
        return (chapter, min(start, end), max(start, end))
    }

    private func parseChapterSingleVerse(_ token: String) -> (chapter: Int, verse: Int)? {
        guard let r = token.range(of: #"^(\d+):(\d+)$"#, options: .regularExpression) else {
            return nil
        }
        let parts = String(token[r]).split(separator: ":")
        guard parts.count == 2,
              let chapter = Int(parts[0]),
              let verse = Int(parts[1]) else { return nil }
        return (chapter, verse)
    }

    private func parseVerseRange(_ token: String) -> (start: Int, end: Int)? {
        guard let r = token.range(of: #"^(\d+)-(\d+)$"#, options: .regularExpression) else {
            return nil
        }
        let parts = String(token[r]).split(separator: "-")
        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1]) else { return nil }
        return (min(start, end), max(start, end))
    }

    private func parseCrossChapterRange(_ token: String) -> (startChapter: Int, startVerse: Int, endChapter: Int, endVerse: Int)? {
        guard let r = token.range(of: #"^(\d+):(\d+)-(\d+):(\d+)$"#, options: .regularExpression) else {
            return nil
        }
        let body = String(token[r]).replacingOccurrences(of: ":", with: "-")
        let nums = body.split(separator: "-").compactMap { Int($0) }
        guard nums.count == 4 else { return nil }
        return (nums[0], nums[1], nums[2], nums[3])
    }

    private func parseSingleVerse(_ token: String) -> Int? {
        guard token.range(of: #"^\d+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Int(token)
    }

    private func parseImplicitCrossChapterRange(_ token: String, startChapter: Int) -> (startChapter: Int, startVerse: Int, endChapter: Int, endVerse: Int)? {
        guard let r = token.range(of: #"^(\d+)-(\d+):(\d+)$"#, options: .regularExpression) else {
            return nil
        }
        let body = String(token[r]).replacingOccurrences(of: ":", with: "-")
        let nums = body.split(separator: "-").compactMap { Int($0) }
        guard nums.count == 3 else { return nil }
        return (startChapter, nums[0], nums[1], nums[2])
    }

    private func displayRef(bookPart: String, token: String, chapter: Int) -> String {
        if token.contains(":") {
            return "\(bookPart) \(token)"
        }
        return "\(bookPart) \(chapter):\(token)"
    }

    private func implicitCrossDisplayRef(bookPart: String, token: String, startChapter: Int) -> String {
        "\(bookPart) \(startChapter):\(token)"
    }

    private func captureGroups(pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let fullRange = NSRange(location: 0, length: value.utf16.count)
        guard let match = regex.firstMatch(in: value, options: [], range: fullRange) else { return nil }

        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            let range = match.range(at: index)
            guard let swiftRange = Range(range, in: value) else {
                groups.append("")
                continue
            }
            groups.append(String(value[swiftRange]))
        }
        return groups
    }
}
