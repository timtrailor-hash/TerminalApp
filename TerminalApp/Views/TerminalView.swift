import SwiftUI
import SwiftTerm
import TimSharedKit
import PhotosUI
import UniformTypeIdentifiers
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
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if ssh.isConnected {
                SwiftTermContainer(ssh: ssh, terminalTitle: $terminalTitle, terminalViewRef: $terminalViewRef)
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
                HStack(spacing: 14) {
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
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
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
        .overlay(alignment: .bottom) {
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
        .animation(.easeInOut(duration: 0.2), value: pendingFiles.isEmpty)
        .overlay(alignment: .bottom) {
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
        }
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

    // MARK: - File Upload

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                let thumb = uiImage.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? uiImage
                let jpegData = uiImage.jpegData(compressionQuality: 0.8) ?? data
                await MainActor.run {
                    pendingFiles.append(PendingFile(thumbnail: thumb, data: jpegData))
                }
            }
        }
        await MainActor.run { selectedPhotos = [] }
    }

    private func addCapturedImage(_ image: UIImage) {
        let thumb = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        let jpegData = image.jpegData(compressionQuality: 0.8) ?? Data()
        pendingFiles.append(PendingFile(thumbnail: thumb, data: jpegData))
    }

    private func addFileData(_ data: Data, filename: String) {
        if let image = UIImage(data: data) {
            let thumb = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
            let jpegData = image.jpegData(compressionQuality: 0.8) ?? data
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
        let jpegData = image.jpegData(compressionQuality: 0.8) ?? Data()
        pendingFiles.append(PendingFile(thumbnail: thumb, data: jpegData, filename: "screenshot.jpg"))
    }

    private func uploadPendingFiles() {
        let files = pendingFiles
        isUploading = true

        Task {
            var uploadedPaths: [String] = []
            let uploadURL = URL(string: "\(server.baseURL)/upload")!

            for file in files {
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

                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let path = json["path"] as? String {
                    uploadedPaths.append(path)
                }
            }

            await MainActor.run {
                isUploading = false
                pendingFiles = []

                if !uploadedPaths.isEmpty {
                    // Paste file paths into terminal so user can reference them
                    let pathsText = uploadedPaths.joined(separator: " ")
                    ssh.sendString("# Uploaded: \(pathsText)\n")

                    exportStatusIsError = false
                    let fileWord = uploadedPaths.count == 1 ? "file" : "files"
                    exportStatus = "\(uploadedPaths.count) \(fileWord) uploaded"
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

    // MARK: - Export

    private func exportToGoogleDocs() {
        guard let tv = terminalViewRef else {
            exportStatusIsError = true
            exportStatus = "No terminal view"
            return
        }

        isExporting = true
        let data = tv.getTerminal().getBufferAsData()
        let text = String(data: data, encoding: .utf8) ?? ""

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
                    let body = String(data: data, encoding: .utf8) ?? ""
                    exportStatusIsError = true
                    exportStatus = "Server error \(statusCode): \(body.prefix(100))"
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
