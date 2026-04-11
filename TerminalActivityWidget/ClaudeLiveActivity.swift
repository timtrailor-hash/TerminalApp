import ActivityKit
import SwiftUI
import WidgetKit

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
                    Text(context.state.headline)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
            } compactTrailing: {
                PhaseCompactTrailingView(state: context.state)
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
                ProgressView().controlSize(.mini).tint(.green)
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
            Text(timerInterval: state.startedAt...Date.distantFuture,
                 countsDown: false)
                .font(.caption.monospacedDigit())
                .foregroundColor(.green)
                .frame(maxWidth: 60)
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
            ProgressView().controlSize(.mini).tint(.green)
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
            Image(systemName: "hourglass").foregroundColor(.green)
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
