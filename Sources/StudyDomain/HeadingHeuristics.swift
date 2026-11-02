import Foundation

public enum HeadingHeuristics {
    /// Detects a heading-looking line in plain text (PDF without outline).
    /// Conservative: only clear signals count, and the line must be short.
    public static func looksLikeHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= 90 else { return false }
        guard !trimmed.hasSuffix(".") else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= 12 else { return false }

        // Numbered headings: "1", "1.2", "Chapter 3", "PART II".
        let numberingPatterns = [
            #"^\d+(\.\d+)*\.?\s+[A-Za-z]"#,
            #"^(Chapter|Part|Section|Appendix|Capitolo|Parte|Sezione)\s+[\dIVXLC]+"#,
        ]
        for pattern in numberingPatterns {
            if trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }

        // All-caps short lines are plausible headings.
        let letters = trimmed.filter { $0.isLetter }
        if letters.count >= 3 {
            let upper = letters.filter { $0.isUppercase }.count
            if Double(upper) / Double(letters.count) > 0.9 {
                return true
            }
        }
        return false
    }

    /// A deterministic title derived from document text, never invented.
    public static func titleFromText(_ text: String, maximumWords: Int = 9) -> String {
        let firstLine = text
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init) ?? text
        let sentence = TextUtilities.sentenceSplit(firstLine).first ?? firstLine
        var words = sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > maximumWords {
            words = Array(words.prefix(maximumWords))
        }
        var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,;:—-"))
        if title.isEmpty {
            title = "Passage"
        }
        if title.count > 80 {
            title = String(title.prefix(77)) + "…"
        }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}
