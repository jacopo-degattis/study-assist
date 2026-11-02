import Foundation
import StudyDomain

/// One contiguous piece of extracted text, before chunking.
public struct TextBlock: Sendable {
    public var text: String
    public var location: SourceLocation
    public var method: ExtractionMethod
    public var quality: Double
    public var isUsable: Bool
    public var sectionId: SectionID?

    public init(
        text: String,
        location: SourceLocation,
        method: ExtractionMethod,
        quality: Double = 1.0,
        isUsable: Bool = true,
        sectionId: SectionID? = nil
    ) {
        self.text = text
        self.location = location
        self.method = method
        self.quality = quality
        self.isUsable = isUsable
        self.sectionId = sectionId
    }
}

/// Splits text along natural boundaries into provenance-preserving chunks.
///
/// Chunks are contiguous ranges of the snapshot's normalized text, so every
/// offset can be verified against what is stored.
public enum Chunker {
    public struct Configuration: Sendable {
        public var targetTokens: Int
        public var maximumTokens: Int
        public var overlapSentences: Int
        public var minimumEvidenceCharacters: Int

        public init(
            targetTokens: Int = 550,
            maximumTokens: Int = 900,
            overlapSentences: Int = 1,
            minimumEvidenceCharacters: Int = 60
        ) {
            self.targetTokens = targetTokens
            self.maximumTokens = maximumTokens
            self.overlapSentences = overlapSentences
            self.minimumEvidenceCharacters = minimumEvidenceCharacters
        }

        public static let `default` = Configuration()
    }

    struct Unit {
        var text: String
        var start: Int
        var end: Int
        var location: SourceLocation
        var method: ExtractionMethod
        var quality: Double
        var isUsable: Bool
        var sectionId: SectionID?
    }

    public struct Result: Sendable {
        public var fullText: String
        public var chunks: [SourceChunk]

        public init(fullText: String, chunks: [SourceChunk]) {
            self.fullText = fullText
            self.chunks = chunks
        }
    }

    public static func chunk(
        blocks: [TextBlock],
        snapshotId: SnapshotID,
        configuration: Configuration = .default
    ) -> Result {
        var fullText = ""
        var units: [Unit] = []

        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !fullText.isEmpty { fullText += "\n\n" }
            let blockStart = fullText.utf16.count
            fullText += trimmed

            // Split the block into sentences, preserving absolute offsets.
            for sentence in sentenceRanges(in: trimmed) {
                let start = blockStart + sentence.start
                let end = blockStart + sentence.end
                guard end > start else { continue }
                var location = block.location
                location.endParagraphIndex = block.location.endParagraphIndex ?? block.location.paragraphIndex
                units.append(
                    Unit(
                        text: sentence.text,
                        start: start,
                        end: end,
                        location: location,
                        method: block.method,
                        quality: block.quality,
                        isUsable: block.isUsable,
                        sectionId: block.sectionId
                    )
                )
            }
        }

        guard !units.isEmpty else {
            return Result(fullText: fullText, chunks: [])
        }

        var chunks: [SourceChunk] = []
        var startIndex = 0
        var order = 0
        let maxUnits = max(1, configuration.maximumTokens)

        while startIndex < units.count {
            var endIndex = startIndex
            var tokenCount = 0
            let chunkPage = units[startIndex].location.pageNumber
            while endIndex < units.count {
                // A chunk must never span pages: a PDF reference has to resolve
                // to exactly the page that contains the text.
                if let chunkPage, let page = units[endIndex].location.pageNumber, page != chunkPage, endIndex > startIndex {
                    break
                }
                let unitTokens = TextUtilities.approximateTokenCount(units[endIndex].text)
                if endIndex > startIndex, tokenCount + unitTokens > maxUnits { break }
                tokenCount += unitTokens
                endIndex += 1
                if tokenCount >= configuration.targetTokens { break }
            }
            if endIndex == startIndex { endIndex = startIndex + 1 }

            let range = startIndex..<endIndex
            let chunkUnits = range.map { units[$0] }
            let first = chunkUnits[0]
            let last = chunkUnits[chunkUnits.count - 1]
            let text = substring(fullText, utf16Range: first.start..<last.end)
            let isUsable = chunkUnits.allSatisfy { $0.isUsable }
                && text.count >= configuration.minimumEvidenceCharacters
            let quality = chunkUnits.map(\.quality).min() ?? 1.0
            let method = majorityMethod(chunkUnits.map(\.method))

            var location = first.location
            if let startParagraph = first.location.paragraphIndex,
               let lastParagraph = chunkUnits.compactMap(\.location.paragraphIndex).max() {
                location.endParagraphIndex = max(startParagraph, lastParagraph)
            }

            chunks.append(
                SourceChunk(
                    snapshotId: snapshotId,
                    text: text,
                    sectionId: first.sectionId,
                    location: location,
                    startOffset: first.start,
                    endOffset: last.end,
                    extractionMethod: method,
                    quality: quality,
                    isUsableAsEvidence: isUsable,
                    order: order
                )
            )
            order += 1

            if endIndex >= units.count { break }
            // Overlap: re-include the last few sentences when they are small.
            var nextStart = endIndex
            if configuration.overlapSentences > 0 {
                let candidate = max(startIndex + 1, endIndex - configuration.overlapSentences)
                let overlapTokens = chunkUnits.suffix(endIndex - candidate).reduce(0) { $0 + TextUtilities.approximateTokenCount($1.text) }
                if overlapTokens < configuration.maximumTokens / 3 {
                    nextStart = candidate
                }
            }
            startIndex = max(nextStart, startIndex + 1)
        }

        return Result(fullText: fullText, chunks: chunks)
    }

    static func sentenceRanges(in text: String) -> [(text: String, start: Int, end: Int)] {
        var ranges: [(text: String, start: Int, end: Int)] = []
        var currentStart = 0
        var offset = 0
        for character in text {
            offset += String(character).utf16.count
            if character == "." || character == "!" || character == "?" {
                appendRange(in: text, from: currentStart, to: offset, into: &ranges)
                currentStart = offset
            }
        }
        appendRange(in: text, from: currentStart, to: offset, into: &ranges)
        return ranges
    }

    private static func appendRange(
        in text: String,
        from: Int,
        to: Int,
        into ranges: inout [(text: String, start: Int, end: Int)]
    ) {
        guard to > from else { return }
        let raw = rawSubstring(text, utf16Range: from..<to)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var leading = 0
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                leading += String(scalar).utf16.count
            } else {
                break
            }
        }
        ranges.append((trimmed, from + leading, from + leading + trimmed.utf16.count))
    }

    static func rawSubstring(_ text: String, utf16Range range: Range<Int>) -> String {
        guard range.lowerBound >= 0,
              range.upperBound <= text.utf16.count,
              range.lowerBound <= range.upperBound
        else { return "" }
        let start = String.Index(utf16Offset: range.lowerBound, in: text)
        let end = String.Index(utf16Offset: range.upperBound, in: text)
        return String(text[start..<end])
    }

    static func substring(_ text: String, utf16Range range: Range<Int>) -> String {
        rawSubstring(text, utf16Range: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func majorityMethod(_ methods: [ExtractionMethod]) -> ExtractionMethod {
        var counts: [ExtractionMethod: Int] = [:]
        for method in methods { counts[method, default: 0] += 1 }
        return counts.max { lhs, rhs in lhs.value < rhs.value }?.key ?? methods.first ?? .pdfText
    }
}

// MARK: - File hashing

public enum FileHashing {
    public static func sha256(of url: URL, maximumBytes: Int = 200 * 1024 * 1024) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumBytes else {
            throw AppError.documentTooLarge("The file is larger than \(maximumBytes / (1024 * 1024)) MB.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return TextUtilities.sha256Hex(data: data)
    }
}
