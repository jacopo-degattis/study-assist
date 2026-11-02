import Foundation
import PDFKit
import Vision
import AppKit
import StudyDomain

/// Extracts text from PDF files page by page, running on-device OCR only where
/// the text layer is missing or clearly unreliable.
public struct PDFDocumentImporter: DocumentImporter {
    public let supportedType: DocumentFileType = .pdf
    public let parserVersion = "pdf-1.0.0"

    let configuration: Configuration

    public struct Configuration: Sendable {
        public var maximumFileBytes: Int
        public var minimumCharactersPerPage: Int
        public var ocrRenderScale: CGFloat
        public var ocrMinimumConfidence: Double
        public var minimumUsableCharactersForStudy: Int

        public init(
            maximumFileBytes: Int = 120 * 1024 * 1024,
            minimumCharactersPerPage: Int = 40,
            ocrRenderScale: CGFloat = 2.0,
            ocrMinimumConfidence: Double = 0.5,
            minimumUsableCharactersForStudy: Int = 200
        ) {
            self.maximumFileBytes = maximumFileBytes
            self.minimumCharactersPerPage = minimumCharactersPerPage
            self.ocrRenderScale = ocrRenderScale
            self.ocrMinimumConfidence = ocrMinimumConfidence
            self.minimumUsableCharactersForStudy = minimumUsableCharactersForStudy
        }

        public static let `default` = Configuration()
    }

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public func importDocument(
        _ request: DocumentImportRequest,
        progress: @Sendable (ImportProgress) -> Void
    ) async throws -> DocumentImportResult {
        let sourceURL = request.sourceURL
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AppError.documentUnreadable("The file no longer exists at its original location.")
        }
        let fileSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 0 else { throw AppError.documentEmpty("The file is empty.") }
        guard fileSize <= configuration.maximumFileBytes else {
            throw AppError.documentTooLarge("PDF files must be smaller than \(configuration.maximumFileBytes / (1024 * 1024)) MB.")
        }

        progress(ImportProgress(phase: "Copying into the library", fraction: 0.02))
        let hash = try FileHashing.sha256(of: sourceURL, maximumBytes: configuration.maximumFileBytes)
        if fileManager.fileExists(atPath: request.destinationURL.path) {
            try fileManager.removeItem(at: request.destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: request.destinationURL)

        progress(ImportProgress(phase: "Reading the PDF", fraction: 0.05))
        guard let document = PDFDocument(url: sourceURL) else {
            throw AppError.documentUnreadable("The file is not a readable PDF.")
        }
        guard !document.isLocked else {
            throw AppError.documentUnreadable("The PDF is password protected.")
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw AppError.documentEmpty("The PDF has no pages.")
        }

        var blocks: [TextBlock] = []
        var sections: [DocumentSection] = []
        var warnings: [String] = []
        var ocrPageCount = 0
        var unreadablePageCount = 0
        var unreliablePageCount = 0
        var paragraphsExtracted = 0

        let snapshotId = SnapshotID()
        let outline = PDFOutlineSections.read(from: document)
        let sectionPlan = Self.sectionPlan(pageCount: pageCount, outline: outline)
        var sectionByPage: [Int: DocumentSection] = [:]
        for section in sectionPlan {
            sections.append(
                DocumentSection(
                    snapshotId: snapshotId,
                    title: section.title,
                    level: section.level,
                    order: sections.count,
                    location: SourceLocation(pageNumber: section.startPage + 1, sectionTitle: section.title)
                )
            )
        }
        let builtSections = sections
        for (index, section) in sectionPlan.enumerated() {
            for page in section.startPage..<section.endPage {
                sectionByPage[page] = builtSections[index]
            }
        }
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            let fraction = 0.08 + 0.75 * (Double(pageIndex) / Double(pageCount))
            progress(ImportProgress(phase: "Extracting page \(pageIndex + 1) of \(pageCount)", fraction: fraction))

            guard let page = document.page(at: pageIndex) else {
                unreadablePageCount += 1
                continue
            }
            let section = sectionByPage[pageIndex]
            let rawText = page.string ?? ""
            let assessment = Self.assess(text: rawText, minimumCharacters: configuration.minimumCharactersPerPage)

            var pageText: String
            var method: ExtractionMethod
            var quality: Double
            var usable: Bool

            if assessment.needsOCR {
                let ocr = OCRTextRecognizer.recognize(page: page, scale: configuration.ocrRenderScale)
                if ocr.text.count > max(rawText.count, configuration.minimumCharactersPerPage) || rawText.isEmpty {
                    ocrPageCount += 1
                    pageText = ocr.text
                    method = .pdfOCR
                    quality = ocr.confidence
                    usable = ocr.confidence >= configuration.ocrMinimumConfidence
                        && TextUtilities.normalizeWhitespace(ocr.text).count >= 20
                    if !usable { unreadablePageCount += 1 }
                    if ocr.confidence < 0.75 { unreliablePageCount += 1 }
                } else {
                    pageText = rawText
                    method = .pdfText
                    quality = assessment.quality
                    usable = assessment.isUsable
                }
            } else {
                pageText = rawText
                method = .pdfText
                quality = assessment.quality
                usable = assessment.isUsable
            }

            let cleanedLines = pageText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let cleaned = cleanedLines.joined(separator: "\n")
            if cleaned.isEmpty {
                unreadablePageCount += 1
                continue
            }

            paragraphsExtracted += 1
            blocks.append(
                TextBlock(
                    text: cleaned,
                    location: SourceLocation(
                        pageNumber: pageIndex + 1,
                        sectionTitle: section?.title
                    ),
                    method: method,
                    quality: quality,
                    isUsable: usable,
                    sectionId: section?.id
                )
            )
        }

        progress(ImportProgress(phase: "Preparing source passages", fraction: 0.86))
        let chunked = Chunker.chunk(blocks: blocks, snapshotId: snapshotId)

        if ocrPageCount > 0 {
            warnings.append("\(ocrPageCount) page\(ocrPageCount == 1 ? "" : "s") were transcribed with on-device OCR; recognition can be imperfect.")
        }
        if unreliablePageCount > 0 {
            warnings.append("\(unreliablePageCount) OCR page\(unreliablePageCount == 1 ? "" : "s") had low recognition confidence and are excluded from evidence.")
        }
        if unreadablePageCount > 0 {
            warnings.append("\(unreadablePageCount) page\(unreadablePageCount == 1 ? "" : "s") contained no reliable text and were left out of study material.")
        }

        let usableChunks = chunked.chunks.filter(\.isUsableAsEvidence)
        let usableCharacters = usableChunks.reduce(0) { $0 + $1.text.count }
        let qualityInfo = DocumentQuality(
            pagesProcessed: pageCount,
            pagesRequiringOCR: ocrPageCount,
            pagesUnreadable: unreadablePageCount,
            paragraphsExtracted: paragraphsExtracted,
            charactersExtracted: chunked.fullText.count,
            warnings: warnings
        )

        guard usableCharacters >= configuration.minimumUsableCharactersForStudy, !usableChunks.isEmpty else {
            throw AppError.documentInsufficientText(
                "Only \(usableCharacters) characters of reliable text were found in \(pageCount) pages. \(qualityInfo.summary)."
            )
        }

        let language = LanguageDetector.detect(from: chunked.fullText)
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
            fileType: .pdf,
            fileHash: hash,
            textHash: snapshot.textHash,
            storedFileName: request.destinationURL.lastPathComponent,
            snapshot: snapshot,
            sections: sections,
            chunks: chunked.chunks,
            fullText: chunked.fullText,
            language: language,
            parserVersion: parserVersion
        )
    }

    // MARK: Helpers

    struct TextAssessment {
        var needsOCR: Bool
        var isUsable: Bool
        var quality: Double
    }

    static func assess(text: String, minimumCharacters: Int) -> TextAssessment {
        let normalized = TextUtilities.normalizeWhitespace(text)
        guard normalized.count >= minimumCharacters else {
            return TextAssessment(needsOCR: true, isUsable: false, quality: 0.2)
        }
        let visible = normalized.filter { !$0.isWhitespace }
        guard !visible.isEmpty else {
            return TextAssessment(needsOCR: true, isUsable: false, quality: 0.1)
        }
        let alphanumeric = visible.filter { $0.isLetter || $0.isNumber }.count
        let ratio = Double(alphanumeric) / Double(visible.count)
        let replacementCharacters = visible.filter { $0 == "\u{FFFD}" }.count
        let replacementRatio = Double(replacementCharacters) / Double(visible.count)
        let controlCharacters = normalized.unicodeScalars.filter { $0.value < 32 && $0 != "\n" }.count

        let needsOCR = ratio < 0.55 || replacementRatio > 0.02 || controlCharacters > 5
        let quality = max(0.1, min(1.0, ratio))
        return TextAssessment(needsOCR: needsOCR, isUsable: !needsOCR && ratio > 0.4, quality: quality)
    }

    struct SectionPlan {
        var title: String
        var level: Int
        var startPage: Int
        var endPage: Int
    }

    static func sectionPlan(pageCount: Int, outline: [PDFOutlineSections.Entry]) -> [SectionPlan] {
        // Outline entries are real document structure. Page sections are an honest
        // fallback when the PDF has no outline.
        if outline.count >= 2 {
            var plans: [SectionPlan] = []
            for (index, entry) in outline.enumerated() {
                let start = min(max(0, entry.pageIndex), max(0, pageCount - 1))
                let nextStart = index + 1 < outline.count
                    ? min(max(0, outline[index + 1].pageIndex), max(0, pageCount - 1))
                    : pageCount
                let end = nextStart > start ? nextStart : min(pageCount, start + 1)
                plans.append(SectionPlan(title: Self.cleanTitle(entry.title), level: entry.level, startPage: start, endPage: end))
            }
            let covered = plans.reduce(0) { $0 + (($1.endPage - $1.startPage)) }
            if covered < pageCount {
                // Pages before the first outline entry still need a section.
                for page in 0..<pageCount where !plans.contains(where: { page >= $0.startPage && page < $0.endPage }) {
                    plans.append(SectionPlan(title: "Page \(page + 1)", level: 1, startPage: page, endPage: page + 1))
                }
            }
            return plans.sorted { $0.startPage < $1.startPage }.reduce(into: []) { result, plan in
                if let last = result.last, last.startPage == plan.startPage {
                    return
                }
                result.append(plan)
            }
        }
        return (0..<pageCount).map { page in
            SectionPlan(title: "Page \(page + 1)", level: 1, startPage: page, endPage: page + 1)
        }
    }

    static func cleanTitle(_ title: String) -> String {
        let trimmed = TextUtilities.normalizeWhitespace(title)
        if trimmed.isEmpty { return "Section" }
        return String(trimmed.prefix(120))
    }
}

// MARK: - PDF outline

enum PDFOutlineSections {
    struct Entry {
        var title: String
        var level: Int
        var pageIndex: Int
    }

    static func read(from document: PDFDocument) -> [Entry] {
        guard let root = document.outlineRoot else { return [] }
        var entries: [Entry] = []
        func walk(_ outline: PDFOutline, level: Int) {
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let destination = child.destination,
                   let page = destination.page,
                   !title.isEmpty {
                    let pageIndex = document.index(for: page)
                    if pageIndex != NSNotFound {
                        entries.append(Entry(title: title, level: level, pageIndex: pageIndex))
                    }
                }
                if child.numberOfChildren > 0 {
                    walk(child, level: level + 1)
                }
            }
        }
        walk(root, level: 1)
        return entries
    }
}

// MARK: - OCR

struct OCRTextRecognizer {
    struct Result {
        var text: String
        var confidence: Double
    }

    static func recognize(page: PDFPage, scale: CGFloat) -> Result {
        guard let image = render(page: page, scale: scale) else {
            return Result(text: "", confidence: 0)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return Result(text: "", confidence: 0)
        }

        guard let observations = request.results, !observations.isEmpty else {
            return Result(text: "", confidence: 0)
        }

        // Reading order: top to bottom, then left to right.
        let sorted = observations.sorted { lhs, rhs in
            let a = lhs.boundingBox
            let b = rhs.boundingBox
            if abs(a.midY - b.midY) > 0.02 {
                return a.midY > b.midY
            }
            return a.minX < b.minX
        }

        var lines: [String] = []
        var confidenceTotal: Double = 0
        var confidenceCount: Double = 0
        var previousMidY: CGFloat?
        for observation in sorted {
            guard let candidate = observation.topCandidates(1).first else { continue }
            if let previousMidY, abs(previousMidY - observation.boundingBox.midY) > 0.02 {
                lines.append("") // paragraph break between separated bands
            }
            previousMidY = observation.boundingBox.midY
            lines.append(candidate.string)
            confidenceTotal += Double(candidate.confidence)
            confidenceCount += 1
        }

        let text = lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
        let confidence = confidenceCount > 0 ? confidenceTotal / confidenceCount : 0
        return Result(text: text, confidence: confidence)
    }

    static func render(page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let longestSide: CGFloat = 4000
        let effectiveScale = min(scale, longestSide / max(bounds.width, bounds.height))
        let width = Int(bounds.width * effectiveScale)
        let height = Int(bounds.height * effectiveScale)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: effectiveScale, y: effectiveScale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
