import Foundation
import Combine
import TimSharedKit

/// Polls /metrics/activity on the conv server and exposes a compact
/// summary the persistent banner renders.
///
/// The banner only needs three things:
///   - active autonomous task count
///   - pill colour (green / blue / red)
///   - a tap target (the tasks themselves, for the optional sheet)
///
/// Anything richer (per-task drill-in, queued list, kill switch
/// breakdown) lives in ClaudeControl.
@MainActor
final class AutonomousMonitor: ObservableObject {
    struct ActiveTask: Identifiable, Equatable {
        let id: String
        let task: String
        let elapsedSec: Double
        let pid: Int?
    }

    enum Pill: String {
        case green   // N = 0, no errors
        case blue    // N > 0, no errors
        case red     // any failure signal
    }

    @Published private(set) var activeCount: Int = 0
    @Published private(set) var activeTasks: [ActiveTask] = []
    @Published private(set) var pill: Pill = .green
    @Published private(set) var lastError: String?

    private var pollTimer: Timer?
    private let serverProvider: () -> (baseURL: String, authToken: String)
    private let session: URLSession

    init(serverProvider: @escaping () -> (baseURL: String, authToken: String),
         session: URLSession = .shared) {
        self.serverProvider = serverProvider
        self.session = session
    }

    func start() {
        stop()
        pollNow()
        let timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollNow() }
        }
        timer.tolerance = 5.0
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func pollNow() {
        let s = serverProvider()
        guard let url = URL(string: "\(s.baseURL)/metrics/activity") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !s.authToken.isEmpty {
            request.setValue("Bearer \(s.authToken)", forHTTPHeaderField: "Authorization")
        }
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            Task { @MainActor in
                if let error = error {
                    self.lastError = error.localizedDescription
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data else {
                    self.lastError = "HTTP error"
                    return
                }
                self.decode(data)
            }
        }
        task.resume()
    }

    private func decode(_ data: Data) {
        struct Response: Decodable {
            struct Active: Decodable {
                let id: String
                let task: String?
                let elapsed_sec: Double?
                let pid: Int?
                let status: String?
            }
            struct KillSwitch: Decodable {
                let master: Bool?
                let autonomous: Bool?
            }
            let active_sessions: [Active]?
            let doorman_error: String?
            let autonomous_loops_error: String?
            let kill_switch: KillSwitch?
        }
        do {
            let parsed = try JSONDecoder().decode(Response.self, from: data)
            let sessions = parsed.active_sessions ?? []
            self.activeCount = sessions.count
            self.activeTasks = sessions.map {
                ActiveTask(
                    id: $0.id,
                    task: $0.task ?? "",
                    elapsedSec: $0.elapsed_sec ?? 0,
                    pid: $0.pid
                )
            }
            let killAuto = parsed.kill_switch?.autonomous ?? false
            let killMaster = parsed.kill_switch?.master ?? false
            let hasErr = parsed.doorman_error != nil || parsed.autonomous_loops_error != nil
            if killAuto || killMaster || hasErr {
                self.pill = .red
            } else if sessions.isEmpty {
                self.pill = .green
            } else {
                self.pill = .blue
            }
            self.lastError = nil
        } catch {
            self.lastError = "decode: \(error.localizedDescription)"
        }
    }
}
