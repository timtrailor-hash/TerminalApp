import ActivityKit
import Foundation

public struct ClaudeActivityAttributes: ActivityAttributes {
    public typealias ContentState = ClaudeActivityState

    public struct ClaudeActivityState: Codable, Hashable {
        public enum Phase: String, Codable, Hashable {
            case thinking
            case finished
            case error
        }

        public var phase: Phase
        public var headline: String
        public var body: String
        public var startedAt: Date
        public var elapsedSeconds: Int

        public init(phase: Phase,
                    headline: String,
                    body: String,
                    startedAt: Date,
                    elapsedSeconds: Int = 0) {
            self.phase = phase
            self.headline = headline
            self.body = body
            self.startedAt = startedAt
            self.elapsedSeconds = elapsedSeconds
        }
    }

    public var sessionLabel: String

    public init(sessionLabel: String) {
        self.sessionLabel = sessionLabel
    }
}
