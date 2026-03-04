import SwiftUI
import SwiftTerm
import TimSharedKit
import os

private let termLog = Logger(subsystem: "com.timtrailor.terminal", category: "terminalView")

/// Native SSH terminal using SwiftTerm + NIOSSH.
struct TerminalView: View {
    @EnvironmentObject var server: ServerConnection
    @StateObject private var ssh = SSHTerminalService()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("sshUsername") private var sshUsername = "timtrailor"
    @AppStorage("sshPassword") private var sshPassword = ""

    @State private var terminalTitle = "Terminal"

    private var serverIP: String {
        String(server.serverHost.split(separator: ":").first ?? "100.126.253.40")
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if ssh.isConnected {
                SwiftTermContainer(ssh: ssh, terminalTitle: $terminalTitle)
            } else if ssh.isConnecting {
                connectingView
            } else {
                disconnectedView
            }
        }
        .navigationTitle(terminalTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.cardBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    ssh.sendString("tmux new-window\n")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.rectangle")
                        Text("New")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(AppTheme.accent)
                }
                .disabled(!ssh.isConnected)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                            .foregroundColor(AppTheme.accent)
                    }

                    Button {
                        reconnect()
                    } label: {
                        Image(systemName: "arrow.trianglehead.2.counterclockwise")
                            .foregroundColor(AppTheme.accent)
                    }

                    Button {
                        if ssh.isConnected {
                            ssh.disconnect()
                        } else {
                            connectSSH()
                        }
                    } label: {
                        Image(systemName: ssh.isConnected ? "wifi.slash" : "wifi")
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }
        }
        .onAppear {
            autoConnect()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                autoConnect()
            }
        }
    }

    // MARK: - Sub-views

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(AppTheme.accent)
            Text("Connecting to \(serverIP)...")
                .foregroundColor(AppTheme.dimText)
                .font(.system(size: 14, design: .monospaced))
        }
    }

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            if let error = ssh.connectionError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                Text(error)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(hex: "#EE5555"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundColor(AppTheme.accent.opacity(0.5))
            }

            Button("Connect") {
                connectSSH()
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.accent)
            .disabled(sshPassword.isEmpty)

            if sshPassword.isEmpty {
                Text("Set SSH password in Settings")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.fadedText)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func connectSSH() {
        guard !sshPassword.isEmpty else { return }
        Task {
            await ssh.connect(host: serverIP, username: sshUsername, password: sshPassword)
        }
    }

    private func reconnect() {
        ssh.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            connectSSH()
        }
    }

    private func autoConnect() {
        if !ssh.isConnected && !ssh.isConnecting && !sshPassword.isEmpty {
            connectSSH()
        }
    }
}

// MARK: - SwiftTerm UIViewRepresentable

/// Type alias to disambiguate SwiftTerm's TerminalView from our own TerminalView struct
typealias STTerminalView = SwiftTerm.TerminalView

/// Wraps SwiftTerm's native TerminalView for use in SwiftUI.
/// Bridges keyboard input -> SSH and SSH output -> terminal display.
struct SwiftTermContainer: UIViewRepresentable {
    @ObservedObject var ssh: SSHTerminalService
    @Binding var terminalTitle: String

    func makeCoordinator() -> Coordinator {
        Coordinator(ssh: ssh, titleBinding: $terminalTitle)
    }

    func makeUIView(context: Context) -> STTerminalView {
        let tv = STTerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv

        // Dark theme matching the app
        let bgColor = UIColor(red: 0.102, green: 0.102, blue: 0.180, alpha: 1)
        let fgColor = UIColor(red: 0.878, green: 0.878, blue: 0.878, alpha: 1)
        tv.nativeBackgroundColor = bgColor
        tv.nativeForegroundColor = fgColor

        // Monospace font
        let fontSize: CGFloat = 13
        tv.font = UIFont(name: "Menlo-Regular", size: fontSize)
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Wire SSH output -> terminal display
        ssh.onDataReceived = { data in
            let bytes = [UInt8](data)
            tv.feed(byteArray: bytes[...])
        }

        // Bring up keyboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            _ = tv.becomeFirstResponder()
        }

        termLog.info("SwiftTerm terminal view created")
        return tv
    }

    func updateUIView(_ uiView: STTerminalView, context: Context) {}

    class Coordinator: NSObject, TerminalViewDelegate {
        weak var terminalView: STTerminalView?
        let ssh: SSHTerminalService
        @Binding var terminalTitle: String

        init(ssh: SSHTerminalService, titleBinding: Binding<String>) {
            self.ssh = ssh
            self._terminalTitle = titleBinding
        }

        // User typed -> send to SSH
        func send(source: STTerminalView, data: ArraySlice<UInt8>) {
            let d = Data(data)
            Task { @MainActor in
                ssh.send(d)
            }
        }

        // Terminal resized -> update SSH PTY
        func sizeChanged(source: STTerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                ssh.resize(cols: newCols, rows: newRows)
            }
            termLog.info("Terminal size: \(newCols)x\(newRows)")
        }

        func scrolled(source: STTerminalView, position: Double) {}

        func setTerminalTitle(source: STTerminalView, title: String) {
            Task { @MainActor in
                self.terminalTitle = title.isEmpty ? "Terminal" : title
            }
        }

        func hostCurrentDirectoryUpdate(source: STTerminalView, directory: String?) {}

        func requestOpenLink(source: STTerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }

        func rangeChanged(source: STTerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: STTerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
    }
}
