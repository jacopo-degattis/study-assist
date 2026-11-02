import Foundation
import StudyDomain

/// Streaming parser for `word/document.xml` and the companion parts we need.
/// Deliberately conservative: it extracts paragraphs, headings, lists, tables
/// and notes in document order, and never concatenates raw XML.
final class OOXMLDocumentParser: NSObject, XMLParserDelegate {

    struct Block {
        enum Kind { case paragraph, table }
        var kind: Kind
        var text: String
        var startParagraphIndex: Int
        var endParagraphIndex: Int
        var headingLevel: Int?
        var isListItem: Bool
    }

    struct Result {
        var blocks: [Block]
        var warnings: [String]
        var hasDrawings: Bool
        var hasExternalRelationships: Bool
        var paragraphCount: Int
    }

    private var blocks: [Block] = []
    private var warnings: [String] = []
    private var paragraphCounter = 0
    private var headingStyleLevels: [String: Int] = [:]

    // Paragraph state
    private var currentParagraphIndex: Int?
    private var currentParagraphText = ""
    private var currentStyleId: String?
    private var currentOutlineLevel: Int?
    private var currentIsListItem = false
    private var currentHasDrawing = false
    private var paragraphDepth = 0

    // Table state
    private var tableDepth = 0
    private var rows: [[String]] = []
    private var currentRow: [String] = []
    private var currentCellText: [String] = []
    private var inCell = false
    private var tableStartParagraph = 0
    private var tableDrawing = false

    // Text capture
    private var collectingText = false
    private var collectingInstrText = false

    private var drawingCount = 0
    private var unsupportedObjectCount = 0

    private var parserError: Error?

    var hasDrawings: Bool { drawingCount > 0 }

    static func parseDocumentXML(_ data: Data, headingStyles: [String: Int]) throws -> Result {
        let parser = OOXMLDocumentParser()
        parser.headingStyleLevels = headingStyles
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        guard xml.parse() else {
            let error = parser.parserError ?? xml.parserError
            throw AppError.documentCorruptArchive(
                "word/document.xml could not be parsed" + (error.map { ": \($0.localizedDescription)" } ?? ".")
            )
        }
        if let error = parser.parserError {
            throw AppError.documentCorruptArchive("word/document.xml could not be parsed: \(error.localizedDescription)")
        }
        if parser.hasDrawings {
            parser.warnings.append("\(parser.drawingCount) embedded drawing\(parser.drawingCount == 1 ? "" : "s") or image\(parser.drawingCount == 1 ? "" : "s") were not extracted; questions cannot rely on them.")
        }
        if parser.unsupportedObjectCount > 0 {
            parser.warnings.append("\(parser.unsupportedObjectCount) embedded object\(parser.unsupportedObjectCount == 1 ? "" : "s") were not extracted.")
        }
        return Result(
            blocks: parser.blocks,
            warnings: parser.warnings,
            hasDrawings: parser.hasDrawings,
            hasExternalRelationships: false,
            paragraphCount: parser.paragraphCounter
        )
    }

    /// Reads heading levels from `word/styles.xml`.
    static func parseHeadingStyles(_ data: Data) -> [String: Int] {
        let delegate = StylesDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        return delegate.levels
    }

    /// Reads note texts from `word/footnotes.xml` or `word/endnotes.xml`.
    static func parseNotes(_ data: Data) throws -> [String] {
        let delegate = NotesDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        if let error = parser.parserError {
            throw AppError.documentCorruptArchive("A notes part could not be parsed: \(error.localizedDescription)")
        }
        return delegate.notes
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = localName(elementName)
        switch name {
        case "p":
            paragraphDepth += 1
            if paragraphDepth == 1 {
                currentParagraphIndex = paragraphCounter
                paragraphCounter += 1
                currentParagraphText = ""
                currentStyleId = nil
                currentOutlineLevel = nil
                currentIsListItem = false
                currentHasDrawing = false
                if tableDepth == 0 {
                    tableStartParagraph = currentParagraphIndex ?? tableStartParagraph
                }
            }
        case "pStyle":
            if paragraphDepth == 1 { currentStyleId = attributes["w:val"] ?? attributes["val"] }
        case "outlineLvl":
            if paragraphDepth == 1, let value = attributes["w:val"] ?? attributes["val"], let level = Int(value) {
                currentOutlineLevel = level + 1
            }
        case "numPr":
            if paragraphDepth == 1 { currentIsListItem = true }
        case "drawing", "pict":
            currentHasDrawing = true
            drawingCount += 1
        case "object", "oleObject", "altChunk":
            unsupportedObjectCount += 1
        case "tbl":
            tableDepth += 1
            if tableDepth == 1 {
                rows = []
                tableStartParagraph = paragraphCounter
            }
        case "tr":
            if tableDepth == 1 { currentRow = [] }
        case "tc":
            if tableDepth == 1 {
                inCell = true
                currentCellText = []
            }
        case "t":
            collectingText = true
        case "instrText":
            collectingInstrText = true
        case "tab":
            append("\t")
        case "br", "cr":
            append("\n")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard collectingText, !collectingInstrText else { return }
        append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        switch name {
        case "t":
            collectingText = false
        case "instrText":
            collectingInstrText = false
        case "p":
            if paragraphDepth == 1 {
                let trimmed = currentParagraphText.trimmingCharacters(in: .whitespacesAndNewlines)
                if inCell {
                    currentCellText.append(trimmed)
                } else if tableDepth == 0, !trimmed.isEmpty {
                    blocks.append(
                        Block(
                            kind: .paragraph,
                            text: trimmed,
                            startParagraphIndex: currentParagraphIndex ?? 0,
                            endParagraphIndex: currentParagraphIndex ?? 0,
                            headingLevel: headingLevel(styleId: currentStyleId, outlineLevel: currentOutlineLevel),
                            isListItem: currentIsListItem
                        )
                    )
                }
                currentParagraphIndex = nil
                currentParagraphText = ""
            }
            paragraphDepth = max(0, paragraphDepth - 1)
        case "tc":
            if tableDepth == 1, inCell {
                currentRow.append(currentCellText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
                inCell = false
                currentCellText = []
            }
        case "tr":
            if tableDepth == 1, !currentRow.isEmpty {
                rows.append(currentRow)
                currentRow = []
            }
        case "tbl":
            if tableDepth == 1 {
                let nonEmptyRows = rows.filter { row in row.contains { !$0.isEmpty } }
                if !nonEmptyRows.isEmpty {
                    let text = nonEmptyRows
                        .map { $0.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") }
                        .joined(separator: "\n")
                    blocks.append(
                        Block(
                            kind: .table,
                            text: text,
                            startParagraphIndex: tableStartParagraph,
                            endParagraphIndex: max(tableStartParagraph, paragraphCounter - 1),
                            headingLevel: nil,
                            isListItem: false
                        )
                    )
                }
                rows = []
                currentRow = []
            }
            tableDepth = max(0, tableDepth - 1)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parserError = parseError
    }

    // MARK: Helpers

    private func append(_ string: String) {
        if inCell {
            currentCellText.append(string)
        } else {
            currentParagraphText += string
        }
    }

    private func localName(_ name: String) -> String {
        if let range = name.range(of: ":") {
            return String(name[range.upperBound...])
        }
        return name
    }

    private func headingLevel(styleId: String?, outlineLevel: Int?) -> Int? {
        if let outlineLevel, outlineLevel >= 1 && outlineLevel <= 9 {
            return min(outlineLevel, 6)
        }
        guard let styleId else { return nil }
        if let mapped = headingStyleLevels[styleId] { return mapped }
        let normalized = styleId.lowercased()
        for candidate in ["heading", "titolo", "titre", "überschrift", "título"] {
            if normalized.hasPrefix(candidate) || normalized.contains(candidate) {
                let digits = normalized.compactMap { $0.wholeNumberValue }
                if let first = digits.first, first >= 1, first <= 9 {
                    return min(first, 6)
                }
            }
        }
        if normalized == "title" || normalized == "titolo" { return 1 }
        return nil
    }
}

// MARK: - Styles

private final class StylesDelegate: NSObject, XMLParserDelegate {
    var levels: [String: Int] = [:]
    private var currentStyleId: String?
    private var currentName: String?
    private var currentOutlineLevel: Int?
    private var isParagraphStyle = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = Self.local(elementName)
        switch name {
        case "style":
            currentStyleId = attributes["w:styleId"] ?? attributes["styleId"]
            currentName = nil
            currentOutlineLevel = nil
            isParagraphStyle = (attributes["w:type"] ?? attributes["type"]) == "paragraph"
        case "name":
            if currentStyleId != nil {
                currentName = attributes["w:val"] ?? attributes["val"]
            }
        case "outlineLvl":
            if currentStyleId != nil, let value = attributes["w:val"] ?? attributes["val"], let level = Int(value) {
                currentOutlineLevel = level + 1
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard Self.local(elementName) == "style", let styleId = currentStyleId else { return }
        if isParagraphStyle {
            if let level = currentOutlineLevel {
                levels[styleId] = min(level, 6)
            } else if let name = currentName, let level = Self.level(fromName: name) {
                levels[styleId] = level
            }
        }
        currentStyleId = nil
        currentName = nil
        currentOutlineLevel = nil
        isParagraphStyle = false
    }

    static func level(fromName name: String) -> Int? {
        let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["heading ", "titolo ", "titre ", "überschrift "] where normalized.hasPrefix(prefix) {
            if let value = Int(normalized.dropFirst(prefix.count)) {
                return min(max(value, 1), 6)
            }
        }
        return nil
    }

    static func local(_ name: String) -> String {
        if let range = name.range(of: ":") { return String(name[range.upperBound...]) }
        return name
    }
}

// MARK: - Notes

private final class NotesDelegate: NSObject, XMLParserDelegate {
    var notes: [String] = []
    private var currentText = ""
    private var inNote = false
    private var collecting = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = Self.local(elementName)
        if name == "footnote" || name == "endnote" {
            inNote = true
            currentText = ""
        } else if name == "t", inNote {
            collecting = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.local(elementName)
        if name == "t" {
            collecting = false
        } else if (name == "footnote" || name == "endnote"), inNote {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { notes.append(trimmed) }
            inNote = false
            currentText = ""
        }
    }

    static func local(_ name: String) -> String {
        if let range = name.range(of: ":") { return String(name[range.upperBound...]) }
        return name
    }
}
