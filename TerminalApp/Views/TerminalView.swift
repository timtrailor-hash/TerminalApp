import SwiftUI
import SwiftTerm
import TimSharedKit
import PhotosUI
import UniformTypeIdentifiers
import os

private let termLog = Logger(subsystem: "com.timtrailor.terminal", category: "terminalView")


struct TmuxWindow: Identifiable, Equatable {
    let index: Int
    let name: String
    let active: Bool
    let command: String
    let cwd: String
    let summary: String
    let status: String
    let elapsed: Int
    let pendingApproval: Bool
    let pendingToolName: String
    /// Monotonic counter that increments each time pendingApproval
    /// transitions false → true for this window. Zero when no prompt is
    /// active. Used by SplitTerminalView to distinguish "the same prompt
    /// I already answered" from "a brand-new prompt with identical
    /// choices", and as the stale-guard key on /tmux-send-key.
    let promptId: Int
    let pendingIntent: String
    let pendingRisk: String
    let pendingBlastRadius: String
    let pendingCommandPreview: String
    /// "native" or "hook" — drives whether the rich card renders 2 or 3
    /// buttons. Empty string when not applicable / older server.
    let pendingPromptType: String
    /// Pane-parsed options. Empty when not applicable / older server.
    let pendingOptions: [PaneOption]
    var id: Int { index }
}

private func formatTabStatus(_ status: String, _ elapsed: Int) -> String {
    guard elapsed >= 0 else { return "" }
    let time: String
    if elapsed < 60 { time = "\(elapsed)s" }
    else if elapsed < 3600 { time = "\(elapsed / 60)m" }
    else { time = "\(elapsed / 3600)h" }
    switch status {
    case "working": return "working \(time)"
    case "idle":    return "idle \(time)"
    default:        return ""
    }
}

/// Flattens the v1 typed `TimSharedKit.TmuxWindow` (with nested
/// `pending_prompt`) into the local flat `TmuxWindow` shape that
/// SplitTerminalView still consumes. Step 5 of the pause will collapse
/// the local struct onto the contract directly; until then this is the
/// adapter that lets PR A2 land without churning every consumer.
private func translateContractsTmuxWindow(_ w: TimSharedKit.TmuxWindow) -> TmuxWindow {
    let p = w.pendingPrompt
    let options: [PaneOption] = p?.options.map {
        PaneOption(number: $0.number, label: $0.label)
    } ?? []
    return TmuxWindow(
        index: w.index,
        name: w.name,
        active: w.active,
        command: w.command,
        cwd: w.cwd,
        summary: w.summary,
        status: w.status.rawValue,
        elapsed: w.elapsed,
        pendingApproval: p != nil,
        pendingToolName: p?.toolName ?? "",
        promptId: p?.promptId ?? 0,
        pendingIntent: p?.intent ?? "",
        pendingRisk: p?.risk?.rawValue ?? "",
        pendingBlastRadius: p?.blastRadius ?? "",
        pendingCommandPreview: p?.commandPreview ?? "",
        pendingPromptType: p?.promptType.rawValue ?? "",
        pendingOptions: options
    )
}

/// Native SSH terminal using SwiftTerm + NIOSSH.
struct TerminalView: View {
    @EnvironmentObject var server: ServerConnection
    @StateObject private var ssh = SSHTerminalService()
    @StateObject private var commandRunner = SSHCommandRunner()
    @StateObject private var sessionModel = TerminalSessionModel()
    @StateObject private var autonomousMonitor = AutonomousMonitor(serverProvider: {
        let s = ServerConnection()
        return (s.baseURL, s.authToken)
    })
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("sshUsername") private var sshUsername = "timtrailor"
    @State private var sshPassword = CredentialStore.loadPassword()
    @AppStorage("useSplitView") private var useSplitView = true

    @State private var terminalTitle = "Terminal"
    @State private var lastCapturedText = ""
    @State private var activeWindowIndex: Int = 1
    @State private var hasSyncedInitialWindow = false

    // Tmux window tabs
    @State private var tmuxWindows: [TmuxWindow] = []
    @State private var renameTargetIndex: Int? = nil
    @State private var renameText: String = ""
    @State private var showRenameAlert: Bool = false
    @State private var tmuxPollTimer: Timer?
    @State private var tmuxPollFailed = false
    @State private var isExporting = false
    @State private var exportStatus: String?
    @State private var exportStatusIsError = false
    @State private var terminalViewRef: STTerminalView?

    // File upload state
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isUploading = false
    @State private var pendingFiles: [PendingFile] = []
    @State private var showPendingFiles = false
    /// Paths from the most recent successful upload, handed to
    /// SplitTerminalView via Binding so it can combine them with any
    /// typed prose and submit as one message. Cleared by the consumer.
    @State private var pendingPathsToConsume: [String] = []

    private var serverIP: String {
        String(server.serverHost.split(separator: ":").first ?? "100.126.253.40")
    }

    struct PendingFile: Identifiable {
        let id = UUID()
        let thumbnail: UIImage
        let data: Data
        let filename: String
        let isFile: Bool

        init(thumbnail: UIImage, data: Data, filename: String = "image.jpg", isFile: Bool = false) {
            self.thumbnail = thumbnail
            self.data = data
            self.filename = filename
            self.isFile = isFile
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AutonomousBanner(monitor: autonomousMonitor)

            // Tmux window tab bar
            if ssh.isConnected && !tmuxWindows.isEmpty {
                HStack(spacing: 4) {
                    tmuxTabBar
                    if tmuxPollFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                            .padding(.trailing, 8)
                    }
                }
            }

            ZStack {
                AppTheme.background.ignoresSafeArea()

                if ssh.isConnected {
                    if useSplitView {
                        let activeWin = tmuxWindows.first(where: { $0.index == activeWindowIndex })
                        SplitTerminalView(
                            commandRunner: commandRunner,
                            ssh: ssh,
                            model: sessionModel,
                            activeWindowIndex: activeWindowIndex,
                            pendingApproval: activeWin?.pendingApproval ?? false,
                            pendingToolName: activeWin?.pendingToolName ?? "",
                            promptId: activeWin?.promptId ?? 0,
                            pendingIntent: activeWin?.pendingIntent ?? "",
                            pendingRisk: activeWin?.pendingRisk ?? "",
                            pendingBlastRadius: activeWin?.pendingBlastRadius ?? "",
                            pendingCommandPreview: activeWin?.pendingCommandPreview ?? "",
                            pendingPromptType: activeWin?.pendingPromptType ?? "",
                            pendingOptions: activeWin?.pendingOptions ?? [],
                            onCapturedText: { lastCapturedText = $0 },
                            pendingPathsToConsume: $pendingPathsToConsume,
                            tmuxWindowIndices: Set(tmuxWindows.map(\.index))
                        )
                    } else {
                        SwiftTermContainer(ssh: ssh, terminalTitle: $terminalTitle, terminalViewRef: $terminalViewRef)
                    }
                } else if ssh.isConnecting {
                    connectingView
                } else {
                    disconnectedView
                }
            }
        }
        .navigationTitle(terminalTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.cardBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Menu {
                        Button {
                            showCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }

                        Button {
                            captureScreenshot()
                        } label: {
                            Label("Screenshot", systemImage: "camera.viewfinder")
                        }

                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }

                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Choose File", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        ZStack {
                            Image(systemName: "paperclip")
                                .foregroundColor(AppTheme.accent)
                            if !pendingFiles.isEmpty {
                                Text("\(pendingFiles.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(AppTheme.background)
                                    .padding(3)
                                    .background(Circle().fill(AppTheme.accent))
                                    .offset(x: 8, y: -8)
                            }
                        }
                    }

                    Button {
                        exportToGoogleDocs()
                    } label: {
                        if isExporting {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "doc.text")
                                .foregroundColor(AppTheme.accent)
                        }
                    }
                    .disabled(!ssh.isConnected || isExporting)

                    NavigationLink(destination: SessionLogsView(onResume: { cmd in
                        ssh.sendString(cmd)
                    })) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(AppTheme.accent)
                    }

                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                            .foregroundColor(AppTheme.accent)
                    }

                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                // Export/upload status toast — sits above the pending files bar
                if let status = exportStatus {
                    Text(status)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(exportStatusIsError ? Color(hex: "#EE5555") : .green)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(AppTheme.cardBackground.opacity(0.95))
                        .cornerRadius(8)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation { exportStatus = nil }
                            }
                        }
                }

                // Pending files bar
                if !pendingFiles.isEmpty {
                    VStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(pendingFiles) { file in
                                    ZStack(alignment: .topTrailing) {
                                        if file.isFile {
                                            VStack(spacing: 2) {
                                                Image(systemName: fileIcon(for: file.filename))
                                                    .font(.system(size: 24))
                                                    .foregroundColor(AppTheme.accent)
                                                Text(file.filename)
                                                    .font(.system(size: 8))
                                                    .foregroundColor(AppTheme.bodyText)
                                                    .lineLimit(2)
                                                    .multilineTextAlignment(.center)
                                            }
                                            .frame(width: 60, height: 60)
                                            .background(AppTheme.cardBackground)
                                            .cornerRadius(8)
                                        } else {
                                            Image(uiImage: file.thumbnail)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 60, height: 60)
                                                .cornerRadius(8)
                                                .clipped()
                                        }

                                        Button {
                                            pendingFiles.removeAll { $0.id == file.id }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundColor(.white)
                                                .background(Circle().fill(Color.black.opacity(0.6)))
                                        }
                                        .offset(x: 4, y: -4)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }

                        Button {
                            uploadPendingFiles()
                        } label: {
                            HStack {
                                if isUploading {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .tint(AppTheme.background)
                                    Text("Uploading...")
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                    Text("Upload \(pendingFiles.count) file\(pendingFiles.count == 1 ? "" : "s")")
                                }
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(AppTheme.accent)
                            .cornerRadius(10)
                        }
                        .disabled(isUploading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    .background(AppTheme.cardBackground.opacity(0.95))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pendingFiles.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: exportStatus)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 5, matching: .images)
        .onChange(of: selectedPhotos) { _, newItems in
            Task { await loadSelectedPhotos(newItems) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                addCapturedImage(image)
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFilePicker) {
            FileImagePicker { data, filename in
                addFileData(data, filename: filename)
            }
        }
        .onAppear {
            sessionModel.server = server
            autoConnect()
            if ssh.isConnected && tmuxPollTimer == nil {
                startTmuxPolling()
            }
            autonomousMonitor.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                autoConnect()
                autonomousMonitor.start()
            } else if newPhase == .background {
                autonomousMonitor.stop()
            }
        }
        .onChange(of: ssh.isConnected) { _, connected in
            if connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { startTmuxPolling() }
            } else {
                stopTmuxPolling()
            }
        }
        .onDisappear {
            stopTmuxPolling()
            autonomousMonitor.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepLinkToWindow)) { note in
            guard let window = note.userInfo?["window"] as? Int else { return }
            if activeWindowIndex != window {
                activeWindowIndex = window
            }
            // Force a tab-bar + pane refresh so the latest content is in
            // place by the time the scene finishes becoming active.
            pollTmuxWindows()
            NotificationCenter.default.post(name: .paneRefreshRequested,
                                            object: nil,
                                            userInfo: ["window": window])
        }
    }


    // MARK: - Tmux Tab Bar

    private var tmuxTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tmuxWindows) { window in
                    Button {
                        selectTmuxWindow(index: window.index)
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            VStack(spacing: 3) {
                                Text("\(window.index)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(window.active ? AppTheme.background.opacity(0.75) : AppTheme.accent.opacity(0.55))
                                Image(systemName: window.status == "working" ? "circle.fill" : "checkmark.circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundColor(window.status == "working" ? .green : (window.active ? AppTheme.background.opacity(0.5) : .white.opacity(0.35)))
                            }
                            Text(window.summary.isEmpty ? (window.command.isEmpty ? window.name : window.command) : window.summary)
                                .font(.system(size: 12, weight: window.active ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(window.active ? AppTheme.background : .white.opacity(0.9))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minWidth: 140, maxWidth: 170, minHeight: 54, alignment: .topLeading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(window.active ? AppTheme.accent : AppTheme.cardBackground)
                        )
                    }
                    .contextMenu {
                        Button {
                            selectTmuxWindow(index: window.index)
                        } label: {
                            Label("Switch to", systemImage: "arrow.right.circle")
                        }
                        Button {
                            renameTargetIndex = window.index
                            renameText = window.summary.isEmpty ? window.name : window.summary
                            showRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            closeTmuxWindow(index: window.index)
                        } label: {
                            Label("Close", systemImage: "xmark.circle")
                        }
                    }
                }

                // New window button
                Button {
                    createTmuxWindow()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AppTheme.accent.opacity(0.7))
                        .frame(width: 44)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(AppTheme.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(AppTheme.accent.opacity(0.25), lineWidth: 1)
                                )
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(AppTheme.background)
        .alert("Rename tab", isPresented: $showRenameAlert, actions: {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Button("Save") {
                if let idx = renameTargetIndex {
                    renameTmuxWindow(index: idx, name: renameText)
                }
                renameTargetIndex = nil
            }
            Button("Cancel", role: .cancel) {
                renameTargetIndex = nil
            }
        }, message: {
            Text("Give this tab a name. It will stay until you rename or close it.")
        })
    }

    private func renameTmuxWindow(index: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: "\(server.baseURL)/tmux-rename-window") else { return }
        var request = server.authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "index": index,
            "name": trimmed,
        ])
        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pollTmuxWindows()
            }
        }.resume()
    }

    private func createTmuxWindow() {
        guard let url = URL(string: "\(server.baseURL)/tmux-new-window") else { return }
        var request = server.authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Tell the server to create the window at the pane's current
        // dimensions. If we let tmux default to 80x24 and resize
        // afterward, zsh redraws its prompt on SIGWINCH and leaves the
        // pre-resize prompt in scrollback — the pane then shows
        // duplicate "%" prompt lines (2026-04-17 bug).
        let cols = UserDefaults.standard.integer(forKey: "TerminalApp.lastPaneCols")
        let rows = UserDefaults.standard.integer(forKey: "TerminalApp.lastPaneRows")
        var body: [String: Any] = [:]
        if cols >= 20 && rows >= 5 {
            body["cols"] = cols
            body["rows"] = rows
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            // Read the new window index from the server so we can switch to
            // it immediately. Without this, activeWindowIndex stays on the
            // previous tab and the very next sendInput() routes into the
            // wrong pane.
            var newIndex: Int? = nil
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let idx = json["index"] as? Int, idx > 0 {
                newIndex = idx
            }
            DispatchQueue.main.async {
                if let idx = newIndex {
                    activeWindowIndex = idx
                    selectTmuxWindow(index: idx)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pollTmuxWindows()
                }
            }
        }.resume()
    }

    private func closeTmuxWindow(index: Int) {
        if tmuxWindows.count <= 1 {
            guard let url = URL(string: "\(server.baseURL)/tmux-new-window") else { return }
            var request = server.authedRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let cols = UserDefaults.standard.integer(forKey: "TerminalApp.lastPaneCols")
            let rows = UserDefaults.standard.integer(forKey: "TerminalApp.lastPaneRows")
            var body: [String: Any] = [:]
            if cols >= 20 && rows >= 5 { body["cols"] = cols; body["rows"] = rows }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: request) { data, _, _ in
                var created = false
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let idx = json["index"] as? Int, idx > 0 {
                    created = true
                    DispatchQueue.main.async { activeWindowIndex = idx }
                }
                if created {
                    DispatchQueue.main.async { killTmuxWindow(index: index) }
                }
            }.resume()
        } else {
            killTmuxWindow(index: index)
        }
    }

    private func killTmuxWindow(index: Int) {
        guard let url = URL(string: "\(server.baseURL)/tmux-kill-window") else { return }
        var request = server.authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["index": index])
        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pollTmuxWindows() }
        }.resume()
    }

    private func selectTmuxWindow(index: Int) {
        activeWindowIndex = index

        guard let url = URL(string: "\(server.baseURL)/tmux-select-window") else { return }
        var request = server.authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["index": index])
        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pollTmuxWindows() }
        }.resume()
    }

    private func pollTmuxWindows() {
        guard ssh.isConnected else { return }
        guard let url = URL(string: "\(server.baseURL)/tmux-windows") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data else { return }

            let applyWindows: ([TmuxWindow]) -> Void = { windows in
                DispatchQueue.main.async {
                    tmuxWindows = windows
                    // On first load, sync active window from tmux's perspective
                    if !hasSyncedInitialWindow, let active = windows.first(where: { $0.active }) {
                        activeWindowIndex = active.index
                        hasSyncedInitialWindow = true
                    }
                    // If our current activeWindowIndex no longer exists (the
                    // user just killed that tab), snap to whichever window
                    // tmux now reports as active — otherwise the pane keeps
                    // polling a dead window and the tab bar's orange
                    // selection drifts out of sync with the displayed pane.
                    else if !windows.contains(where: { $0.index == activeWindowIndex }) {
                        if let active = windows.first(where: { $0.active }) {
                            activeWindowIndex = active.index
                        } else if let first = windows.first {
                            activeWindowIndex = first.index
                        }
                    }
                }
            }

            do {
                let typed = try JSONDecoder().decode(TimSharedKit.TmuxWindowsResponse.self, from: data)
                guard typed.schemaVersion == TimSharedKit.ContractsSchemaVersion else {
                    let raw = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                    termLog.error("tmux-windows schema mismatch (got \(typed.schemaVersion), want \(TimSharedKit.ContractsSchemaVersion)): \(raw)")
                    DispatchQueue.main.async { self.tmuxPollFailed = true }
                    return
                }
                DispatchQueue.main.async { self.tmuxPollFailed = false }
                applyWindows(typed.windows.map(translateContractsTmuxWindow))
            } catch {
                let raw = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                termLog.error("tmux-windows decode failed: \(error.localizedDescription) raw: \(raw)")
                DispatchQueue.main.async { self.tmuxPollFailed = true }
            }
        }.resume()
    }

    private func startTmuxPolling() {
        tmuxPollTimer?.invalidate()
        // Use Timer(timeInterval:repeats:block:) + RunLoop.common so the
        // poll keeps firing even while the keyboard is up or the pane is
        // scrolling (the default runloop mode pauses under UI tracking).
        let t = Timer(timeInterval: 3, repeats: true) { _ in
            pollTmuxWindows()
        }
        RunLoop.main.add(t, forMode: .common)
        tmuxPollTimer = t
        pollTmuxWindows() // immediate first poll
    }

    private func stopTmuxPolling() {
        tmuxPollTimer?.invalidate()
        tmuxPollTimer = nil
        // Deliberately DO NOT clear tmuxWindows here. If the view reappears
        // before the next poll tick, the user keeps seeing the last-known
        // tabs instead of an empty bar.
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
            // Auto-start tmux so tab bar and session persistence work
            // -A: attach if session exists, -s mobile: named session
            try? await Task.sleep(nanoseconds: 500_000_000) // wait for shell prompt
            ssh.sendString("tmux new-session -A -s mobile\n")

            // Connect command runner (second SSH connection for tmux commands)
            if useSplitView {
                await commandRunner.connect(host: serverIP, username: sshUsername, password: sshPassword)
            }

            // Re-register APNs device token with server (in case server restarted)
            if let token = UserDefaults.standard.string(forKey: "apnsDeviceToken") {
                registerDeviceToken(token)
            }
        }
    }

    private func reconnect() {
        ssh.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            connectSSH()
        }
    }

    private func registerDeviceToken(_ token: String) {
        guard let url = URL(string: "\(server.baseURL)/register-device") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.authToken.isEmpty {
            request.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["device_token": token])
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    private func autoConnect() {
        if !ssh.isConnected && !ssh.isConnecting && !sshPassword.isEmpty {
            connectSSH()
        }
    }

    // MARK: - File Upload

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        var failures: [String] = []
        for (idx, item) in items.enumerated() {
            let label = "photo \(idx + 1)"
            do {
                guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                    failures.append("\(label): could not be read")
                    continue
                }
                guard let uiImage = UIImage(data: data) else {
                    failures.append("\(label): not a valid image")
                    continue
                }
                let thumb = uiImage.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? uiImage
                // jpegData can return nil for unsupported colour spaces (CMYK,
                // some HEIF variants); fall back to the original bytes only
                // when those are themselves a non-empty image payload.
                let encoded = uiImage.jpegData(compressionQuality: 0.8)
                let jpegData = (encoded?.isEmpty == false) ? encoded! : data
                guard !jpegData.isEmpty else {
                    failures.append("\(label): empty payload after encode")
                    continue
                }
                await MainActor.run {
                    pendingFiles.append(PendingFile(thumbnail: thumb, data: jpegData))
                }
            } catch {
                failures.append("\(label): \(error.localizedDescription)")
            }
        }
        await MainActor.run {
            selectedPhotos = []
            if !failures.isEmpty {
                exportStatusIsError = true
                let head = failures.prefix(3).joined(separator: "; ")
                let extra = failures.count > 3 ? " (+\(failures.count - 3) more)" : ""
                exportStatus = "Photo load failed: \(head)\(extra)"
            }
        }
    }

    private func addCapturedImage(_ image: UIImage) {
        let thumb = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        guard let jpegData = image.jpegData(compressionQuality: 0.8), !jpegData.isEmpty else {
            exportStatusIsError = true
            exportStatus = "Camera image could not be compressed"
            return
        }
        pendingFiles.append(PendingFile(thumbnail: thumb, data: jpegData))
    }

    private func addFileData(_ data: Data, filename: String) {
        guard !data.isEmpty else {
            exportStatusIsError = true
            exportStatus = "File \(filename) is empty, skipped"
            return
        }
        if let image = UIImage(data: data) {
            let thumb = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
            let encoded = image.jpegData(compressionQuality: 0.8)
            let jpegData = (encoded?.isEmpty == false) ? encoded! : data
            pendingFiles.append(PendingFile(thumbnail: thumb, data: jpegData, filename: filename))
        } else {
            let placeholder = UIImage(systemName: "doc.fill") ?? UIImage()
            pendingFiles.append(PendingFile(thumbnail: placeholder, data: data, filename: filename, isFile: true))
        }
    }

    private func captureScreenshot() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first else { return }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let thumb = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        guard let jpegData = image.jpegData(compressionQuality: 0.8), !jpegData.isEmpty else {
            exportStatusIsError = true
            exportStatus = "Screenshot capture failed"
            return
        }
        pendingFiles.append(PendingFile(thumbnail: thumb, data: jpegData, filename: "screenshot.jpg"))
    }

    private func uploadPendingFiles() {
        let files = pendingFiles
        isUploading = true

        Task {
            var uploadedPaths: [String] = []
            guard let uploadURL = URL(string: "\(server.baseURL)/upload") else {
                isUploading = false
                exportStatusIsError = true
                exportStatus = "Upload failed — invalid server URL"
                return
            }

            var skippedEmpty = 0
            for file in files {
                guard !file.data.isEmpty else {
                    skippedEmpty += 1
                    continue
                }
                var request = server.authedRequest(url: uploadURL)
                request.httpMethod = "POST"

                let boundary = UUID().uuidString
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

                let mimeType = file.isFile ? mimeTypeFor(filename: file.filename) : "image/jpeg"

                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.filename)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
                body.append(file.data)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                request.httpBody = body

                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if statusCode >= 400 {
                        let errorMsg = extractErrorMessage(from: data) ?? "HTTP \(statusCode)"
                        await MainActor.run {
                            exportStatusIsError = true
                            exportStatus = "Upload error: \(errorMsg)"
                        }
                        continue
                    }
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let path = json["path"] as? String {
                        uploadedPaths.append(path)
                    } else {
                        await MainActor.run {
                            exportStatusIsError = true
                            exportStatus = "Upload failed: unexpected response"
                        }
                    }
                } catch {
                    await MainActor.run {
                        exportStatusIsError = true
                        exportStatus = "Upload failed: \(error.localizedDescription)"
                    }
                }
            }

            await MainActor.run {
                isUploading = false
                pendingFiles = []

                if !uploadedPaths.isEmpty {
                    // Hand the paths off to SplitTerminalView via the
                    // pendingPathsToConsume binding. SplitTerminalView's
                    // .onChange handler reads any prose typed in the
                    // active tab's input field and submits paths + prose
                    // as one message. If no prose is pending it falls
                    // back to pasting paths to the pane unchanged.
                    // Fixes the 2026-05-04 bug where typed prose got lost
                    // alongside an attachment upload.
                    if useSplitView {
                        pendingPathsToConsume = uploadedPaths
                    } else {
                        let pathsText = uploadedPaths.joined(separator: " ")
                        ssh.sendString(pathsText + " ")
                    }

                    exportStatusIsError = false
                    let fileWord = uploadedPaths.count == 1 ? "file" : "files"
                    let suffix = skippedEmpty > 0 ? " (\(skippedEmpty) empty skipped)" : ""
                    exportStatus = "\(uploadedPaths.count) \(fileWord) uploaded\(suffix)"
                } else if skippedEmpty > 0 {
                    exportStatusIsError = true
                    exportStatus = "All \(skippedEmpty) file(s) were empty, nothing uploaded"
                } else {
                    exportStatusIsError = true
                    exportStatus = "Upload failed"
                }
            }
        }
    }

    private func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "txt", "md", "log": return "doc.text"
        case "csv", "xlsx", "xls": return "tablecells"
        case "json", "xml", "yaml", "yml": return "curlybraces"
        case "py", "swift", "js", "ts", "html", "css": return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz": return "doc.zipper"
        default: return "doc.fill"
        }
    }

    private func mimeTypeFor(filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt", "md", "log": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "zip": return "application/zip"
        case "py", "swift", "js", "ts", "html", "css": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? String ?? json["message"] as? String
    }

    // MARK: - Export

    private func exportToGoogleDocs() {
        isExporting = true
        let text: String
        if useSplitView {
            text = lastCapturedText
        } else {
            guard let tv = terminalViewRef else {
                isExporting = false
                exportStatusIsError = true
                exportStatus = "No terminal view"
                return
            }
            let data = tv.getTerminal().getBufferAsData()
            text = String(data: data, encoding: .utf8) ?? ""
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isExporting = false
            exportStatusIsError = true
            exportStatus = "Nothing to export"
            return
        }

        Task {
            do {
                guard let url = URL(string: "\(server.baseURL)/terminal-to-doc") else {
                    isExporting = false
                    exportStatusIsError = true
                    exportStatus = "Bad URL: \(server.baseURL)/terminal-to-doc"
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !server.authToken.isEmpty {
                    request.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
                }

                // Strip control characters that break JSON
                let cleanText = text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\r" || $0 == "\t" }.map(String.init).joined()
                request.httpBody = try JSONSerialization.data(withJSONObject: ["text": cleanText])

                let (data, response) = try await URLSession.shared.data(for: request)
                isExporting = false

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard statusCode < 400 else {
                    let errorMsg = extractErrorMessage(from: data) ?? "Server error \(statusCode)"
                    exportStatusIsError = true
                    exportStatus = errorMsg
                    return
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let docURL = json["doc_url"] as? String {
                    exportStatusIsError = false
                    exportStatus = "Exported to Google Docs"
                    if let openURL = URL(string: docURL) {
                        await UIApplication.shared.open(openURL)
                    }
                } else {
                    exportStatusIsError = false
                    exportStatus = "Exported"
                }
            } catch {
                isExporting = false
                exportStatusIsError = true
                exportStatus = "Export failed: \(error.localizedDescription)"
            }
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
    @Binding var terminalViewRef: STTerminalView?

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

        // Store ref for export
        DispatchQueue.main.async {
            terminalViewRef = tv
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

// MARK: - Camera Picker

struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - File Picker (any file from Files app)

struct FileImagePicker: UIViewControllerRepresentable {
    let onPick: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .image, .pdf, .plainText, .json, .xml, .commaSeparatedText,
            .data, .sourceCode, .spreadsheet, .presentation
        ])
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FileImagePicker
        init(parent: FileImagePicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url) {
                    parent.onPick(data, url.lastPathComponent)
                }
            }
        }
    }
}
