import Foundation
import os

private let cmdLog = Logger(subsystem: "com.timtrailor.terminal", category: "commandRunner")

/// A second SSH connection used exclusively for running commands (tmux capture-pane, send-keys).
/// Does NOT attach to tmux — stays at a raw shell prompt.
@MainActor
final class SSHCommandRunner: ObservableObject {
    private let ssh = SSHTerminalService()
    @Published var isReady = false

    private var outputBuffer = ""
    private var pendingContinuation: CheckedContinuation<String, Never>?
    private let marker = "___END_CMD_\(UUID().uuidString.prefix(8))___"

    func connect(host: String, username: String, password: String) async {
        ssh.onDataReceived = { [weak self] data in
            guard let self, let text = String(data: data, encoding: .utf8) else { return }
            self.handleOutput(text)
        }
        await ssh.connect(host: host, username: username, password: password)

        // Wait for shell to be ready, then disable echo for clean output parsing
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        if ssh.isConnected {
            // Set a unique prompt and disable echo so we get clean command output
            ssh.sendString("export PS1=''; stty -echo\n")
            try? await Task.sleep(nanoseconds: 500_000_000)
            isReady = true
            cmdLog.info("Command runner ready")
        }
    }

    /// Run a command and return its output.
    func run(_ command: String) async -> String {
        guard ssh.isConnected else { return "" }

        return await withCheckedContinuation { continuation in
            outputBuffer = ""
            pendingContinuation = continuation
            ssh.sendString("\(command); echo '\(marker)'\n")
        }
    }

    /// Send text to a specific tmux window as if typed.
    func sendToTmux(_ text: String, target: String = "mobile") async {
        // Base64 encode to avoid quoting issues
        let base64 = Data(text.utf8).base64EncodedString()
        let cmd = "echo '\(base64)' | base64 -d | /opt/homebrew/bin/tmux load-buffer - && /opt/homebrew/bin/tmux paste-buffer -t \(target) -d"
        _ = await run(cmd)
    }

    /// Send Enter key to a specific tmux window.
    func sendEnterToTmux(target: String = "mobile") async {
        _ = await run("/opt/homebrew/bin/tmux send-keys -t \(target) Enter")
    }

    /// Capture scrollback from a specific tmux window.
    func captureTmuxPane(target: String = "mobile", lines: Int = 500) async -> String {
        // -J: join wrapped lines (avoid weird mid-sentence breaks at terminal width)
        let output = await run("/opt/homebrew/bin/tmux capture-pane -p -J -S -\(lines) -t \(target) 2>/dev/null")
        // Trim trailing empty lines
        return output.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    var isConnected: Bool { ssh.isConnected }

    func disconnect() {
        ssh.disconnect()
        isReady = false
    }

    // MARK: - Private

    private func handleOutput(_ text: String) {
        guard pendingContinuation != nil else { return }
        outputBuffer += text

        if outputBuffer.contains(marker) {
            let parts = outputBuffer.components(separatedBy: marker)
            var result = parts.first ?? ""

            // Clean up: remove leading blank lines from shell noise
            while result.hasPrefix("\n") || result.hasPrefix("\r\n") {
                if result.hasPrefix("\r\n") {
                    result = String(result.dropFirst(2))
                } else {
                    result = String(result.dropFirst())
                }
            }
            // Remove trailing newlines
            while result.hasSuffix("\n") || result.hasSuffix("\r\n") {
                if result.hasSuffix("\r\n") {
                    result = String(result.dropLast(2))
                } else {
                    result = String(result.dropLast())
                }
            }

            pendingContinuation?.resume(returning: result)
            pendingContinuation = nil
            outputBuffer = ""
        }
    }
}
