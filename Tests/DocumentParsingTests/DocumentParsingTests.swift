import XCTest
import Foundation
import AppKit
import PDFKit
import ZIPFoundation
@testable import StudyDocuments
import StudyDomain

final class DocumentParsingTests: XCTestCase {
    var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyAppParsing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: Chunking

    func testChunksAreExactContiguousRangesOfTheSnapshotText() {
        let snapshotId = SnapshotID()
        let blocks = [
            TextBlock(
                text: "Depolarization is caused by sodium influx. It raises the membrane potential.",
                location: SourceLocation(pageNumber: 1, sectionTitle: "Action potential"),
                method: .pdfText
            ),
            TextBlock(
                text: "Repolarization is caused by potassium efflux. It restores the resting potential.",
                location: SourceLocation(pageNumber: 2, sectionTitle: "Action potential"),
                method: .pdfText
            ),
        ]
        let result = Chunker.chunk(
            blocks: blocks,
            snapshotId: snapshotId,
            configuration: Chunker.Configuration(targetTokens: 8, maximumTokens: 20, overlapSentences: 0, minimumEvidenceCharacters: 10)
        )
        XCTAssertFalse(result.chunks.isEmpty)
        for chunk in result.chunks {
            let slice = Chunker.substring(result.fullText, utf16Range: chunk.startOffset..<chunk.endOffset)
            XCTAssertEqual(slice, chunk.text, "Chunk text must be the stored text at its own offsets")
            XCTAssertTrue(chunk.isUsableAsEvidence)
            XCTAssertEqual(chunk.snapshotId, snapshotId)
        }
        // Page provenance survives chunking.
        XCTAssertEqual(Set(result.chunks.compactMap { $0.location.pageNumber }), [1, 2])
    }

    func testUnusableBlocksProduceUnusableChunks() {
        let blocks = [
            TextBlock(
                text: "This text came from an OCR page with very low confidence and must not be used as evidence.",
                location: SourceLocation(pageNumber: 3),
                method: .pdfOCR,
                quality: 0.12,
                isUsable: false
            )
        ]
        let result = Chunker.chunk(blocks: blocks, snapshotId: SnapshotID())
        XCTAssertTrue(result.chunks.allSatisfy { !$0.isUsableAsEvidence })
        XCTAssertTrue(result.chunks.allSatisfy { $0.extractionMethod == .pdfOCR })
    }

    func testSentenceSplittingPreservesUnicodeOffsets() {
        let text = "Café naïve — first sentence. Second sentence with ünïcode! Third?"
        let ranges = Chunker.sentenceRanges(in: text)
        XCTAssertEqual(ranges.count, 3)
        for range in ranges {
            let extracted = Chunker.substring(text, utf16Range: range.start..<range.end)
            XCTAssertEqual(extracted, range.text)
        }
    }

    // MARK: DOCX

    func testDOCXImportPreservesHeadingsParagraphsTablesAndNotes() async throws {
        let docx = try makeDOCX(named: "study.docx", includeNotes: true, includeDrawing: false, includeHeader: false)
        let destination = workDirectory.appendingPathComponent("stored.docx")
        let importer = DOCXDocumentImporter()
        let request = DocumentImportRequest(
            sourceURL: docx,
            destinationURL: destination,
            documentId: DocumentID(),
            documentName: "study"
        )
        let result = try await importer.importDocument(request, progress: { _ in })

        XCTAssertEqual(result.fileType, .docx)
        XCTAssertTrue(result.sections.contains { $0.title == "Action potential" })
        XCTAssertTrue(result.sections.contains { $0.title == "Notes" })
        XCTAssertTrue(result.chunks.contains { $0.text.contains("sodium influx") })
        XCTAssertTrue(result.chunks.allSatisfy { $0.extractionMethod == .docxXML })
        XCTAssertTrue(result.chunks.allSatisfy { $0.location.pageNumber == nil }, "DOCX must not invent page numbers")
        XCTAssertTrue(result.chunks.contains { $0.text.contains("Phase | Ion") && $0.text.contains("Depolarization | Sodium") })
        XCTAssertTrue(result.chunks.contains { $0.text.contains("Footnote about ion channels") })
        XCTAssertTrue(result.snapshot.quality.warnings.contains { $0.contains("footnote") })
        XCTAssertEqual(result.snapshot.textHash, TextUtilities.sha256Hex(result.fullText))
        // No headings beyond the real ones.
        XCTAssertFalse(result.sections.contains { $0.title.hasPrefix("Paragraph") })
    }

    func testDOCXRejectsArchiveWithoutDocumentPart() async throws {
        let url = workDirectory.appendingPathComponent("bad.docx")
        try writeArchive(at: url, entries: [("[Content_Types].xml", "<Types/>")])
        do {
            _ = try await runDOCXImport(url)
            XCTFail("Expected the archive to be rejected")
        } catch let error as AppError {
            guard case AppError.documentCorruptArchive = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDOCXRejectsNonZipFile() async throws {
        let url = workDirectory.appendingPathComponent("text.docx")
        try Data("This is not a ZIP package".utf8).write(to: url)
        do {
            _ = try await runDOCXImport(url)
            XCTFail("Expected the file to be rejected")
        } catch let error as AppError {
            guard case AppError.documentCorruptArchive = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDOCXWarnsAboutUnavailableMaterial() async throws {
        let url = try makeDOCX(named: "warn.docx", includeNotes: false, includeDrawing: true, includeHeader: true)
        let result = try await runDOCXImport(url)
        XCTAssertTrue(result.snapshot.quality.warnings.contains { $0.lowercased().contains("drawing") })
        XCTAssertTrue(result.snapshot.quality.warnings.contains { $0.lowercased().contains("header") })
    }

    func testDOCXEnforcesEntryCountLimit() async throws {
        let url = workDirectory.appendingPathComponent("many.docx")
        try writeArchive(at: url, entries: [
            ("[Content_Types].xml", "<Types/>"),
            ("word/document.xml", minimalDocumentXML("One sentence.")),
            ("word/styles.xml", "<styles/>"),
            ("word/extra1.xml", "<x/>"),
            ("word/extra2.xml", "<x/>"),
        ])
        let importer = DOCXDocumentImporter(limits: .init(maximumEntryCount: 3))
        let request = DocumentImportRequest(
            sourceURL: url,
            destinationURL: workDirectory.appendingPathComponent("copy.docx"),
            documentId: DocumentID(),
            documentName: "many"
        )
        do {
            _ = try await importer.importDocument(request, progress: { _ in })
            XCTFail("Expected the archive to be rejected")
        } catch let error as AppError {
            guard case AppError.documentCorruptArchive = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: PDF

    func testPDFTextImportKeepsRealPageNumbers() async throws {
        let url = try makeTextPDF(named: "notes.pdf", pageTexts: [
            "Depolarization is caused by sodium influx through voltage-gated channels. This raises the membrane potential toward threshold and triggers the upstroke of the action potential.",
            "Repolarization is caused by potassium efflux from the cell. This restores the negative resting potential and ends the action potential.",
        ])
        let result = try await runPDFImport(url)
        XCTAssertEqual(result.snapshot.quality.pagesProcessed, 2)
        XCTAssertEqual(result.snapshot.quality.pagesRequiringOCR, 0)
        XCTAssertEqual(Set(result.chunks.compactMap { $0.location.pageNumber }), [1, 2])
        XCTAssertTrue(result.chunks.contains { $0.text.contains("sodium influx") })
        XCTAssertTrue(result.chunks.contains { $0.text.contains("potassium efflux") })
        XCTAssertEqual(Set(result.sections.map(\.title)), ["Page 1", "Page 2"], "Without an outline, page sections are used")
    }

    func testPDFWithNoTextLayerIsRejectedInsteadOfInventingContent() async throws {
        let url = try makeTextPDF(named: "blank.pdf", pageTexts: [""])
        do {
            _ = try await runPDFImport(url)
            XCTFail("Expected the document to be rejected as unreadable")
        } catch let error as AppError {
            guard case AppError.documentInsufficientText = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testScannedPDFIsTranscribedOnDeviceWithOCRProvenance() async throws {
        let text = "Sodium influx through voltage-gated channels causes depolarization of the membrane. Potassium efflux then causes repolarization and restores the resting potential. The action potential therefore depends on the coordinated activity of these ion channels."
        let url = try makeScannedPDF(named: "scan.pdf", text: text)
        let result = try await runPDFImport(url)
        XCTAssertEqual(result.snapshot.quality.pagesProcessed, 1)
        XCTAssertEqual(result.snapshot.quality.pagesRequiringOCR, 1)
        XCTAssertTrue(result.chunks.contains { $0.extractionMethod == .pdfOCR })
        XCTAssertTrue(result.snapshot.quality.warnings.contains { $0.lowercased().contains("ocr") })
        let recognized = result.fullText.lowercased()
        XCTAssertTrue(recognized.contains("sodium") || recognized.contains("depolarization"), "OCR should read the rendered text")
        XCTAssertTrue(result.chunks.allSatisfy { $0.location.pageNumber == 1 })
    }

    func testPDFQualityAssessmentFlagsGarbageText() {
        let garbage = String(repeating: "\u{FFFD}#$%", count: 40)
        let assessment = PDFDocumentImporter.assess(text: garbage, minimumCharacters: 40)
        XCTAssertTrue(assessment.needsOCR, "Unreadable text must trigger OCR rather than become evidence")

        let clean = "This is a normal sentence about the membrane potential and its phases."
        let cleanAssessment = PDFDocumentImporter.assess(text: clean, minimumCharacters: 40)
        XCTAssertFalse(cleanAssessment.needsOCR)
        XCTAssertTrue(cleanAssessment.isUsable)
    }

    // MARK: Helpers

    private func runDOCXImport(_ url: URL) async throws -> DocumentImportResult {
        let importer = DOCXDocumentImporter()
        let request = DocumentImportRequest(
            sourceURL: url,
            destinationURL: workDirectory.appendingPathComponent("copy-\(UUID().uuidString).docx"),
            documentId: DocumentID(),
            documentName: "test"
        )
        return try await importer.importDocument(request, progress: { _ in })
    }

    private func runPDFImport(_ url: URL) async throws -> DocumentImportResult {
        let importer = PDFDocumentImporter()
        let request = DocumentImportRequest(
            sourceURL: url,
            destinationURL: workDirectory.appendingPathComponent("copy-\(UUID().uuidString).pdf"),
            documentId: DocumentID(),
            documentName: "test"
        )
        return try await importer.importDocument(request, progress: { _ in })
    }

    private func makeScannedPDF(named name: String, text: String) throws -> URL {
        let size = NSSize(width: 1_224, height: 1_584)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 46),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(
            in: NSRect(x: 90, y: 300, width: size.width - 180, height: size.height - 600),
            withAttributes: attributes
        )
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage
        else {
            throw AppError.documentImportFailed("Could not render the scanned fixture.")
        }
        let url = workDirectory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw AppError.documentImportFailed("Could not create the scanned PDF fixture.")
        }
        context.beginPDFPage(nil)
        context.draw(cgImage, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func makeTextPDF(named name: String, pageTexts: [String]) throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw AppError.documentImportFailed("Could not create the PDF fixture.")
        }
        for text in pageTexts {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.black,
            ]
            (text as NSString).draw(in: CGRect(x: 60, y: 600, width: 480, height: 160), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func makeDOCX(named name: String, includeNotes: Bool, includeDrawing: Bool, includeHeader: Bool) throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        var entries: [(String, String)] = [
            ("[Content_Types].xml", "<Types/>"),
            ("word/document.xml", documentXML(includeDrawing: includeDrawing)),
            ("word/styles.xml", stylesXML),
        ]
        if includeNotes { entries.append(("word/footnotes.xml", footnotesXML)) }
        if includeHeader { entries.append(("word/header1.xml", "<w:hdr/>")) }
        try writeArchive(at: url, entries: entries)
        return url
    }

    /// Writes a ZIP and returns only after the archive is closed on deallocation.
    private func writeArchive(at url: URL, entries: [(String, String)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, content) in entries {
            try addEntry(archive, path, content)
        }
    }

    private func addEntry(_ archive: Archive, _ path: String, _ content: String) throws {
        // Real OOXML parts start with the XML declaration at byte zero.
        let data = Data(content.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                guard start < end else { return Data() }
                return data.subdata(in: start..<end)
            }
        )
    }

    private func minimalDocumentXML(_ text: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body>
        </w:document>
        """
    }

    private var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="heading 1"/>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Normal">
            <w:name w:val="Normal"/>
          </w:style>
        </w:styles>
        """
    }

    private var footnotesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:footnote w:id="1"><w:p><w:r><w:t>Footnote about ion channels.</w:t></w:r></w:p></w:footnote>
        </w:footnotes>
        """
    }

    private func documentXML(includeDrawing: Bool) -> String {
        let drawing = includeDrawing
            ? "<w:p><w:r><w:drawing/></w:r></w:p>"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Action potential</w:t></w:r></w:p>
            <w:p><w:r><w:t>Depolarization is caused by sodium influx through voltage-gated channels.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Repolarization is caused by potassium efflux from the cell.</w:t></w:r></w:p>
            <w:p><w:r><w:t>This paragraph adds enough reliable text for the document to qualify for study and to exercise the extraction thresholds.</w:t></w:r></w:p>
            <w:tbl>
              <w:tr>
                <w:tc><w:p><w:r><w:t>Phase</w:t></w:r></w:p></w:tc>
                <w:tc><w:p><w:r><w:t>Ion</w:t></w:r></w:p></w:tc>
              </w:tr>
              <w:tr>
                <w:tc><w:p><w:r><w:t>Depolarization</w:t></w:r></w:p></w:tc>
                <w:tc><w:p><w:r><w:t>Sodium</w:t></w:r></w:p></w:tc>
              </w:tr>
            </w:tbl>
            \(drawing)
            <w:sectPr/>
          </w:body>
        </w:document>
        """
    }
}
