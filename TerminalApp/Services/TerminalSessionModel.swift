import Foundation
import SwiftUI
import TimSharedKit
import os

private let sessionLog = Logger(subsystem: "com.timtrailor.terminal", category: "sessionModel")

/// Owns HTTP communication with the conversation server. Phase 1 of the
/// SplitTerminalView decomposition: moves ~100 lines of HTTP boilerplate
/// out of the view. Phase 2 (next PR) will move per-tab state here.
@MainActor
final class TerminalSessionModel: ObservableObject {

    weak var server: ServerConnection?

    private var baseURL: String { server?.baseURL ?? "" }
    private var token: String { server?.authToken ?? "" }

    // MARK: - HTTP helpers

    private func authedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func httpCaptureTmux(window: Int) async -> String? {
        guard let url = URL(string: "\(baseURL)/tmux-capture?window=\(window)&lines=500") else { return nil }
        let request = authedRequest(url: url)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? String else { return nil }
            return content
        } catch {
            sessionLog.error("[capture] network error: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func httpSendText(_ text: String, window: Int) async -> Bool {
        guard let url = URL(string: "\(baseURL)/tmux-send-text") else { return false }
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "window": window])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200...299).contains(status)
        } catch {
            sessionLog.error("[send-text] network error: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func httpSendEnter(window: Int) async -> Bool {
        guard let url = URL(string: "\(baseURL)/tmux-send-enter") else { return false }
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["window": window])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200...299).contains(status)
        } catch {
            sessionLog.error("[send-enter] network error: \(error.localizedDescription)")
            return false
        }
    }

    func httpSendEscape(window: Int) async {
        _ = await httpSendKey("Escape", window: window)
    }

    func httpSendKey(_ key: String, window: Int, promptId: Int = 0) async -> Bool {
        guard let url = URL(string: "\(baseURL)/tmux-send-key") else { return false }
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["window": window, "key": key]
        if promptId > 0 { body["promptId"] = promptId }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 409 {
                    sessionLog.info("[button] tap rejected as stale (promptId=\(promptId))")
                    return false
                }
                return http.statusCode < 400
            }
            return true
        } catch {
            return false
        }
    }

    func httpTmuxResize(cols: Int, rows: Int) async {
        guard let url = URL(string: "\(baseURL)/tmux-resize") else { return }
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "cols": cols,
            "rows": rows,
            "session": "mobile",
        ])
        _ = try? await URLSession.shared.data(for: request)
    }
}
