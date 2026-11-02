import SwiftUI
import StudyDomain

/// Professional design system for StudyApp.
/// Uses semantic colors, clear hierarchy, and native macOS patterns.
public enum StudyDesign {
    public static let readingColumnWidth: CGFloat = 820
    public static let cardCornerRadius: CGFloat = 12
    public static let contentSpacing: CGFloat = 20
    
    // Spacing scale
    public static let spacingXS: CGFloat = 4
    public static let spacingS: CGFloat = 8
    public static let spacingM: CGFloat = 12
    public static let spacingL: CGFloat = 16
    public static let spacingXL: CGFloat = 24
    public static let spacingXXL: CGFloat = 32
    
    // Typography
    public static let titleFont = Font.system(size: 28, weight: .semibold)
    public static let sectionTitleFont = Font.system(size: 20, weight: .semibold)
    public static let headingFont = Font.system(size: 17, weight: .semibold)
    public static let bodyFont = Font.system(size: 15)
    public static let captionFont = Font.system(size: 13)
    public static let smallCaptionFont = Font.system(size: 11)
}

/// Centered reading column with proper margins
public struct ReadingColumn<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 32)
            content
                .frame(maxWidth: StudyDesign.readingColumnWidth, alignment: .leading)
            Spacer(minLength: 32)
        }
    }
}

/// Elevated card with subtle shadow and border
public struct StudyCard<Content: View>: View {
    private let content: Content
    private var background: Color = Color.secondary.opacity(0.08)
    private var borderWidth: CGFloat = 1

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    public init(background: Color, @ViewBuilder content: () -> Content) {
        self.background = background
        self.content = content()
    }

    public var body: some View {
        content
            .padding(StudyDesign.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: StudyDesign.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.cardCornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: borderWidth)
            )
            .shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
    }
}

/// Status badge with icon and color
public struct StatusBadge: View {
    public let title: String
    public let systemImage: String
    public let color: Color

    public init(title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)")
    }
}

/// Outcome badge for evaluation results
public struct EvaluationBadge: View {
    public let status: EvaluationStatus

    public init(status: EvaluationStatus) {
        self.status = status
    }

    public var body: some View {
        StatusBadge(
            title: status.displayName,
            systemImage: symbol,
            color: color
        )
    }

    private var symbol: String {
        switch status {
        case .correct: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .incorrect: return "xmark.circle.fill"
        case .notEvaluable: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch status {
        case .correct: return .green
        case .partial: return .orange
        case .incorrect: return .red
        case .notEvaluable: return .gray
        }
    }
}

/// Mastery level badge
public struct MasteryBadge: View {
    public let mastery: TopicMastery

    public init(mastery: TopicMastery) {
        self.mastery = mastery
    }

    public var body: some View {
        StatusBadge(
            title: mastery.displayName,
            systemImage: icon,
            color: mastery == .weak ? .orange : mastery == .consolidated ? .green : .secondary
        )
    }
    
    private var icon: String {
        switch mastery {
        case .weak: return "arrow.down.right"
        case .needsReinforcement: return "arrow.triangle.2.circlepath"
        case .consolidated: return "checkmark.seal"
        case .unassessed: return "circle"
        }
    }
}

/// Prominent error banner with icon and retry
public struct ErrorBanner: View {
    public let message: String
    public var retry: (() -> Void)?

    public init(message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Something went wrong")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Helpful empty state with icon and guidance
public struct EmptyStateView: View {
    public let symbol: String
    public let title: String
    public let message: String

    public init(symbol: String, title: String, message: String) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(40)
    }
}

/// Progress indicator with label
public struct BusyLabel: View {
    public let text: String
    public var progress: Double?

    public init(text: String, progress: Double? = nil) {
        self.text = text
        self.progress = progress
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// Keyboard shortcut hint
public struct KeyboardHint: View {
    public let keys: String
    public let label: String

    public init(keys: String, label: String) {
        self.keys = keys
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Metric display for statistics
public struct MetricView: View {
    public let label: String
    public let value: String
    public var color: Color = .primary

    public init(label: String, value: String, color: Color = .primary) {
        self.label = label
        self.value = value
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Section header with optional subtitle
public struct SectionHeader: View {
    public let title: String
    public var subtitle: String?

    public init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(StudyDesign.sectionTitleFont)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
