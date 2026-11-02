import SwiftUI
import PDFKit
import StudyDomain
import StudyDesignSystem

struct SourceViewerView: View {
    let document: StudyDocument
    let target: StudyViewModel.SourceViewerTarget
    let evidence: [SourceChunk]
    let storedFileURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: document.fileType == .pdf ? "doc.richtext" : "doc.text")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .font(StudyDesign.headingFont)
                        .lineLimit(1)
                    Text(referenceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            switch document.fileType {
            case .pdf:
                if FileManager.default.fileExists(atPath: storedFileURL.path) {
                    PDFKitPageView(url: storedFileURL, pageNumber: target.page)
                } else {
                    missingFile
                }
            case .docx:
                docxView
            }
        }
        .frame(minWidth: 780, minHeight: 600)
    }

    private var referenceDescription: String {
        if let page = target.page {
            return "Page \(page) · \(document.name)"
        }
        let locations = evidence.compactMap(\.location.paragraphIndex)
        if let first = locations.min() {
            return "Paragraph \(first + 1) · \(document.name)"
        }
        return document.name
    }

    private var missingFile: some View {
        EmptyStateView(
            symbol: "doc.questionmark",
            title: "The stored file is missing",
            message: "The passages are still available below. Re-import the document to view the original pages."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var docxView: some View {
        ScrollView {
            ReadingColumn {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Extracted paragraphs, read-only. DOCX has no stable page numbers, so references use paragraph positions.", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(evidence) { chunk in
                        StudyCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(chunk.location.shortDescription)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    if chunk.extractionMethod == .pdfOCR {
                                        Text("OCR")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .background(.orange.opacity(0.15), in: Capsule())
                                    }
                                }
                                Text(chunk.text)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.vertical, 18)
            }
        }
    }
}

/// PDFView focused on the real page. Page numbers come from the PDF itself.
private struct PDFKitPageView: NSViewRepresentable {
    let url: URL
    let pageNumber: Int?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        if let pageNumber, let document = view.document,
           pageNumber >= 1, pageNumber <= document.pageCount,
           let page = document.page(at: pageNumber - 1) {
            view.go(to: page)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document == nil {
            view.document = PDFDocument(url: url)
        }
    }
}
