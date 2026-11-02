import Foundation

/// One evaluable attempt on a topic, newest information for the review algorithm.
public struct TopicAttempt: Hashable, Sendable {
    public var topicId: TopicID
    public var questionId: QuestionID
    public var sessionId: SessionID
    public var status: EvaluationStatus
    public var createdAt: Date

    public init(topicId: TopicID, questionId: QuestionID, sessionId: SessionID, status: EvaluationStatus, createdAt: Date) {
        self.topicId = topicId
        self.questionId = questionId
        self.sessionId = sessionId
        self.status = status
        self.createdAt = createdAt
    }
}

/// Explicit, testable parameters for the review algorithm.
///
/// These are heuristics, not a scientific measure of knowledge. They only ever
/// influence which supported topic is asked next; they never invent material.
public struct ReviewPolicy: Sendable, Hashable, Codable {
    /// Only the most recent evaluable attempts count.
    public var windowSize: Int
    /// Each older attempt counts this much relative to the one after it (0 < w <= 1).
    public var recencyDecay: Double
    /// A topic at or below this score is weak even with a good latest attempt.
    public var weakThreshold: Double
    /// A topic at or above this score, with enough consecutive correct answers, is consolidated.
    public var consolidatedThreshold: Double
    /// Consecutive correct answers required before a topic can be called consolidated.
    public var consolidatedConsecutiveCorrect: Int
    /// A topic is never considered mastered without at least this many attempts.
    public var minimumAttemptsForConsolidated: Int

    public init(
        windowSize: Int = 5,
        recencyDecay: Double = 0.75,
        weakThreshold: Double = 0.4,
        consolidatedThreshold: Double = 0.85,
        consolidatedConsecutiveCorrect: Int = 2,
        minimumAttemptsForConsolidated: Int = 2
    ) {
        self.windowSize = windowSize
        self.recencyDecay = recencyDecay
        self.weakThreshold = weakThreshold
        self.consolidatedThreshold = consolidatedThreshold
        self.consolidatedConsecutiveCorrect = consolidatedConsecutiveCorrect
        self.minimumAttemptsForConsolidated = minimumAttemptsForConsolidated
    }

    public static let `default` = ReviewPolicy()
}

public enum TopicMastery: String, Codable, Sendable, CaseIterable {
    /// No evaluable attempts yet. Not a judgement of knowledge.
    case unassessed
    case weak
    case needsReinforcement
    case consolidated

    public var displayName: String {
        switch self {
        case .unassessed: return "Not assessed"
        case .weak: return "Needs work"
        case .needsReinforcement: return "Needs reinforcement"
        case .consolidated: return "Consolidated"
        }
    }
}

public struct TopicPerformance: Hashable, Sendable {
    public var topic: Topic
    public var attemptsUsed: [TopicAttempt]
    public var score: Double?
    public var mastery: TopicMastery
    public var latestStatus: EvaluationStatus?

    public init(topic: Topic, attemptsUsed: [TopicAttempt], score: Double?, mastery: TopicMastery, latestStatus: EvaluationStatus?) {
        self.topic = topic
        self.attemptsUsed = attemptsUsed
        self.score = score
        self.mastery = mastery
        self.latestStatus = latestStatus
    }
}

public enum ReviewScoring {
    /// Weighted score over the most recent evaluable attempts, in [0, 1].
    /// `attempts` may be in any order; newest is chosen by `createdAt` (ties broken by input order).
    public static func score(attempts: [TopicAttempt], policy: ReviewPolicy = .default) -> Double? {
        let evaluable = attempts
            .enumerated()
            .filter { $0.element.status.isEvaluable }
            .sorted { lhs, rhs in
                if lhs.element.createdAt == rhs.element.createdAt {
                    return lhs.offset > rhs.offset
                }
                return lhs.element.createdAt > rhs.element.createdAt
            }
            .prefix(max(0, policy.windowSize))
            .map(\.element)

        guard !evaluable.isEmpty else { return nil }

        var weightedSum = 0.0
        var weightTotal = 0.0
        for (index, attempt) in evaluable.enumerated() {
            let weight = pow(max(0.0001, min(1.0, policy.recencyDecay)), Double(index))
            let value = Double(attempt.status.reviewScore ?? 0) / 2.0
            weightedSum += value * weight
            weightTotal += weight
        }
        guard weightTotal > 0 else { return nil }
        return weightedSum / weightTotal
    }

    public static func performance(
        for topic: Topic,
        attempts: [TopicAttempt],
        policy: ReviewPolicy = .default
    ) -> TopicPerformance {
        let evaluable = attempts
            .filter { $0.status.isEvaluable }
            .sorted { $0.createdAt > $1.createdAt }
        let window = Array(evaluable.prefix(max(0, policy.windowSize)))
        let latest = window.first?.status
        let value = score(attempts: attempts, policy: policy)

        let mastery: TopicMastery
        if value == nil {
            mastery = .unassessed
        } else if latest == .incorrect || (value ?? 0) < policy.weakThreshold {
            mastery = .weak
        } else {
            var consecutive = 0
            for attempt in window {
                if attempt.status == .correct { consecutive += 1 } else { break }
            }
            if (value ?? 0) >= policy.consolidatedThreshold,
               window.count >= policy.minimumAttemptsForConsolidated,
               consecutive >= policy.consolidatedConsecutiveCorrect {
                mastery = .consolidated
            } else {
                mastery = .needsReinforcement
            }
        }

        return TopicPerformance(
            topic: topic,
            attemptsUsed: window,
            score: value,
            mastery: mastery,
            latestStatus: latest
        )
    }

    /// Topics to prioritize in review mode: weak first, then needs reinforcement.
    /// Unassessed topics are never called "weak" and are handled by full study.
    public static func reviewPriority(_ a: TopicPerformance, _ b: TopicPerformance) -> Bool {
        func rank(_ mastery: TopicMastery) -> Int {
            switch mastery {
            case .weak: return 0
            case .needsReinforcement: return 1
            case .unassessed: return 2
            case .consolidated: return 3
            }
        }
        if rank(a.mastery) != rank(b.mastery) {
            return rank(a.mastery) < rank(b.mastery)
        }
        let aScore = a.score ?? 1
        let bScore = b.score ?? 1
        if aScore != bScore { return aScore < bScore }
        return a.topic.order < b.topic.order
    }
}

// MARK: - Session summary

public struct SessionSummary: Hashable, Sendable {
    public var answeredQuestions: Int
    public var statusCounts: [EvaluationStatus: Int]
    public var weakTopics: [TopicPerformance]

    public init(answeredQuestions: Int, statusCounts: [EvaluationStatus: Int], weakTopics: [TopicPerformance]) {
        self.answeredQuestions = answeredQuestions
        self.statusCounts = statusCounts
        self.weakTopics = weakTopics
    }

    public var topicsNeedingReview: [TopicPerformance] {
        weakTopics.filter { $0.mastery == .weak || $0.mastery == .needsReinforcement }
    }
}
