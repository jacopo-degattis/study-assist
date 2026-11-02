import Foundation
import ZIPFoundation
import NaturalLanguage
import StudyDomain

/// Imports Office Open XML `.docx` files without external converters.
///
/// The archive is validated against size, entry-count, expansion and ratio
/// limits before extraction. Only the parts needed for text are read; macros
/// are never executed and external relationships are never fetched.
public struct DOCXDocumentImporter: DocumentImporter {
    public let supportedType: DocumentFileType = .docx
    public let parserVersion = "docx-1.0.0"

    let limits: Limits

    public struct Limits: Sendable {
        public var maximumFileBytes: Int
        public var maximumEntryCount: Int
        public var maximumEntryBytes: Int
        public var maximumTotalUncompressedBytes: Int
        public var maximumCompressionRatio: Double
        public var minimumUsableCharactersForStudy: Int

        public init(
            maximumFileBytes: Int = 80 * 1024 * 1024,
            maximumEntryCount: Int = 5000,
            maximumEntryBytes: Int = 256 * 1024 * 1024,
            maximumTotalUncompressedBytes: Int = 512 * 1024 * 1024,
            maximumCompressionRatio: Double = 100,
            minimumUsableCharactersForStudy: Int = 200
        ) {
            self.maximumFileBytes = maximumFileBytes
            self.maximumEntryCount = maximumEntryCount
            self.maximumEntryBytes = maximumEntryBytes
            self.maximumTotalUncompressedBytes = maximumTotalUncompressedBytes
            self.maximumCompressionRatio = maximumCompressionRatio
            self.minimumUsableCharactersForStudy = minimumUsableCharactersForStudy
        }

        public static let `default` = Limits()
    }

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    public func importDocument(
        _ request: DocumentImportRequest,
        progress: @Sendable (ImportProgress) -> Void
    ) async throws -> DocumentImportResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: request.sourceURL.path) else {
            throw AppError.documentUnreadable("The file no longer exists at its original location.")
        }
        let fileSize = (try? request.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 0 else { throw AppError.documentEmpty("The file is empty.") }
        guard fileSize <= limits.maximumFileBytes else {
            throw AppError.documentTooLarge("DOCX files must be smaller than \(limits.maximumFileBytes / (1024 * 1024)) MB.")
        }

        progress(ImportProgress(phase: "Copying into the library", fraction: 0.05))
        try Self.validatePackageSignature(at: request.sourceURL)
        let hash = try FileHashing.sha256(of: request.sourceURL, maximumBytes: limits.maximumFileBytes)

        if fileManager.fileExists(atPath: request.destinationURL.path) {
            try fileManager.removeItem(at: request.destinationURL)
        }
        try fileManager.copyItem(at: request.sourceURL, to: request.destinationURL)

        progress(ImportProgress(phase: "Validating the package", fraction: 0.12))
        let archive: Archive
        do {
            archive = try Archive(url: request.sourceURL, accessMode: .read)
        } catch {
            throw AppError.documentCorruptArchive("The file is not a valid ZIP-based DOCX package.")
        }

        var entryCount = 0
        var totalUncompressed: UInt64 = 0
        var hasDocumentPart = false
        var hasMedia = false
        var hasHeadersOrFooters = false
        var hasMacros = false
        for entry in archive {
            entryCount += 1
            guard entryCount <= limits.maximumEntryCount else {
                throw AppError.documentCorruptArchive("The package contains more than \(limits.maximumEntryCount) entries.")
            }
            let uncompressed = UInt64(entry.uncompressedSize)
            let compressed = UInt64(max(1, entry.compressedSize))
            guard uncompressed <= UInt64(limits.maximumEntryBytes) else {
                throw AppError.documentCorruptArchive("An entry expands beyond \(limits.maximumEntryBytes / (1024 * 1024)) MB.")
            }
            if uncompressed > 1024 * 1024, Double(uncompressed) / Double(compressed) > limits.maximumCompressionRatio {
                throw AppError.documentCorruptArchive("An entry has a suspicious compression ratio.")
            }
            totalUncompressed += uncompressed
            guard totalUncompressed <= UInt64(limits.maximumTotalUncompressedBytes) else {
                throw AppError.documentCorruptArchive("The package expands beyond the safe limit.")
            }
            if entry.path == "word/document.xml" { hasDocumentPart = true }
            if entry.path.hasPrefix("word/media/") { hasMedia = true }
            if entry.path.hasPrefix("word/header") || entry.path.hasPrefix("word/footer") { hasHeadersOrFooters = true }
            if entry.path.hasSuffix("vbaProject.bin") || entry.path.hasSuffix("vbaData.xml") { hasMacros = true }
        }
        guard hasDocumentPart else {
            throw AppError.documentCorruptArchive("word/document.xml is missing.")
        }

        progress(ImportProgress(phase: "Reading document structure", fraction: 0.3))
        let documentData = try Self.readEntry("word/document.xml", from: archive, maximumBytes: limits.maximumEntryBytes)
        guard let documentData else {
            throw AppError.documentCorruptArchive("word/document.xml could not be read.")
        }

        var headingStyles: [String: Int] = [:]
        if let stylesData = try Self.readEntry("word/styles.xml", from: archive, maximumBytes: limits.maximumEntryBytes) {
            headingStyles = OOXMLDocumentParser.parseHeadingStyles(stylesData)
        }

        let parsed = try OOXMLDocumentParser.parseDocumentXML(documentData, headingStyles: headingStyles)
        var warnings = parsed.warnings

        var notes: [String] = []
        if let footnotes = try Self.readEntry("word/footnotes.xml", from: archive, maximumBytes: limits.maximumEntryBytes) {
            notes.append(contentsOf: (try? OOXMLDocumentParser.parseNotes(footnotes)) ?? [])
        }
        if let endnotes = try Self.readEntry("word/endnotes.xml", from: archive, maximumBytes: limits.maximumEntryBytes) {
            notes.append(contentsOf: (try? OOXMLDocumentParser.parseNotes(endnotes)) ?? [])
        }

        if let rels = try Self.readEntry("word/_rels/document.xml.rels", from: archive, maximumBytes: 4 * 1024 * 1024),
           let relsString = String(data: rels, encoding: .utf8),
           relsString.contains("TargetMode=\"External\"") || relsString.contains("TargetMode='External'") {
            warnings.append("The document references external resources; they were not fetched.")
        }
        if hasMedia && !parsed.hasDrawings {
            warnings.append("The package contains media files that are not represented as extractable text.")
        }
        if hasHeadersOrFooters {
            warnings.append("Repeated headers and footers were ignored.")
        }
        if hasMacros {
            warnings.append("The document contains macros; they were not executed or extracted.")
        }
        if notes.isEmpty == false {
            warnings.append("\(notes.count) footnote\(notes.count == 1 ? "" : "s") or endnote\(notes.count == 1 ? "" : "s") were appended at the end of the extracted text.")
        }

        progress(ImportProgress(phase: "Preparing source passages", fraction: 0.6))
        let snapshotId = SnapshotID()

        // Build sections from real heading structure only.
        var sections: [DocumentSection] = []
        var sectionIndexByBlock: [Int?] = []
        var currentSectionIndex: Int?
        var sawHeading = false
        for block in parsed.blocks {
            if let level = block.headingLevel {
                sawHeading = true
                let section = DocumentSection(
                    snapshotId: snapshotId,
                    title: Self.cleanHeading(block.text),
                    level: level,
                    order: sections.count,
                    location: SourceLocation(paragraphIndex: block.startParagraphIndex, sectionTitle: nil)
                )
                sections.append(section)
                currentSectionIndex = sections.count - 1
            } else if currentSectionIndex == nil {
                let section = DocumentSection(
                    snapshotId: snapshotId,
                    title: "Document",
                    level: 1,
                    order: sections.count,
                    location: SourceLocation(paragraphIndex: block.startParagraphIndex)
                )
                sections.append(section)
                currentSectionIndex = 0
            }
            sectionIndexByBlock.append(currentSectionIndex)
        }
        if sections.isEmpty {
            sections.append(
                DocumentSection(
                    snapshotId: snapshotId,
                    title: "Document",
                    level: 1,
                    order: 0,
                    location: SourceLocation(paragraphIndex: 0)
                )
            )
        }
        if !sawHeading {
            warnings.append("No heading structure was found; the document is treated as a single section.")
        }

        var textBlocks: [TextBlock] = []
        for (index, block) in parsed.blocks.enumerated() {
            let section = sectionIndexByBlock[index].flatMap { sections.indices.contains($0) ? sections[$0] : nil }
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            textBlocks.append(
                TextBlock(
                    text: trimmed,
                    location: SourceLocation(
                        paragraphIndex: block.startParagraphIndex,
                        endParagraphIndex: block.endParagraphIndex,
                        sectionTitle: section?.title
                    ),
                    method: .docxXML,
                    quality: 1.0,
                    isUsable: true,
                    sectionId: section?.id
                )
            )
        }

        if !notes.isEmpty, !sections.contains(where: { $0.title == "Notes" }) {
            let section = DocumentSection(
                snapshotId: snapshotId,
                title: "Notes",
                level: 2,
                order: sections.count,
                location: SourceLocation(paragraphIndex: max(0, parsed.paragraphCount))
            )
            sections.append(section)
            var nextIndex = parsed.paragraphCount
            for note in notes {
                textBlocks.append(
                    TextBlock(
                        text: note,
                        location: SourceLocation(paragraphIndex: nextIndex, sectionTitle: "Notes"),
                        method: .docxXML,
                        quality: 1.0,
                        isUsable: true,
                        sectionId: section.id
                    )
                )
                nextIndex += 1
            }
        }

        guard !textBlocks.isEmpty else {
            throw AppError.documentEmpty("No extractable text was found in this DOCX file.")
        }

        let chunked = Chunker.chunk(blocks: textBlocks, snapshotId: snapshotId)
        let usableChunks = chunked.chunks.filter(\.isUsableAsEvidence)
        let usableCharacters = usableChunks.reduce(0) { $0 + $1.text.count }
        let qualityInfo = DocumentQuality(
            pagesProcessed: 0,
            pagesRequiringOCR: 0,
            pagesUnreadable: 0,
            paragraphsExtracted: textBlocks.count,
            charactersExtracted: chunked.fullText.count,
            warnings: warnings
        )
        guard usableCharacters >= limits.minimumUsableCharactersForStudy, !usableChunks.isEmpty else {
            throw AppError.documentInsufficientText(
                "Only \(usableCharacters) characters of reliable text were found. \(qualityInfo.summary)."
            )
        }

        let snapshot = DocumentSnapshot(
            id: snapshotId,
            documentId: request.documentId,
            version: 1,
            textHash: TextUtilities.sha256Hex(chunked.fullText),
            quality: qualityInfo
        )

        progress(ImportProgress(phase: "Ready", fraction: 1.0))
        return DocumentImportResult(
            documentName: request.documentName,
            fileType: .docx,
            fileHash: hash,
            textHash: snapshot.textHash,
            storedFileName: request.destinationURL.lastPathComponent,
            snapshot: snapshot,
            sections: sections,
            chunks: chunked.chunks,
            fullText: chunked.fullText,
            language: LanguageDetector.detect(from: chunked.fullText),
            parserVersion: parserVersion
        )
    }

    // MARK: Helpers

    static func validatePackageSignature(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 4) ?? Data()
        // Encrypted OOXML is a CFB container, not a ZIP.
        if prefix.count >= 4, prefix[0] == 0xD0, prefix[1] == 0xCF, prefix[2] == 0x11, prefix[3] == 0xE0 {
            throw AppError.documentCorruptArchive("The DOCX is encrypted or password protected; remove the password and import it again.")
        }
        guard prefix.count >= 4, prefix[0] == 0x50, prefix[1] == 0x4B else {
            throw AppError.documentCorruptArchive("The file is not a ZIP-based DOCX package.")
        }
    }

    static func readEntry(_ path: String, from archive: Archive, maximumBytes: Int) throws -> Data? {
        guard let entry = archive[path], entry.type == .file else { return nil }
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            data.append(chunk)
            if data.count > maximumBytes {
                throw AppError.documentCorruptArchive("An entry expands beyond the safe limit.")
            }
        })
        return data
    }

    static func cleanHeading(_ text: String) -> String {
        let cleaned = TextUtilities.normalizeWhitespace(text)
        if cleaned.isEmpty { return "Section" }
        return String(cleaned.prefix(120))
    }
}

// MARK: - Language

public enum LanguageDetector {
    public static func detect(from text: String) -> String? {
        let sample = String(text.prefix(4000))
        guard sample.count > 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return confidence >= 0.3 ? language.rawValue : nil
    }
}

// MARK: - Factory

public enum DocumentImporterFactory {
    public static func importer(for fileType: DocumentFileType) -> any DocumentImporter {
        switch fileType {
        case .pdf: return PDFDocumentImporter()
        case .docx: return DOCXDocumentImporter()
        }
    }

    public static func fileType(for url: URL) -> DocumentFileType? {
        let ext = url.pathExtension.lowercased()
        return DocumentFileType.allCases.first { $0.fileExtensions.contains(ext) }
    }
}
