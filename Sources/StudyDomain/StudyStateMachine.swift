import Foundation

/// The session state machine described in the plan.
///
/// Events are accepted only in compatible states. Duplicate submissions and
/// late responses are ignored rather than corrupting history.
public enum StudyState: String, Codable, Sendable, CaseIterable {
    case empty
    case importing
    case ready
    case preparingQuestion
    case awaitingAnswer
    case recording
    case transcribing
    case evaluating
    case showingFeedback
    case completed
    case failed

    /// States in which the student can type or record an answer.
    public var isAnswering: Bool {
        self == .awaitingAnswer || self == .recording || self == .transcribing
    }

    public var isBusy: Bool {
        switch self {
        case .importing, .preparingQuestion, .evaluating, .transcribing:
            return true
        default:
            return false
        }
    }
}

public enum StudyEvent: Sendable, Equatable {
    case beginImport
    case importFinished
    case importFailed
    case readyForStudy
    case startSession
    case questionRequested
    case questionReceived
    case questionFailed
    case beginRecording
    case recordingCancelled
    case beginTranscription
    case transcriptionFinished
    case transcriptionFailed
    case submitAnswer
    case evaluationFinished
    case evaluationFailed
    case nextQuestionRequested
    case finishSession
    case retry
    case reset
}

public struct StudyStateMachine: Sendable {
    public private(set) var state: StudyState

    public init(state: StudyState = .empty) {
        self.state = state
    }

    /// Returns the new state, or throws when the event is not valid here.
    /// Invalid events must be ignored by the caller (they are not errors to show).
    @discardableResult
    public mutating func apply(_ event: StudyEvent) throws -> StudyState {
        guard let next = Self.nextState(from: state, event: event) else {
            throw AppError.invalidStateTransition("Cannot apply \(event) while \(state.rawValue).")
        }
        state = next
        return next
    }

    public static func nextState(from state: StudyState, event: StudyEvent) -> StudyState? {
        switch (state, event) {
        // Import lifecycle
        case (.empty, .beginImport), (.ready, .beginImport), (.failed, .beginImport):
            return .importing
        case (.importing, .importFinished):
            return .ready
        case (.importing, .importFailed):
            return .failed

        // Session lifecycle
        case (.ready, .startSession):
            return .preparingQuestion
        case (.preparingQuestion, .questionReceived):
            return .awaitingAnswer
        case (.preparingQuestion, .questionFailed):
            return .failed
        case (.showingFeedback, .nextQuestionRequested), (.showingFeedback, .questionRequested):
            return .preparingQuestion
        case (.awaitingAnswer, .questionRequested):
            return .preparingQuestion

        // Recording / transcription are branches of answering
        case (.awaitingAnswer, .beginRecording):
            return .recording
        case (.recording, .recordingCancelled):
            return .awaitingAnswer
        case (.recording, .beginTranscription):
            return .transcribing
        case (.transcribing, .transcriptionFinished):
            return .awaitingAnswer
        case (.transcribing, .transcriptionFailed):
            return .awaitingAnswer
        case (.recording, .submitAnswer):
            // Submitting while recording is ambiguous: stop recording first.
            return nil
        case (.awaitingAnswer, .submitAnswer):
            return .evaluating

        // Evaluation
        case (.evaluating, .evaluationFinished):
            return .showingFeedback
        case (.evaluating, .evaluationFailed):
            return .awaitingAnswer
        case (.evaluating, .submitAnswer):
            // Duplicate submission: ignored.
            return nil

        // Closing
        case (.awaitingAnswer, .finishSession), (.showingFeedback, .finishSession):
            return .completed
        case (.preparingQuestion, .finishSession):
            return .completed
        case (.completed, .startSession):
            return .preparingQuestion

        // Recovery
        case (.failed, .questionRequested):
            return .preparingQuestion
        case (.failed, .retry):
            return .ready
        case (_, .reset):
            return .empty
        case (.ready, .readyForStudy):
            return .ready

        default:
            return nil
        }
    }
}
