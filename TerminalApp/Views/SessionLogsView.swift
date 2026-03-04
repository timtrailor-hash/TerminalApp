import SwiftUI
import TimSharedKit

struct SessionLogsView: View {
    @EnvironmentObject var server: ServerConnection
    @State private var sessions: [SessionSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedSession: SessionDetail?
    @State private var isLoadingDetail = false

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

                            Text(session.sizeFormatted)
                                .font(.system(size: 10))
                                .foregroundColor(AppTheme.fadedText)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(AppTheme.cardBackground)
                }
                .listStyle(.plain)
                .refreshable { loadSessions() }
            }
        }
        .navigationTitle("Session Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.cardBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $selectedSession) { detail in
            NavigationStack {
                SessionDetailView(detail: detail, server: server)
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
    @Environment(\.dismiss) private var dismiss
    @State private var copiedToClipboard = false
    @State private var pastedToTerminal = false

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
                Menu {
                    Button {
                        copySessionToClipboard()
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                    }

                    Button {
                        copyAsContextCommand()
                    } label: {
                        Label("Copy as --resume Command", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(AppTheme.accent)
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

    private func copyAsContextCommand() {
        // Copy the session ID so user can use --resume
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
    let messageCount: Int
    let sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case id, filename, date
        case firstMessage = "first_message"
        case messageCount = "message_count"
        case sizeBytes = "size_bytes"
    }

    var dateFormatted: String {
        // Parse ISO date and format nicely
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
