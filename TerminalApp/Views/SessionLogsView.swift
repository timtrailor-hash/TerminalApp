import SwiftUI
import TimSharedKit

struct SessionLogsView: View {
    @EnvironmentObject var server: ServerConnection
    /// Callback to send a resume command to the SSH terminal.
    /// Passes the full shell command string (e.g. "claude --resume <id>\n").
    var onResume: ((String) -> Void)?
    @State private var sessions: [SessionSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedSession: SessionDetail?
    @State private var isLoadingDetail = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if isLoading && sessions.isEmpty {
                ProgressView("Loading sessions...")
                    .tint(AppTheme.accent)
                    .foregroundColor(AppTheme.dimText)
            } else if let error = errorMessage, sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(AppTheme.dimText)
                        .multilineTextAlignment(.center)
                    Button("Retry") { loadSessions() }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.accent)
                }
                .padding()
            } else {
                List(sessions) { session in
                    HStack {
                        Button {
                            loadSessionDetail(session.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(session.dateFormatted)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(AppTheme.accent)
                                    Spacer()
                                    Text("\(session.messageCount) msgs")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(AppTheme.dimText)
                                }

                                Text(session.firstMessage)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppTheme.bodyText)
                                    .lineLimit(2)

                                if let summary = session.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.system(size: 11))
                                        .foregroundColor(AppTheme.dimText)
                                        .lineLimit(2)
                                }

                                Text(session.sizeFormatted)
                                    .font(.system(size: 10))
                                    .foregroundColor(AppTheme.fadedText)
                            }
                            .padding(.vertical, 4)
                        }

                        if onResume != nil {
                            Button {
                                resumeSession(session.id)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 24))
                                    Text("Resume")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundColor(AppTheme.accent)
                                .frame(width: 56)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(AppTheme.cardBackground)
                }
                .listStyle(.plain)
                .refreshable { loadSessions() }
            }
        }
        .navigationTitle("Session History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.cardBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $selectedSession) { detail in
            NavigationStack {
                SessionDetailView(detail: detail, server: server, onResume: onResume != nil ? { id in
                    resumeSession(id)
                } : nil)
            }
        }
        .overlay {
            if isLoadingDetail {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(AppTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.3))
            }
        }
        .onAppear { loadSessions() }
    }

    private func resumeSession(_ sessionId: String) {
        // Send Ctrl+C to interrupt current Claude, wait briefly, then send resume command.
        // The \u{03} is Ctrl+C (ETX), which exits the current Claude CLI session.
        // Then we cd to the right directory and launch claude --resume.
        let cmd = "\u{03}\u{03}"  // Double Ctrl+C to ensure clean exit
            + "sleep 0.5 && cd ~/Documents/Claude\\ code && claude --resume \(sessionId)\n"
        onResume?(cmd)
        dismiss()
    }

    private func loadSessions() {
        isLoading = true
        errorMessage = nil

        Task {
            guard var request = server.request(path: "/session-logs") else {
                errorMessage = "Invalid server URL"
                isLoading = false
                return
            }
            request.timeoutInterval = 10

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let response = try JSONDecoder().decode(SessionListResponse.self, from: data)
                sessions = response.sessions
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func loadSessionDetail(_ id: String) {
        isLoadingDetail = true

        Task {
            guard var request = server.request(path: "/session-logs/\(id)") else {
                isLoadingDetail = false
                return
            }
            request.timeoutInterval = 15

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let detail = try JSONDecoder().decode(SessionDetail.self, from: data)
                selectedSession = detail
                isLoadingDetail = false
            } catch {
                isLoadingDetail = false
            }
        }
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let detail: SessionDetail
    let server: ServerConnection
    var onResume: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var copiedToClipboard = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(detail.messages.enumerated()), id: \.offset) { _, msg in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: msg.type == "user" ? "person.fill" : "cpu")
                            .font(.system(size: 12))
                            .foregroundColor(msg.type == "user" ? AppTheme.accent : .green)
                            .frame(width: 20)

                        Text(msg.text)
                            .font(.system(size: 13))
                            .foregroundColor(AppTheme.bodyText)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 8)
        }
        .background(AppTheme.background)
        .navigationTitle("Session (\(detail.messageCount) messages)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.cardBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
                    .foregroundColor(AppTheme.accent)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    if let onResume {
                        Button {
                            onResume(detail.sessionId)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.circle.fill")
                                Text("Resume")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(AppTheme.accent)
                        }
                    }

                    Menu {
                        Button {
                            copySessionToClipboard()
                        } label: {
                            Label("Copy to Clipboard", systemImage: "doc.on.doc")
                        }

                        Button {
                            copyAsResumeCommand()
                        } label: {
                            Label("Copy --resume Command", systemImage: "terminal")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if copiedToClipboard {
                Text("Copied to clipboard")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(AppTheme.cardBackground.opacity(0.95))
                    .cornerRadius(8)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { copiedToClipboard = false }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copiedToClipboard)
    }

    private func copySessionToClipboard() {
        let text = detail.messages.map { msg in
            let role = msg.type == "user" ? "User" : "Assistant"
            return "[\(role)]: \(msg.text)"
        }.joined(separator: "\n\n")

        UIPasteboard.general.string = text
        copiedToClipboard = true
    }

    private func copyAsResumeCommand() {
        UIPasteboard.general.string = "claude --resume \(detail.sessionId)"
        copiedToClipboard = true
    }
}

// MARK: - Models

struct SessionListResponse: Codable {
    let sessions: [SessionSummary]
    let total: Int
}

struct SessionSummary: Codable, Identifiable {
    let id: String
    let filename: String
    let date: String
    let firstMessage: String
    let summary: String?
    let messageCount: Int
    let sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case id, filename, date, summary
        case firstMessage = "first_message"
        case messageCount = "message_count"
        case sizeBytes = "size_bytes"
    }

    var dateFormatted: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: date) {
            let df = DateFormatter()
            df.dateFormat = "d MMM HH:mm"
            return df.string(from: d)
        }
        return String(date.prefix(16))
    }

    var sizeFormatted: String {
        if sizeBytes > 1_000_000 {
            return String(format: "%.1f MB", Double(sizeBytes) / 1_000_000)
        } else {
            return String(format: "%.0f KB", Double(sizeBytes) / 1_000)
        }
    }
}

struct SessionDetail: Codable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let messageCount: Int
    let messages: [SessionMessage]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case messageCount = "message_count"
        case messages
    }
}

struct SessionMessage: Codable {
    let type: String
    let text: String
}
