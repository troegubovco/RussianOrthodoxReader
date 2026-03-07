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
        
        // Parse the bodyPart into [ReadingReference]
        let tokens = bodyPart.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var results: [ReadingReference] = []
        var ordinal = ordinalStart
        
        for token in tokens {
            if let range = parseChapterVerseRange(token) {
                results.append(ReadingReference(
                    kind: kind,
                    sourceLabel: sourceLabel,
                    displayRef: token,
                    bookId: bookId,
                    chapter: range.chapter,
                    verseStart: range.start,
                    verseEnd: range.end,
                    ordinal: ordinal
                ))
                ordinal += 1
            } else if let single = parseChapterSingleVerse(token) {
                results.append(ReadingReference(
                    kind: kind,
                    sourceLabel: sourceLabel,
                    displayRef: token,
                    bookId: bookId,
                    chapter: single.chapter,
                    verseStart: single.verse,
                    verseEnd: single.verse,
                    ordinal: ordinal
                ))
                ordinal += 1
            } else if let cross = parseCrossChapterRange(token) {
                if cross.startChapter == cross.endChapter {
                    results.append(ReadingReference(
                        kind: kind,
                        sourceLabel: sourceLabel,
                        displayRef: token,
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
                            displayRef: token,
                            bookId: bookId,
                            chapter: ch,
                            verseStart: vStart,
                            verseEnd: vEnd,
                            ordinal: ordinal
                        ))
                        ordinal += 1
                    }
                }
            } else if parseVerseRange(token) != nil {
                // Verse ranges without a chapter prefix (e.g., "1-5") are ambiguous without context, so skip them.
                // They could be assumed to apply to a previous chapter, but that's not implemented here.
                #if DEBUG
                print("[ReadingReferenceParser] Skipping ambiguous verse range without chapter: \(token)")
                #endif
            } else {
                #if DEBUG
                print("[ReadingReferenceParser] Unparseable token: \(token)")
                #endif
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
