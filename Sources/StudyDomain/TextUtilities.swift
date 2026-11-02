import Foundation
import CryptoKit

/// Text helpers shared by import, validation and scoring.
public enum TextUtilities {

    /// Collapses runs of whitespace and normalizes line endings. Used for display
    /// and for stable offsets, never to alter meaning.
    public static func normalizeWhitespace(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace && !output.isEmpty {
                    output.append(" ")
                    lastWasSpace = true
                }
            } else {
                output.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes text for duplicate-question comparison: lowercase, letters and
    /// digits only, single spaces. Two questions that differ only in punctuation
    /// or casing compare equal.
    public static func normalizeForComparison(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = String()
        out.reserveCapacity(folded.count)
        var lastWasSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace && !out.isEmpty {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func questionHash(_ text: String) -> String {
        sha256Hex(normalizeForComparison(text))
    }

    /// Content words, lowercase, no stopwords. Used for local support checks only.
    public static func contentTokens(_ text: String) -> [String] {
        let normalized = text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let tokens = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) }
        return tokens
    }

    public static let stopwords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "with", "that", "this", "these", "those",
        "from", "have", "has", "had", "not", "but", "you", "your", "what", "which", "when",
        "where", "how", "why", "who", "does", "did", "can", "could", "would", "should",
        "will", "shall", "may", "might", "must", "into", "than", "then", "there", "their",
        "them", "they", "its", "his", "her", "him", "she", "all", "any", "some", "such",
        "about", "according", "document", "passage", "text", "between", "more", "most",
        "other", "also", "only", "both", "each", "one", "two", "per", "via", "using", "used",
        "described", "describe", "state", "states", "stated", "explain", "explains"
    ]

    /// Rough word count used to keep chunks in the 400–900 token range.
    public static func approximateTokenCount(_ text: String) -> Int {
        // ~0.75 words per token for English; use words/0.75 as an estimate.
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return Int((Double(words) / 0.75).rounded())
    }

    public static func sentenceSplit(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = String()
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }

    /// Jaccard similarity over content tokens, in [0, 1].
    public static func tokenOverlap(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(contentTokens(lhs))
        let b = Set(contentTokens(rhs))
        if a.isEmpty || b.isEmpty { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }

    /// Fraction of `text`'s content tokens that appear in `reference`.
    /// This is the local, deterministic part of the support check.
    public static func containment(of text: String, in reference: String) -> Double {
        let needle = Set(contentTokens(text))
        if needle.isEmpty { return 0 }
        let haystack = Set(contentTokens(reference))
        let found = needle.intersection(haystack).count
        return Double(found) / Double(needle.count)
    }

    public static func detectLanguageHint(_ text: String) -> String? {
        // Deliberately simple: NLLanguageRecognizer lives in NaturalLanguage and is
        // used by the importer; this is the fallback for short text.
        let lowered = text.lowercased()
        let markers: [(String, [String])] = [
            ("it", [" della ", " che ", " sono ", " nella ", " per il ", " degli "]),
            ("en", [" the ", " and ", " of the ", " that the "]),
            ("es", [" que ", " los ", " para ", " una "]),
            ("fr", [" les ", " des ", " est ", " dans "]),
            ("de", [" der ", " die ", " und ", " nicht "]),
        ]
        for (language, needles) in markers where needles.contains(where: { lowered.contains($0) }) {
            return language
        }
        return nil
    }
}
