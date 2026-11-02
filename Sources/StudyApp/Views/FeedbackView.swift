import SwiftUI
import StudyDomain
import StudyDesignSystem
import StudyEngine

struct FeedbackView: View {
    let feedback: AnswerFeedback
    let hint: Hint?
    let solution: Solution?
    let onNext: () -> Void
    let onTryAgain: () -> Void
    let onHint: (Int) -> Void
    let onShowSolution: () -> Void
    let onViewSource: () -> Void
    let onRetryGrading: () -> Void
    let onOverride: (EvaluationStatus) -> Void

    private var evaluation: Evaluation { feedback.evaluation }
    private var points: [ExpectedPoint] { feedback.question.rubric.expectedPoints }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.spacingL) {
            // Status header
            HStack(spacing: 12) {
                EvaluationBadge(status: evaluation.effectiveStatus)
                if let topic = feedback.topic {
                    Text(topic.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let override = evaluation.userOverride {
                    Label("You marked this as \(override.status.displayName)", systemImage: "flag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Feedback text
            StudyCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Feedback")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(evaluation.feedback)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    
                    if evaluation.effectiveStatus == .notEvaluable, let reason = evaluation.notEvaluableReason {
                        Divider()
                        Label("The app could not verify a verdict: \(reason)", systemImage: "questionmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Expected points
            if !points.isEmpty {
                StudyCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Expected points")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        
                        pointList(title: "Present", ids: evaluation.correctPointIds, symbol: "checkmark.circle.fill", color: .green)
                        pointList(title: "Missing", ids: evaluation.missingPointIds, symbol: "circle.dashed", color: .orange)
                        
                        if !evaluation.incorrectStatements.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Incorrect or unsupported", systemImage: "xmark.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.red)
                                ForEach(evaluation.incorrectStatements, id: \.self) { statement in
                                    Text("\"\(statement)\"")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.leading, 8)
                                }
                            }
                        }
                    }
                }
            }

            // Evidence passages
            if !feedback.evidence.isEmpty {
                StudyCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("From the document")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(feedback.evidence) { chunk in
                            Button {
                                onViewSource()
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "text.quote")
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(chunk.location.shortDescription)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(chunk.text)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.forward.square")
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open source passage, \(chunk.location.shortDescription)")
                        }
                    }
                }
            }

            // Hint
            if let hint {
                StudyCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Hint \(hint.level)", systemImage: "lightbulb")
                            .font(StudyDesign.headingFont)
                            .foregroundStyle(Color.accentColor)
                        Text(hint.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Solution
            if let solution {
                StudyCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Answer from the document", systemImage: "book.closed")
                            .font(StudyDesign.headingFont)
                        ForEach(solution.expectedPoints) { point in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                Text(point.text)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !solution.evidence.isEmpty {
                            Divider()
                            Text(solution.evidence.map(\.text).joined(separator: "\n\n"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                                .textSelection(.enabled)
                        }
                        Label("This is the document's own wording. The app adds no outside material.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Action buttons
            Divider()
            actionButtons
        }
        .padding(.vertical, 4)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if evaluation.effectiveStatus == .notEvaluable {
                Button("Retry grading") { onRetryGrading() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Try again") { onTryAgain() }
                .buttonStyle(.bordered)
                .disabled(evaluation.effectiveStatus == .correct)
            Button("Show answer") { onShowSolution() }
                .buttonStyle(.bordered)
                .disabled(solution != nil)
            if hint == nil {
                Button("Hint") { onHint(1) }
                    .buttonStyle(.bordered)
            } else if hint?.level == 1 {
                Button("More detail") { onHint(2) }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Menu {
                ForEach(EvaluationStatus.allCases, id: \.self) { status in
                    Button("Mark as \(status.displayName)") { onOverride(status) }
                }
            } label: {
                Label("Flag", systemImage: "flag")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Flag this assessment as incorrect")
            Button("Next question") { onNext() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private func pointList(title: String, ids: [String], symbol: String, color: Color) -> some View {
        let items = points.filter { ids.contains($0.id) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                ForEach(items) { point in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(point.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
