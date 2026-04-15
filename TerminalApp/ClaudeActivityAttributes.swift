import ActivityKit
import Foundation

public struct ClaudeActivityAttributes: ActivityAttributes {
    public typealias ContentState = ClaudeActivityState

    public struct PromptOption: Codable, Hashable, Identifiable {
        public let number: Int
        public let label: String
        public var id: Int { number }

        public init(number: Int, label: String) {
            self.number = number
            self.label = label
        }
    }

    public struct ClaudeActivityState: Codable, Hashable {
        public enum Phase: String, Codable, Hashable {
            case thinking
            case finished
            case error
        }

        public var phase: Phase
        public var headline: String
        public var body: String
        /// Real task start — used by the ever-ticking Text(timerInterval:) counter.
        public var startedAt: Date
        /// Start of the current 60-second "arc cycle". Server pushes a fresh
        /// value every ~55s so the ProgressView(timerInterval:) has a new
        /// interval to animate across (iOS won't fire a pure TimelineView
        /// .periodic re-render often enough in a Live Activity to loop
        /// without help). Decoded as equal to startedAt if absent (back-compat).
        public var arcStartedAt: Date
        public var elapsedSeconds: Int
        /// Numbered choices from a Claude Code permission prompt. Populated
        /// when the server detects an active prompt in the pane and cleared
        /// when the prompt is dismissed. Rendered as Live-Activity buttons
        /// that fire PromptChoiceIntent so the user can answer from the
        /// lock screen without unlocking.
        public var options: [PromptOption]
        /// Base URL the PromptChoiceIntent should POST /internal/prompt-choice
        /// against. Lives on the state so the widget extension doesn't need
        /// its own network-config plumbing.
        public var serverBaseURL: String

        public init(phase: Phase,
                    headline: String,
                    body: String,
                    startedAt: Date,
                    arcStartedAt: Date? = nil,
                    elapsedSeconds: Int = 0,
                    options: [PromptOption] = [],
                    serverBaseURL: String = "") {
            self.phase = phase
            self.headline = headline
            self.body = body
            self.startedAt = startedAt
            self.arcStartedAt = arcStartedAt ?? startedAt
            self.elapsedSeconds = elapsedSeconds
            self.options = options
            self.serverBaseURL = serverBaseURL
        }

        private enum CodingKeys: String, CodingKey {
            case phase, headline, body, startedAt, arcStartedAt, elapsedSeconds
            case options, serverBaseURL
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.phase = try c.decode(Phase.self, forKey: .phase)
            self.headline = try c.decode(String.self, forKey: .headline)
            self.body = try c.decode(String.self, forKey: .body)
            self.startedAt = try c.decode(Date.self, forKey: .startedAt)
            self.arcStartedAt = (try? c.decode(Date.self, forKey: .arcStartedAt)) ?? self.startedAt
            self.elapsedSeconds = (try? c.decode(Int.self, forKey: .elapsedSeconds)) ?? 0
            self.options = (try? c.decode([PromptOption].self, forKey: .options)) ?? []
            self.serverBaseURL = (try? c.decode(String.self, forKey: .serverBaseURL)) ?? ""
        }
    }

    public var sessionLabel: String

    public init(sessionLabel: String) {
        self.sessionLabel = sessionLabel
    }
}
