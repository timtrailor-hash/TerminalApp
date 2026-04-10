import SwiftUI
import TimSharedKit
import os

private let splitLog = Logger(subsystem: "com.timtrailor.terminal", category: "splitView")

/// Split-screen terminal view: scrollable output on top, text input on bottom.
struct SplitTerminalView: View {
    @ObservedObject var commandRunner: SSHCommandRunner
    @ObservedObject var ssh: SSHTerminalService
    @EnvironmentObject var server: ServerConnection

    /// The tmux window index the user is currently viewing. Defaults to 1.
    let activeWindowIndex: Int
    var onCapturedText: ((String) -> Void)?

    @State private var perTabLines: [Int: [PaneLine]] = [:]
    @State private var perTabInput: [Int: String] = [:]
    @State private var perTabPaneHash: [Int: Int] = [:]
    @State private var hasLoadedOnce: Bool = false

    private var paneLines: [PaneLine] {
        perTabLines[activeWindowIndex] ?? []
    }
    @State private var pollTimer: Timer?
    @State private var isSending = false
    @State private var fastPollUntil: Date = .distantPast
    @State private var isUserScrolledUp = false
    @FocusState private var inputFocused: Bool

    // MARK: - HTTP helpers

    private func httpCaptureTmux(window: Int) async -> String? {
        guard let url = URL(string: "\(server.baseURL)/tmux-capture?window=\(window)&lines=500") else { return nil }
        var request = URLRequest(url: url)
        if !server.authToken.isEmpty {
            request.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? String else { return nil }
            return content
        } catch {
            return nil
        }
    }

    private func httpSendText(_ text: String, window: Int) async {
        guard let url = URL(string: "\(server.baseURL)/tmux-send-text") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.authToken.isEmpty {
            request.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "window": window])
        _ = try? await URLSession.shared.data(for: request)
    }

    private func httpSendEnter(window: Int) async {
        guard let url = URL(string: "\(server.baseURL)/tmux-send-enter") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.authToken.isEmpty {
            request.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["window": window])
        _ = try? await URLSession.shared.data(for: request)
    }

    private var inputText: Binding<String> {
        Binding(
            get: { perTabInput[activeWindowIndex] ?? "" },
            set: { perTabInput[activeWindowIndex] = $0 }
        )
    }

    private var tmuxTarget: String {
        "mobile:\(activeWindowIndex)"
    }

    struct PaneLine: Identifiable {
        let id: Int
        let text: String
        let lineType: LineType
    }

    enum LineType {
        case userInput   // Lines the user typed (prompt lines)
        case claudeText  // Claude's response text
        case system      // Tool use, system info, etc.
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                outputSection
                    .frame(height: geo.size.height * 0.68)

                Divider()
                    .background(AppTheme.accent.opacity(0.3))

                inputSection
                    .frame(height: geo.size.height * 0.32)
            }
        }
        .background(AppTheme.background)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .onChange(of: activeWindowIndex) { _, _ in
            // Keep per-tab cached content; just refresh in background
            isUserScrolledUp = false
            Task { await refreshPane() }
        }
    }

    // MARK: - Output Section

    private var outputSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if paneLines.isEmpty {
                        Text(hasLoadedOnce ? "" : "Loading...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(AppTheme.dimText)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                    } else {
                        ForEach(paneLines) { line in
                            Text(line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(colorFor(line.lineType))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 0.5)
                                .id(line.id)
                        }
                    }
                }
                .textSelection(.enabled)
            }
            .background(AppTheme.background)
            .onChange(of: paneLines.count) { _, _ in
                if !isUserScrolledUp, let last = paneLines.last {
                    // Small delay to let layout complete before scrolling
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .simultaneousGesture(
                DragGesture().onChanged { value in
                    if value.translation.height > 10 {
                        isUserScrolledUp = true
                    }
                }
            )
            .overlay(alignment: .bottomTrailing) {
                if isUserScrolledUp {
                    Button {
                        isUserScrolledUp = false
                        if let last = paneLines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(AppTheme.accent)
                            .background(Circle().fill(AppTheme.background))
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Color coding

    private func colorFor(_ type: LineType) -> Color {
        switch type {
        case .userInput:
            return Color(red: 0.4, green: 0.8, blue: 1.0) // bright cyan
        case .claudeText:
            return Color(red: 0.88, green: 0.88, blue: 0.88) // light grey (default)
        case .system:
            return Color(red: 0.6, green: 0.6, blue: 0.6) // dim grey
        }
    }

    private func classifyLine(_ text: String) -> LineType {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // User prompt lines (Claude Code uses ❯ or > as prompt)
        if trimmed.hasPrefix("❯ ") || trimmed.hasPrefix("> ") || trimmed.hasPrefix("$ ") {
            return .userInput
        }

        // Lines that look like the user's message continuation (after prompt)
        // Tool use indicators
        if trimmed.hasPrefix("⏺") || trimmed.hasPrefix("●") {
            return .system
        }

        // File paths, tool headers
        if trimmed.hasPrefix("─") || trimmed.hasPrefix("╭") || trimmed.hasPrefix("╰") ||
           trimmed.hasPrefix("│") || trimmed.hasPrefix("├") {
            return .system
        }

        return .claudeText
    }

    // MARK: - Input Section

    private var inputSection: some View {
        let currentInput = perTabInput[activeWindowIndex] ?? ""
        let isEmpty = currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: inputText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.cardBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppTheme.accent.opacity(0.3), lineWidth: 1)
                    )
                    .focused($inputFocused)

                Button {
                    sendInput()
                } label: {
                    if isSending {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(AppTheme.background)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(isEmpty ? AppTheme.dimText : AppTheme.accent)
                    }
                }
                .disabled(isSending || isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(AppTheme.cardBackground.opacity(0.95))
    }

    // MARK: - Actions

    private func sendInput() {
        let current = perTabInput[activeWindowIndex] ?? ""
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSending = true
        let textToSend = text
        let window = activeWindowIndex
        perTabInput[activeWindowIndex] = ""
        isUserScrolledUp = false // auto-scroll to see response

        Task {
            await httpSendText(textToSend, window: window)
            await httpSendEnter(window: window)
            isSending = false
            fastPollUntil = Date().addingTimeInterval(30)
            await refreshPane()

            // Tell server to watch for Claude's response and push-notify when done
            triggerResponseWatch()
        }
    }

    private func triggerResponseWatch() {
        guard let url = URL(string: "\(server.baseURL)/watch-tmux") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.authToken.isEmpty {
            request.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["session": "mobile"])
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                await refreshPane()
            }
        }
        Task { await refreshPane() }
        splitLog.info("Polling started")
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshPane() async {
        let capturedIndex = activeWindowIndex
        guard let content = await httpCaptureTmux(window: capturedIndex) else { return }

        hasLoadedOnce = true

        let hash = content.hashValue
        guard hash != (perTabPaneHash[capturedIndex] ?? 0) else { return }
        perTabPaneHash[capturedIndex] = hash

        let lines = content.components(separatedBy: "\n")
        let paneLineObjects = lines.enumerated().map { idx, text in
            PaneLine(id: idx, text: text, lineType: classifyLine(text))
        }
        perTabLines[capturedIndex] = paneLineObjects

        // Notify parent of captured text (only for the visible tab)
        if capturedIndex == activeWindowIndex {
            onCapturedText?(lines.joined(separator: "\n"))
        }
    }
}
