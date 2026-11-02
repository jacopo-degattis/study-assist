import SwiftUI
import StudyDomain
import StudyDesignSystem

/// Free-text topic selection that resolves to real passages in the imported
/// document, with a preview the student confirms before studying.
struct ScopePickerView: View {
    @EnvironmentObject private var model: AppModel
    let snapshotId: SnapshotID
    var showsModePicker: Bool = true
    var confirmTitle: String = "Start with this focus"
    var onCancel: (() -> Void)?
    let onConfirm: (StudyScope, SessionMode) -> Void

    @State private var query = ""
    @State private var resolution: ScopeResolution?
    @State private var selectedChunkIds: Set<ChunkID> = []
    @State private var suggestions: [ScopeSuggestion] = []
    @State private var mode: SessionMode = .fullStudy
    @State private var isResolving = false
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var weakCount: Int?
    @State private var hasLoadedSuggestions = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.spacingL) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What do you want to study?")
                    .font(StudyDesign.headingFont)
                Text("Leave this empty for the entire document. The app searches only this file and shows you what it matched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("For example: action potentials, chapter 3, sodium channels", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { find() }
                Button("Find") { find() }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
                if isResolving {
                    ProgressView().controlSize(.small)
                }
            }

            if !suggestions.isEmpty, resolution == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From this document")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowRow(spacing: 8) {
                        ForEach(suggestions) { suggestion in
                            Button(suggestion.title) {
                                query = suggestion.title
                                find()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            if let resolution {
                resolutionView(resolution)
            }

            if showsModePicker {
                Picker("Session", selection: $mode) {
                    Text("Full study").tag(SessionMode.fullStudy)
                    Text("Review weak areas").tag(SessionMode.review)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                if mode == .review {
                    if let weakCount, weakCount == 0 {
                        Label("There is not enough history inside this focus for a review yet. Full study will build it.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Label("Review uses the topics you answered least well inside the selected focus.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                }
                Button {
                    confirm(scopeChunkIds: selectedIds)
                } label: {
                    Text(confirmTitle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConfirm)
                .keyboardShortcut(.return, modifiers: .command)

                Button("Entire document") {
                    confirm(scopeChunkIds: nil)
                }
                .buttonStyle(.bordered)
                .disabled(isConfirming)
            }
        }
        .task {
            guard !hasLoadedSuggestions else { return }
            hasLoadedSuggestions = true
            suggestions = (try? await model.engine.scopeSuggestions(snapshotId: snapshotId)) ?? []
            await refreshWeakCount()
        }
        .onChange(of: selectedChunkIds) { _, _ in
            Task { await refreshWeakCount() }
        }
        .onChange(of: mode) { _, _ in
            Task { await refreshWeakCount() }
        }
    }

    @ViewBuilder
    private func resolutionView(_ resolution: ScopeResolution) -> some View {
        switch resolution.state {
        case .notFound:
            StudyCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label(ScopeResolution.notFoundMessage, systemImage: "magnifyingglass")
                        .font(StudyDesign.headingFont)
                        .foregroundStyle(.orange)
                    Text("Try different wording, choose a suggestion, or study the entire document. The app will not answer from general knowledge or widen the scope silently.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .fullDocument:
            StudyCard {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Entire document", systemImage: "doc.text")
                        .font(StudyDesign.headingFont)
                    Text("Every reliable passage in this document will be in scope.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .found, .ambiguous:
            StudyCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(resolution.state == .ambiguous ? "Check the matched passages" : "Matched in this document")
                            .font(StudyDesign.headingFont)
                        Spacer()
                        Text("\(selectedChunkIds.count) of \(resolution.matches.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message = resolution.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(resolution.matches) { match in
                                Toggle(isOn: Binding(
                                    get: { selectedChunkIds.contains(match.chunkId) },
                                    set: { isOn in
                                        if isOn { selectedChunkIds.insert(match.chunkId) } else { selectedChunkIds.remove(match.chunkId) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(match.sectionTitle)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                            Text(match.location.shortDescription)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(match.excerpt)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .accessibilityLabel("Include \(match.sectionTitle), \(match.location.shortDescription)")
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
    }

    private var canConfirm: Bool {
        guard !isConfirming, let resolution else { return false }
        if showsModePicker, mode == .review, weakCount == 0 { return false }
        switch resolution.state {
        case .notFound: return false
        case .fullDocument: return true
        case .found, .ambiguous: return !selectedChunkIds.isEmpty
        }
    }

    private var selectedIds: [ChunkID] {
        guard let resolution else { return [] }
        return resolution.matches.map(\.chunkId).filter { selectedChunkIds.contains($0) }
    }

    private func find() {
        errorMessage = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resolution = nil
            selectedChunkIds = []
            return
        }
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                let result = try await model.engine.resolveScope(query: trimmed, snapshotId: snapshotId)
                resolution = result
                selectedChunkIds = Set(result.suggestedChunkIds)
                if result.state == .notFound {
                    selectedChunkIds = []
                }
                await refreshWeakCount()
            } catch {
                errorMessage = model.message(for: error)
            }
        }
    }

    private func confirm(scopeChunkIds: [ChunkID]?) {
        errorMessage = nil
        isConfirming = true
        Task {
            defer { isConfirming = false }
            do {
                let scope: StudyScope
                if let scopeChunkIds {
                    guard !scopeChunkIds.isEmpty else {
                        errorMessage = "Select at least one passage, or choose the entire document."
                        return
                    }
                    let title = resolution?.sectionTitles.first ?? query
                    scope = try await model.engine.confirmScope(
                        query: query,
                        snapshotId: snapshotId,
                        chunkIds: scopeChunkIds,
                        title: title
                    )
                } else {
                    scope = try await model.engine.fullDocumentScope(snapshotId: snapshotId)
                }
                onConfirm(scope, mode)
            } catch {
                errorMessage = model.message(for: error)
            }
        }
    }

    private func refreshWeakCount() async {
        let scope: StudyScope?
        if let resolution, resolution.state == .found || resolution.state == .ambiguous, !selectedIds.isEmpty {
            scope = StudyScope(
                snapshotId: snapshotId,
                query: query,
                title: resolution.sectionTitles.first ?? query,
                matchedChunkIds: selectedIds,
                isFullDocument: false,
                version: 0,
                confirmedByUser: false
            )
        } else {
            scope = nil
        }
        do {
            let weak = try await model.engine.weakTopics(snapshotId: snapshotId, scope: scope)
            weakCount = weak.count
        } catch {
            weakCount = nil
        }
    }
}

/// Small wrapping row used for suggestion chips.
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 8
    let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                content
            }
        }
    }
}
