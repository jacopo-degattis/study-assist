import SwiftUI
import StudyDomain
import StudyEngine
import StudyDesignSystem

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var records: [HistoryRecord] = []
    @State private var documents: [StudyDocument] = []
    @State private var documentFilter: DocumentID?
    @State private var statusFilter: EvaluationStatus?
    @State private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var toDate = Date()
    @State private var useDateRange = false
    @State private var selected: HistoryRecord?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .navigationTitle("History")
        .task { await reload() }
        .onChange(of: documentFilter) { _, _ in Task { await reload() } }
        .onChange(of: statusFilter) { _, _ in Task { await reload() } }
        .onChange(of: useDateRange) { _, _ in Task { await reload() } }
        .onChange(of: fromDate) { _, _ in if useDateRange { Task { await reload() } } }
        .onChange(of: toDate) { _, _ in if useDateRange { Task { await reload() } } }
        .sheet(item: $selected) { record in
            HistoryDetailView(record: record)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 14) {
            Picker("Document", selection: $documentFilter) {
                Text("All documents").tag(DocumentID?.none)
                ForEach(documents) { document in
                    Text(document.name).tag(DocumentID?.some(document.id))
                }
            }
            .frame(minWidth: 180, maxWidth: 260)

            Picker("Outcome", selection: $statusFilter) {
                Text("Any outcome").tag(EvaluationStatus?.none)
                ForEach(EvaluationStatus.allCases, id: \.self) { status in
                    Text(status.displayName).tag(EvaluationStatus?.some(status))
                }
            }
            .frame(minWidth: 140, maxWidth: 200)

            Toggle("Date range", isOn: $useDateRange)
            if useDateRange {
                DatePicker("From", selection: $fromDate, displayedComponents: .date)
                DatePicker("To", selection: $toDate, displayedComponents: .date)
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .labelsHidden()
        .controlSize(.small)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ErrorBanner(message: errorMessage) { Task { await reload() } }
                .padding(16)
        }
        if records.isEmpty {
            EmptyStateView(
                symbol: "clock",
                title: "No answers yet",
                message: "Finished and interrupted sessions appear here, with each answer, its assessment and the passages used."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                ReadingColumn {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(records) { record in
                            Button {
                                selected = record
                            } label: {
                                row(record)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the full answer and assessment")
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private func row(_ record: HistoryRecord) -> some View {
        StudyCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let evaluation = record.evaluation {
                        EvaluationBadge(status: evaluation.effectiveStatus)
                    } else {
                        StatusBadge(title: "Not graded", systemImage: "circle", color: .secondary)
                    }
                    Text(record.documentName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let topic = record.topicTitle {
                        Text("· \(topic)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let scope = record.scope {
                        Text("· \(scope.displayTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(record.attempt.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(record.question.text)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(record.attempt.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            documents = try await model.repository.documents()
            var filters = HistoryFilters(documentId: documentFilter, status: statusFilter)
            if useDateRange {
                filters.from = Calendar.current.startOfDay(for: fromDate)
                filters.to = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: toDate))
            }
            records = try await model.repository.history(filters: filters)
        } catch {
            errorMessage = model.message(for: error)
        }
    }
}

private struct HistoryDetailView: View {
    let record: HistoryRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(record.documentName)
                    .font(StudyDesign.headingFont)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                ReadingColumn {
                    VStack(alignment: .leading, spacing: StudyDesign.spacingL) {
                        HStack(spacing: 10) {
                            if let evaluation = record.evaluation {
                                EvaluationBadge(status: evaluation.effectiveStatus)
                            }
                            if let topic = record.topicTitle {
                                Text(topic)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.attempt.createdAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        section("Question") {
                            Text(record.question.text)
                                .font(.body)
                                .textSelection(.enabled)
                        }

                        if let scope = record.scope {
                            section("Focus") {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(scope.displayTitle)
                                        .font(.body)
                                    if !scope.query.isEmpty, scope.query != scope.title {
                                        Text("Your wording: \"\(scope.query)\"")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Scope version \(scope.version) · \(scope.matchedChunkIds.count) passages · \(scope.confirmedByUser ? "confirmed" : "not confirmed")")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        section("Your answer") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.attempt.text)
                                    .font(.body)
                                    .textSelection(.enabled)
                                Label(record.attempt.inputMode == .speech ? "Dictated, then edited before submitting" : "Typed", systemImage: record.attempt.inputMode == .speech ? "mic" : "keyboard")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let transcript = record.attempt.rawTranscript, transcript != record.attempt.text {
                                    Divider()
                                    Text("Original transcript: \(transcript)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }

                        if let evaluation = record.evaluation {
                            section("Assessment") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(evaluation.feedback)
                                        .font(.body)
                                    if let reason = evaluation.notEvaluableReason {
                                        Label(reason, systemImage: "questionmark.circle")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let override = evaluation.userOverride {
                                        Label("You marked this as \(override.status.displayName) on \(override.overriddenAt.formatted(date: .abbreviated, time: .shortened)). The original assessment is preserved.", systemImage: "flag")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Model: \(evaluation.modelId ?? "unknown") · assessed \(evaluation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            if !evaluation.evidenceChunkIds.isEmpty {
                                section("Passages cited") {
                                    Text(evaluation.evidenceChunkIds.map(\.rawValue).joined(separator: ", "))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        section("Expected points") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(record.question.rubric.expectedPoints) { point in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("•")
                                            .foregroundStyle(.secondary)
                                        Text(point.text)
                                            .font(.callout)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 580)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        StudyCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                content()
            }
        }
    }
}
