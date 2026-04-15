import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

@available(iOS 17.2, *)
struct PromptChoiceIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer Claude Prompt"
    static var description: IntentDescription? = IntentDescription(
        "Sends a numbered choice to an active Claude Code permission prompt."
    )

    @Parameter(title: "Session Label")
    var sessionLabel: String

    @Parameter(title: "Option Number")
    var number: Int

    @Parameter(title: "Server Base URL")
    var serverBaseURL: String

    init() {
        self.sessionLabel = ""
        self.number = 0
        self.serverBaseURL = ""
    }

    init(sessionLabel: String, number: Int, serverBaseURL: String) {
        self.sessionLabel = sessionLabel
        self.number = number
        self.serverBaseURL = serverBaseURL
    }

    func perform() async throws -> some IntentResult {
        guard !serverBaseURL.isEmpty,
              let url = URL(string: "\(serverBaseURL)/internal/prompt-choice") else {
            return .result()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "session_label": sessionLabel,
            "number": number,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
        return .result()
    }
}


@available(iOS 17.2, *)
private struct PromptOptionButtons: View {
    let state: ClaudeActivityAttributes.ContentState
    let attributes: ClaudeActivityAttributes
    let compact: Bool  // compact = inline in dynamic island, else lock-screen

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            ForEach(state.options) { opt in
                Button(intent: PromptChoiceIntent(
                    sessionLabel: attributes.sessionLabel,
                    number: opt.number,
                    serverBaseURL: state.serverBaseURL
                )) {
                    HStack(spacing: 6) {
                        Text("\(opt.number)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundColor(.green)
                        Text(opt.label)
                            .font(.caption)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.green.opacity(0.45), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}


struct ClaudeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeActivityAttributes.self) { context in
            LockScreenView(state: context.state, attributes: context.attributes)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(Color.green)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .foregroundColor(.green)
                        Text("Claude")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PhaseTrailingView(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.headline)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if #available(iOS 17.2, *), !context.state.options.isEmpty {
                            PromptOptionButtons(state: context.state,
                                                attributes: context.attributes,
                                                compact: true)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
            } compactTrailing: {
                HStack(spacing: 3) {
                    if context.state.phase == .thinking {
                        Text(timerInterval: context.state.startedAt...Date.distantFuture,
                             countsDown: false,
                             showsHours: false)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundColor(.green)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 38)
                    }
                    PhaseCompactTrailingView(state: context.state)
                }
            } minimal: {
                PhaseMinimalView(state: context.state)
            }
            .widgetURL(URL(string: "terminalapp://claude"))
            .keylineTint(.green)
        }
    }
}

private struct LockScreenView: View {
    let state: ClaudeActivityAttributes.ContentState
    let attributes: ClaudeActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
                Text("Claude")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                PhaseBadge(phase: state.phase)
                if state.phase == .thinking {
                    Text(timerInterval: state.startedAt...Date.distantFuture,
                         countsDown: false)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: 60, alignment: .trailing)
                } else if state.elapsedSeconds > 0 {
                    Text(formatElapsed(state.elapsedSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            if !state.headline.isEmpty {
                Text(state.headline)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            if !state.body.isEmpty {
                Text(state.body)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
            }
            if #available(iOS 17.2, *), !state.options.isEmpty {
                PromptOptionButtons(state: state, attributes: attributes, compact: false)
                    .padding(.top, 2)
            }
            Text(attributes.sessionLabel.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundColor(.green.opacity(0.8))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PhaseBadge: View {
    let phase: ClaudeActivityAttributes.ContentState.Phase
    var body: some View {
        switch phase {
        case .thinking:
            HStack(spacing: 4) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(.green)
                Text("Working")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.green)
            }
        case .finished:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Done")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.green)
            }
        case .error:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("Error")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.orange)
            }
        }
    }
}

private struct PhaseTrailingView: View {
    let state: ClaudeActivityAttributes.ContentState
    var body: some View {
        switch state.phase {
        case .thinking:
            HStack(spacing: 6) {
                ProgressView(timerInterval: state.arcStartedAt...state.arcStartedAt.addingTimeInterval(60),
                             countsDown: false,
                             label: { EmptyView() },
                             currentValueLabel: { EmptyView() })
                    .progressViewStyle(.circular)
                    .tint(.green)
                Text(timerInterval: state.startedAt...Date.distantFuture,
                     countsDown: false)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.green)
                    .frame(maxWidth: 60)
            }
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        }
    }
}

private struct PhaseCompactTrailingView: View {
    let state: ClaudeActivityAttributes.ContentState
    var body: some View {
        switch state.phase {
        case .thinking:
            // ProgressView(timerInterval:) is one of the few views iOS
            // actually animates inside a Dynamic Island / Live Activity.
            // Use a 5-minute sweep so the arc visibly fills while Claude
            // thinks. If thinking takes longer, the arc stays full — the
            // timer text next to it tells the real story.
            ProgressView(timerInterval: state.arcStartedAt...state.arcStartedAt.addingTimeInterval(60),
                         countsDown: false,
                         label: { EmptyView() },
                         currentValueLabel: { EmptyView() })
                .progressViewStyle(.circular)
                .tint(.green)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }
}

private struct PhaseMinimalView: View {
    let state: ClaudeActivityAttributes.ContentState
    var body: some View {
        switch state.phase {
        case .thinking:
            ProgressView(timerInterval: state.arcStartedAt...state.arcStartedAt.addingTimeInterval(60),
                         countsDown: false,
                         label: { EmptyView() },
                         currentValueLabel: { EmptyView() })
                .progressViewStyle(.circular)
                .tint(.green)
        case .finished:
            Image(systemName: "checkmark").foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark").foregroundColor(.orange)
        }
    }
}

private func formatElapsed(_ seconds: Int) -> String {
    let safe = max(0, seconds)
    let m = safe / 60
    let s = safe % 60
    return String(format: "%d:%02d", m, s)
}
