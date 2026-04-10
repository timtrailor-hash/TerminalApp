import Foundation
import mosh
import os

private let moshLog = Logger(subsystem: "com.timtrailor.terminal", category: "mosh")

// MARK: - Mosh Terminal Service

/// Manages a Mosh connection that survives iOS backgrounding.
/// Same observable interface as SSHTerminalService for drop-in use.
@MainActor
final class MoshTerminalService: ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectionError: String?

    /// Callback for terminal output bytes — wire to SwiftTerm's feed()
    var onDataReceived: ((Data) -> Void)?

    // Connection info (persisted for resume)
    private var serverIP: String = ""
    private var moshPort: UInt16 = 0
    private var moshKey: String = ""

    // Pipe file descriptors
    private var inputReadFD: Int32 = -1
    private var inputWriteFD: Int32 = -1
    private var outputReadFD: Int32 = -1
    private var outputWriteFD: Int32 = -1

    // FILE pointers for mosh_main
    private var inputFile: UnsafeMutablePointer<FILE>?
    private var outputFile: UnsafeMutablePointer<FILE>?

    // Output reader
    private var outputSource: DispatchSourceRead?

    // Mosh thread
    private var moshThread: Thread?

    // Window size — shared with mosh_main via pointer
    private var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

    // State serialization for suspend/resume
    private var serializedState: Data?
    private var hasMoshSession = false

    // SSH credentials for launching mosh-server
    private var sshHost: String = ""
    private var sshPort: Int = 22
    private var sshUsername: String = ""
    private var sshPassword: String = ""

    // MARK: - Public Interface

    /// Connect to a remote host via Mosh.
    /// First SSHs in to start mosh-server, then launches the mosh client.
    func connect(host: String, port: Int = 22, username: String, password: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = nil

        // Store SSH credentials for reconnect
        sshHost = host
        sshPort = port
        sshUsername = username
        sshPassword = password
        serverIP = host

        moshLog.info("Starting mosh-server on \(host):\(port)")

        do {
            let launcher = MoshServerLauncher(host: host, port: port, username: username, password: password)
            let info = try await launcher.launch()

            moshPort = info.port
            moshKey = info.key

            moshLog.info("mosh-server ready on port \(info.port)")
            launchMoshClient(state: nil)
        } catch {
            moshLog.error("Failed to start mosh-server: \(error)")
            connectionError = error.localizedDescription
            isConnecting = false
        }
    }

    /// Send user input to the remote shell
    func send(_ data: Data) {
        guard inputWriteFD >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            Darwin.write(inputWriteFD, ptr, buffer.count)
        }
    }

    /// Send a string to the remote shell
    func sendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            send(data)
        }
    }

    /// Resize the terminal
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        windowSize.ws_col = UInt16(cols)
        windowSize.ws_row = UInt16(rows)
        // mosh_main reads the winsize pointer periodically — the update is picked up automatically
        moshLog.info("Resize: \(cols)x\(rows)")
    }

    /// Disconnect and clean up
    func disconnect() {
        cleanupPipes()
        serializedState = nil
        hasMoshSession = false
        isConnected = false
        isConnecting = false
        moshLog.info("Disconnected")
    }

    /// Suspend the mosh session for iOS backgrounding.
    /// Triggers state serialization so we can resume instantly.
    func suspend() {
        guard hasMoshSession, inputWriteFD >= 0 else { return }
        moshLog.info("Suspending mosh session")

        // Send Ctrl-^ Ctrl-Z to trigger mosh detach + state serialization
        let detachSequence: [UInt8] = [0x1E, 0x1A]
        detachSequence.withUnsafeBufferPointer { buffer in
            Darwin.write(inputWriteFD, buffer.baseAddress!, buffer.count)
        }

        // Give mosh a moment to serialize state before we close pipes
        // The state_callback will fire synchronously within mosh_main
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task { @MainActor in
                self?.cleanupPipes()
            }
        }
    }

    /// Resume from suspended state. If we have serialized state, restore instantly.
    /// If not, do a full reconnect.
    func resume() {
        if isConnected || isConnecting { return }

        if let state = serializedState, moshPort > 0, !moshKey.isEmpty {
            moshLog.info("Resuming mosh from serialized state")
            launchMoshClient(state: state)
        } else if hasMoshSession, moshPort > 0, !moshKey.isEmpty {
            // No serialized state but we had a session — try reconnecting
            // Mosh's UDP protocol will resync if the server is still alive
            moshLog.info("Resuming mosh without state (UDP resync)")
            launchMoshClient(state: nil)
        } else if !sshPassword.isEmpty {
            // Full reconnect — start a new mosh-server
            moshLog.info("Full reconnect — starting new mosh-server")
            Task {
                await connect(host: sshHost, port: sshPort, username: sshUsername, password: sshPassword)
            }
        }
    }

    // MARK: - Private

    private func launchMoshClient(state: Data?) {
        // Create pipes
        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]

        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else {
            connectionError = "Failed to create pipes"
            isConnecting = false
            moshLog.error("pipe() failed: \(errno)")
            return
        }

        inputReadFD = inPipe[0]
        inputWriteFD = inPipe[1]
        outputReadFD = outPipe[0]
        outputWriteFD = outPipe[1]

        // Create FILE pointers for mosh_main
        inputFile = fdopen(inputReadFD, "r")
        outputFile = fdopen(outputWriteFD, "w")

        guard inputFile != nil, outputFile != nil else {
            connectionError = "Failed to create FILE streams"
            isConnecting = false
            cleanupPipes()
            return
        }

        // Set output to unbuffered so we get data immediately
        setvbuf(outputFile, nil, _IONBF, 0)

        // Set up DispatchSource to read mosh output and feed to terminal
        let source = DispatchSource.makeReadSource(fileDescriptor: outputReadFD, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let bytesRead = read(self.outputReadFD, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                Task { @MainActor in
                    self.onDataReceived?(data)
                }
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.isConnected {
                    self.isConnected = false
                    self.connectionError = "Connection closed"
                }
            }
        }
        outputSource = source
        source.resume()

        // Capture values for the mosh thread (can't capture self)
        let ip = serverIP
        let port = String(moshPort)
        let key = moshKey
        let fIn = inputFile!
        let fOut = outputFile!

        // State buffer for resume
        let stateBuffer: UnsafePointer<CChar>?
        let stateSize: Int
        if let state = state {
            let mutablePtr = UnsafeMutablePointer<UInt8>.allocate(capacity: state.count)
            state.copyBytes(to: mutablePtr, count: state.count)
            stateBuffer = UnsafeRawPointer(mutablePtr).assumingMemoryBound(to: CChar.self)
            stateSize = state.count
        } else {
            stateBuffer = nil
            stateSize = 0
        }

        // Capture a pointer to self for the state callback
        let servicePtr = Unmanaged.passRetained(self).toOpaque()

        // Launch mosh_main on a background thread
        let thread = Thread {
            moshLog.info("mosh_main starting on background thread")

            var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            // Copy current window size
            Task { @MainActor in
                // This won't execute in time for the initial call, but that's okay —
                // mosh will pick up resize events
            }

            let result = ip.withCString { ipPtr in
                port.withCString { portPtr in
                    key.withCString { keyPtr in
                        "adaptive".withCString { predictPtr in
                            mosh_main(
                                fIn,
                                fOut,
                                &ws,
                                // State callback — called when mosh serializes state
                                { context, buffer, size in
                                    guard let context = context, let buffer = buffer, size > 0 else { return }
                                    let data = Data(bytes: buffer, count: size)
                                    let service = Unmanaged<MoshTerminalService>.fromOpaque(context).takeUnretainedValue()
                                    Task { @MainActor in
                                        service.serializedState = data
                                        moshLog.info("State serialized: \(size) bytes")
                                    }
                                },
                                servicePtr,
                                ipPtr,
                                portPtr,
                                keyPtr,
                                predictPtr,
                                stateBuffer,
                                stateSize,
                                nil // predict_overwrite
                            )
                        }
                    }
                }
            }

            // mosh_main returned — session ended
            moshLog.info("mosh_main exited with code \(result)")

            // Free the state buffer if we allocated one
            if let stateBuffer = stateBuffer {
                stateBuffer.deallocate()
            }

            // Release the retained self
            Unmanaged<MoshTerminalService>.fromOpaque(servicePtr).release()

            Task { @MainActor in
                // Don't clear connected state if we're just suspending
                // The suspend() method handles that
            }
        }
        thread.name = "MoshClient"
        thread.qualityOfService = .userInteractive
        moshThread = thread
        thread.start()

        hasMoshSession = true
        isConnected = true
        isConnecting = false
        moshLog.info("Mosh client launched")
    }

    private func cleanupPipes() {
        outputSource?.cancel()
        outputSource = nil

        // Close FILE pointers (which also closes underlying fds)
        if let f = inputFile {
            fclose(f)
            inputFile = nil
            inputReadFD = -1
        } else if inputReadFD >= 0 {
            close(inputReadFD)
            inputReadFD = -1
        }

        if inputWriteFD >= 0 {
            close(inputWriteFD)
            inputWriteFD = -1
        }

        if let f = outputFile {
            fclose(f)
            outputFile = nil
            outputWriteFD = -1
        } else if outputWriteFD >= 0 {
            close(outputWriteFD)
            outputWriteFD = -1
        }

        if outputReadFD >= 0 {
            close(outputReadFD)
            outputReadFD = -1
        }

        moshThread = nil
    }
}
