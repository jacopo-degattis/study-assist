import SwiftUI
import StudyDomain
import StudyEngine
import StudyDesignSystem
import UniformTypeIdentifiers

struct LibraryHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false
    @State private var deleteTarget: DocumentSummary?

    var body: some View {
        ScrollView {
            ReadingColumn {
                VStack(alignment: .leading, spacing: StudyDesign.spacingXL) {
                    header
                    if let error = model.libraryError {
                        ErrorBanner(message: error) {
                            model.libraryError = nil
                        }
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    importCard
                    if model.importing != nil {
                        importingCard
                    }
                    if model.documents.isEmpty {
                        EmptyStateView(
                            symbol: "doc.text.magnifyingglass",
                            title: "Study one document at a time",
                            message: "Import a PDF or DOCX file. Questions, corrections and hints come only from its text."
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        documentsList
                    }
                    privacyFootnote
                }
                .padding(.vertical, StudyDesign.spacingXXL)
            }
        }
        .navigationTitle("Documents")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.importDocument(from: url) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Delete this document?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { summary in
            Button("Delete \"\(summary.document.name)\" and its history", role: .destructive) {
                let id = summary.document.id
                deleteTarget = nil
                Task { await model.deleteDocument(id) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("The app-owned copy, extracted passages, topics, sessions and answers for this document will be removed. This cannot be undone here.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Documents")
                .font(StudyDesign.titleFont)
            Text("One active document per session. Your files stay on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var importCard: some View {
        StudyCard {
            HStack(spacing: 16) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Study a document")
                        .font(StudyDesign.headingFont)
                    Text("Drag a PDF or DOCX here, or choose a file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose PDF or DOCX…") {
                    model.requestImportPanel()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.importing != nil)
            }
        }
    }

    private var importingCard: some View {
        StudyCard {
            VStack(alignment: .leading, spacing: 10) {
                BusyLabel(
                    text: model.importing?.phase ?? "Importing",
                    progress: model.importing?.fraction
                )
                Label("Parsing runs on this Mac. The window stays responsive.", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var documentsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library")
                .font(StudyDesign.headingFont)
            ForEach(model.documents, id: \.document.id) { summary in
                documentRow(summary)
            }
        }
    }

    private func documentRow(_ summary: DocumentSummary) -> some View {
        Button {
            Task { await model.selectDocument(summary.document.id) }
        } label: {
            StudyCard {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: summary.document.fileType == .pdf ? "doc.richtext" : "doc.text")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.document.name)
                            .font(StudyDesign.headingFont)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(summary.document.fileType.displayName)
                            Text("·")
                            Text("\(summary.sectionCount) sections")
                            Text("·")
                            Text("\(summary.topicCount) topics")
                            if let lastStudied = summary.lastStudiedAt {
                                Text("·")
                                Text("last studied \(lastStudied.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let quality = summary.quality, !quality.warnings.isEmpty {
                            Label(quality.summary, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Import updated version…") {
                model.requestReplacePanel(for: summary.document.id)
            }
            Divider()
            Button("Delete…", role: .destructive) { deleteTarget = summary }
        }
        .accessibilityHint("Opens the document to start or resume studying")
    }

    private var privacyFootnote: some View {
        Label("Documents and history are stored in \(model.storageLocation). When a cloud model is active, only the passages needed for a question or an assessment are sent to that provider.", systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
