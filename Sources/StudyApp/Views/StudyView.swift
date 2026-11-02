import SwiftUI
import StudyDomain
import StudyDesignSystem
import StudyEngine
import StudySpeech

struct StudyView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var viewModel: StudyViewModel
    @FocusState private var editorFocused: Bool
    @State private var showScopePicker = false

    var body: some View {
        ScrollView {
            ReadingColumn {
                VStack(alignment: .leading, spacing: StudyDesign.spacingXL) {
                    focusBar
                    if let message = viewModel.errorMessage {
                        ErrorBanner(message: message) {
                            viewModel.clearError()
                            if viewModel.errorIsRetryable {
                                Task { await viewModel.askNextQuestion() }
                            }
                        }
                    }
                    content
                }
                .padding(.vertical, StudyDesign.spacingXXL)
            }
        }
        .navigationTitle(viewModel.document.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.overview.topicCount > 0 {
                    Text("\(viewModel.overview.answeredCount) of \(viewModel.overview.topicCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                Button {
                    Task { await viewModel.finishSession() }
                } label: {
                    Label("End", systemImage: "stop.circle")
                }
                .disabled(viewModel.state == .completed)
                .help("Finish this session and show a summary")
                Button {
                    Task { await model.endStudy() }
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                }
                .help("Return to the document library")
            }
        }
        .onChange(of: viewModel.state) { _, newState in
            announce(for: newState)
        }
        .sheet(isPresented: $showScopePicker) {
            ScopePickerSheet(
                snapshotId: viewModel.session.snapshotId,
                onCancel: { showScopePicker = false }
            ) { scope in
                showScopePicker = false
                Task { await viewModel.changeScope(scope) }
            }
        }
        .sheet(item: $viewModel.sourceViewerTarget) { target in
            SourceViewerView(
                document: viewModel.document,
                target: target,
                evidence: viewModel.feedback?.evidence ?? viewModel.prepared?.evidence ?? [],
                storedFileURL: model.fileStore.url(forStoredFileName: viewModel.document.storedFileName)
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .preparingQuestion:
            busyView(text: viewModel.busyPhase ?? "Preparing a question from the document")
        case .evaluating:
            busyView(text: viewModel.busyPhase ?? "Checking your answer against the document")
        case .awaitingAnswer, .recording, .transcribing:
            questionView
        case .showingFeedback:
            if let feedback = viewModel.feedback {
                FeedbackView(
                    feedback: feedback,
                    hint: viewModel.hint,
                    solution: viewModel.solution,
                    onNext: { Task { await viewModel.askNextQuestion() } },
                    onTryAgain: { viewModel.tryAgain() },
                    onHint: { level in Task { await viewModel.requestHint(level: level) } },
                    onShowSolution: { Task { await viewModel.showSolution() } },
                    onViewSource: { viewModel.openSource(for: feedback) },
                    onRetryGrading: { Task { await viewModel.retryEvaluation() } },
                    onOverride: { status in Task { await viewModel.overrideEvaluation(status: status) } }
                )
            } else {
                ProgressView()
                    .padding(.vertical, 40)
            }
        case .completed:
            summaryView
        case .failed:
            failedView
        case .empty, .ready, .importing:
            busyView(text: "Starting the session")
        }
    }

    private var focusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 14, weight: .medium))
            Text(viewModel.focusLabel)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if viewModel.currentScope?.isFullDocument == false {
                if let query = viewModel.currentScope?.query, !query.isEmpty, query != viewModel.currentScope?.title {
                    Text("· \(query)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Change") { showScopePicker = true }
                .buttonStyle(.borderless)
                .font(.caption)
            if viewModel.currentScope?.isFullDocument == false {
                Button("All") {
                    Task { await viewModel.changeToEntireDocument() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Study focus: \(viewModel.focusLabel)")
    }

    private var questionView: some View {
        VStack(alignment: .leading, spacing: StudyDesign.spacingL) {
            if let prepared = viewModel.prepared {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Topic")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(prepared.topic.title)
                        .font(StudyDesign.headingFont)
                        .foregroundStyle(.primary)
                    Divider()
                    Text(prepared.question.text)
                        .font(.system(size: 20, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                }

                answerEditor

                HStack(spacing: 12) {
                    recordButton
                    if viewModel.state == .recording || viewModel.state == .transcribing {
                        RecordingStatusView(recorder: viewModel.recorder, isTranscribing: viewModel.state == .transcribing, phase: viewModel.transcriptionPhase)
                    }
                    Spacer()
                    KeyboardHint(keys: "⌘↩", label: "Submit")
                    Button {
                        Task { await viewModel.submitAnswer() }
                    } label: {
                        Text("Submit")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!viewModel.canSubmit)
                }

                if viewModel.inputMode == .speech, viewModel.rawTranscript != nil {
                    Label("Transcribed on this Mac. Edit if needed before submitting.", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Label("Your answer is checked against the document only.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                BusyLabel(text: "Preparing a question")
                    .padding(.vertical, 40)
            }
        }
        .onExitCommand {
            if viewModel.state == .recording {
                viewModel.cancelRecording()
            }
        }
    }

    private var answerEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { viewModel.draft },
                set: { viewModel.draftChanged($0) }
            ))
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .padding(12)
            .frame(minHeight: 160, maxHeight: 320)
            .focused($editorFocused)
            .disabled(viewModel.state != .awaitingAnswer)
            .accessibilityLabel("Your answer")

            if viewModel.draft.isEmpty {
                Text("Type your answer here…")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        )
    }

    private var recordButton: some View {
        Button {
            if viewModel.state == .recording {
                Task { await viewModel.stopRecordingAndTranscribe() }
            } else if viewModel.state == .awaitingAnswer {
                Task { await viewModel.startRecording() }
            }
        } label: {
            Image(systemName: viewModel.state == .recording ? "stop.circle.fill" : "mic")
                .font(.system(size: 18))
                .foregroundStyle(viewModel.state == .recording ? Color.red : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.state == .transcribing)
        .keyboardShortcut("r", modifiers: .command)
        .help(viewModel.state == .recording ? "Stop recording (⌘R)" : "Record an answer (⌘R)")
        .accessibilityLabel(viewModel.state == .recording ? "Stop recording" : "Record answer with the microphone")
    }

    private func busyView(text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BusyLabel(text: text)
            Text("This step uses only the passages from this document.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 60)
    }

    private var failedView: some View {
        StudyCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("That step could not be completed", systemImage: "exclamationmark.triangle")
                    .font(StudyDesign.headingFont)
                    .foregroundStyle(.orange)
                Text(viewModel.errorMessage ?? "The operation failed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Try again") { Task { await viewModel.askNextQuestion() } }
                        .buttonStyle(.borderedProminent)
                    Button("End session") { Task { await viewModel.finishSession() } }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: StudyDesign.spacingL) {
            SectionHeader(title: "Session complete")
            
            if let summary = viewModel.summary {
                StudyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 24) {
                            MetricView(label: "Answered", value: "\(summary.answeredQuestions)")
                            MetricView(label: "Correct", value: "\(summary.statusCounts[.correct] ?? 0)", color: .green)
                            MetricView(label: "Partial", value: "\(summary.statusCounts[.partial] ?? 0)", color: .orange)
                            MetricView(label: "Incorrect", value: "\(summary.statusCounts[.incorrect] ?? 0)", color: .red)
                            MetricView(label: "Not evaluable", value: "\(summary.statusCounts[.notEvaluable] ?? 0)", color: .gray)
                        }
                        
                        if summary.topicsNeedingReview.isEmpty {
                            Label("All topics are well covered. Continue with full study to cover more material.", systemImage: "checkmark.seal")
                                .font(.callout)
                                .foregroundStyle(.green)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Topics to revisit")
                                    .font(StudyDesign.headingFont)
                                ForEach(summary.topicsNeedingReview, id: \.topic.id) { performance in
                                    HStack(spacing: 10) {
                                        Text(performance.topic.title)
                                            .font(.callout)
                                            .lineLimit(1)
                                        Spacer()
                                        MasteryBadge(mastery: performance.mastery)
                                    }
                                }
                            }
                        }
                    }
                }
                
                HStack(spacing: 12) {
                    Button("Back to documents") { Task { await model.endStudy() } }
                        .buttonStyle(.borderedProminent)
                    if viewModel.summary?.topicsNeedingReview.isEmpty == false {
                        Button("Review weak areas") {
                            Task {
                                let scopeId = viewModel.currentScope?.id
                                await model.endStudy()
                                await model.startStudy(mode: .review, scopeId: scopeId)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Text("\(viewModel.overview.answeredCount) answers recorded in this session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            Label("History keeps each answer with its document version, rubric and assessment.", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func announce(for state: StudyState) {
        switch state {
        case .showingFeedback:
            let status = viewModel.feedback?.evaluation.effectiveStatus.displayName ?? "Assessment ready"
            AccessibilityNotification.Announcement("\(status). Feedback is ready.").post()
        case .awaitingAnswer:
            if viewModel.inputMode == .speech {
                AccessibilityNotification.Announcement("Transcript ready. Edit it if needed, then submit.").post()
            }
        case .failed:
            AccessibilityNotification.Announcement("The step failed. \(viewModel.errorMessage ?? "")").post()
        default:
            break
        }
    }
}

private struct ScopePickerSheet: View {
    let snapshotId: SnapshotID
    let onCancel: () -> Void
    let onConfirm: (StudyScope) -> Void
    
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScopePickerView(
            snapshotId: snapshotId,
            showsModePicker: false,
            confirmTitle: "Use this focus",
            onCancel: { dismiss() }
        ) { scope, _ in
            onConfirm(scope)
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 480)
    }
}

private struct RecordingStatusView: View {
    @ObservedObject var recorder: AudioRecorder
    let isTranscribing: Bool
    let phase: String?

    var body: some View {
        HStack(spacing: 10) {
            if isTranscribing {
                ProgressView().controlSize(.small)
                Text(phase ?? "Transcribing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(timeString(recorder.elapsed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Press Esc to cancel")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
