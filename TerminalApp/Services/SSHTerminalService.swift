import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os

private let sshLog = Logger(subsystem: "com.timtrailor.terminal", category: "ssh")

// MARK: - Host Key Storage (Keychain)

enum HostKeyStore {
    private static let service = "com.timtrailor.terminal.hostkeys"

    @discardableResult
    static func save(host: String, key: String) -> Bool {
        let account = host
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            sshLog.error("Failed to save host key for \(account): OSStatus \(status)")
            return false
        }
        return true
    }

    static func load(host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        let udKey = "SSHHostKey.\(host)"
        if let legacy = UserDefaults.standard.string(forKey: udKey) {
            sshLog.info("Migrating host key for \(host) from UserDefaults to Keychain")
            if save(host: host, key: legacy) {
                UserDefaults.standard.removeObject(forKey: udKey)
            } else {
                sshLog.warning("Keychain migration failed for \(host), keeping UserDefaults entry")
            }
            return legacy
        }
        return nil
    }

    static func clear(host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "SSHHostKey.\(host)")
        sshLog.info("Cleared pinned host key for \(host)")
    }

    @discardableResult
    static func clearAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            sshLog.info("Cleared all pinned host keys")
            return true
        }
        sshLog.error("Failed to clear host keys: OSStatus \(status)")
        return false
    }
}

enum CredentialStore {
    private static let service = "com.timtrailor.terminal.credentials"

    static func savePassword(_ password: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "sshPassword",
        ]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadPassword() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "sshPassword",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let pw = String(data: data, encoding: .utf8) {
            return pw
        }
        if let legacy = UserDefaults.standard.string(forKey: "sshPassword"), !legacy.isEmpty {
            sshLog.info("Migrating SSH password from UserDefaults to Keychain")
            savePassword(legacy)
            UserDefaults.standard.removeObject(forKey: "sshPassword")
            return legacy
        }
        return ""
    }
}

// MARK: - Host Key Validation (trust-on-first-use)

final class TOFUHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let host: String

    init(host: String) {
        self.host = host
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let hostName = self.host
        let keyString = String(openSSHPublicKey: hostKey)
        let eventLoop = validationCompletePromise.futureResult.eventLoop

        DispatchQueue.global(qos: .userInitiated).async {
            if let saved = HostKeyStore.load(host: hostName) {
                if saved == keyString {
                    eventLoop.execute { validationCompletePromise.succeed(()) }
                } else {
                    sshLog.error("Host key mismatch for \(hostName) — possible MITM. Saved key differs from presented key.")
                    eventLoop.execute { validationCompletePromise.fail(SSHHostKeyError.mismatch(host: hostName)) }
                }
            } else {
                sshLog.info("First connection to \(hostName) — pinning host key")
                if HostKeyStore.save(host: hostName, key: keyString) {
                    eventLoop.execute { validationCompletePromise.succeed(()) }
                } else {
                    eventLoop.execute { validationCompletePromise.fail(SSHHostKeyError.keychainWriteFailed(host: hostName)) }
                }
            }
        }
    }
}

enum SSHHostKeyError: Error, LocalizedError {
    case mismatch(host: String)
    case keychainWriteFailed(host: String)

    var errorDescription: String? {
        switch self {
        case .mismatch(let host):
            return "Host key for \(host) changed. This may indicate a man-in-the-middle attack or a server rebuild. Verify the change, then clear the pinned key in Settings to reconnect."
        case .keychainWriteFailed(let host):
            return "Failed to save host key for \(host) to Keychain."
        }
    }
}

// MARK: - SSH Error Handler

private final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: @Sendable (Error) -> Void

    init(onError: @escaping @Sendable (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

// MARK: - Shell Channel Handler (with shell-ready fix)

/// Handles SSH channel data for a PTY shell session.
/// Feeds received bytes back to SwiftTerm via the onData callback.
///
/// BUG FIX: Uses ChannelSuccessEvent to detect when the shell is actually ready,
/// instead of signaling connected on channel creation. This prevents the race condition
/// where channelInactive fires before the shell is established.
private final class ShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let term: String
    private let environment: [String: String]
    private let initialCols: Int
    private let initialRows: Int
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void
    private let onReady: @Sendable () -> Void

    /// Tracks whether the server has confirmed the shell is ready
    private var shellReady = false

    init(
        term: String,
        environment: [String: String],
        initialCols: Int,
        initialRows: Int,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void
    ) {
        self.term = term
        self.environment = environment
        self.initialCols = initialCols
        self.initialRows = initialRows
        self.onData = onData
        self.onClose = onClose
        self.onReady = onReady
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        // Request PTY
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: term,
            terminalCharacterWidth: initialCols,
            terminalRowHeight: initialRows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)

        // Set environment
        for (name, value) in environment {
            let env = SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)
            context.triggerUserOutboundEvent(env, promise: nil)
        }

        // Request shell — wantReply: true so server sends ChannelSuccessEvent when ready
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)

        guard case .byteBuffer(var buffer) = payload.data else { return }
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }

        onData(Data(bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            // Server confirmed shell request succeeded — NOW we're truly connected
            if !shellReady {
                shellReady = true
                sshLog.info("Shell ready (ChannelSuccessEvent received)")
                onReady()
            }
        } else if event is SSHChannelRequestEvent.ExitStatus {
            onClose()
        } else if event is SSHChannelRequestEvent.ExitSignal {
            onClose()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Only signal disconnect if the shell was actually established
        // This prevents the premature disconnect race condition
        guard shellReady else {
            sshLog.info("channelInactive before shell ready — ignoring")
            return
        }
        onClose()
    }
}

// MARK: - SSH Connection (NIO event loop managed)

private enum SSHConnectionError: Error, LocalizedError {
    case invalidChannelType
    case keepaliveWriteFailed(underlying: Error)
    case idleReadTimeout(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .invalidChannelType:
            return "SSH channel is not a session"
        case .keepaliveWriteFailed(let underlying):
            return "SSH keepalive write failed: \(underlying.localizedDescription)"
        case .idleReadTimeout(let seconds):
            return "SSH connection idle: no data received in \(seconds)s"
        }
    }
}

/// Manages the NIO SSH connection lifecycle.
/// Runs on NIO event loops — not MainActor-bound.
private final class SSHConnection {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let initialCols: Int
    private let initialRows: Int
    private let onData: @Sendable (Data) -> Void
    private let onConnected: @Sendable () -> Void
    private let onError: @Sendable (Error) -> Void
    private let onDisconnect: @Sendable () -> Void

    private var group: EventLoopGroup?
    private var channel: Channel?
    private var sessionChannel: Channel?

    init(
        host: String,
        port: Int,
        username: String,
        password: String,
        initialCols: Int = 80,
        initialRows: Int = 24,
        onData: @escaping @Sendable (Data) -> Void,
        onConnected: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.initialCols = initialCols
        self.initialRows = initialRows
        self.lastCols = initialCols
        self.lastRows = initialRows
        self.onData = onData
        self.onConnected = onConnected
        self.onError = onError
        self.onDisconnect = onDisconnect
    }

    private var keepaliveTask: RepeatedTask?
    private var lastCols: Int
    private var lastRows: Int

    /// Updated on every inbound channel read AND on every successful keepalive
    /// write. Used by the keepalive watchdog to detect a wedged SSH session
    /// (TCP alive but neither side making progress). All reads/writes happen
    /// on the session childChannel's eventLoop; the data path asserts this
    /// invariant rather than rely on a comment.
    private var lastReadAt: NIODeadline = .now()

    /// If no inbound bytes arrive for this long AND no keepalive write
    /// succeeds either, treat the session as wedged. The window-change
    /// keepalive elicits no application-layer reply on a healthy idle PTY,
    /// so we treat a successful write as evidence of liveness — the
    /// watchdog only fires when both writes and reads stall.
    private let idleReadTimeoutSeconds: Int = 300

    func connect() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let serverAuthDelegate = TOFUHostKeysDelegate(host: host)
        let userAuthDelegate = SimplePasswordDelegate(username: username, password: password)

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let self else { return }
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: userAuthDelegate,
                                serverAuthDelegate: serverAuthDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHErrorHandler { [weak self] error in
                            self?.handleError(error)
                        }
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .connectTimeout(.seconds(15))

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleError(error)
                self.shutdownGroup()
            case .success(let channel):
                self.channel = channel
                self.createSessionChannel(on: channel)
            }
        }
    }

    func send(_ data: Data) {
        guard let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            var buffer = sessionChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            sessionChannel.writeAndFlush(payload, promise: nil)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let sessionChannel else { return }
        sessionChannel.eventLoop.execute { [weak self] in
            guard let self else { return }
            self.lastCols = cols
            self.lastRows = rows
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
            sessionChannel.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    func disconnect() {
        stopKeepalive()
        if let channel, group != nil {
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.shutdownGroup()
            }
            channel.close(promise: nil)
        } else {
            shutdownGroup()
        }
        sessionChannel = nil
        channel = nil
    }

    private func startKeepalive(on channel: Channel) {
        stopKeepalive()
        // Reset the read watchdog so a stale value from a previous session
        // can't immediately trip the timeout on a fresh connection.
        lastReadAt = .now()
        // Every 15s, resend the current window size as a SSH channel request.
        // On macOS/Darwin servers, the kernel's TIOCSWINSZ handler (tty_ioctl.c)
        // does a bcmp before pgsignal, so same-dimension requests are true
        // no-ops at the PTY layer (no SIGWINCH). NOTE: Linux kernels do NOT have
        // this guard and WILL deliver SIGWINCH on every same-size request, so
        // this keepalive is only safe for the Mac Mini (Darwin) target. If the
        // app ever connects to Linux SSH servers, switch to a different
        // keepalive mechanism.
        //
        // SO_KEEPALIVE on the socket is set as a secondary defence but its
        // default interval (~2h) is too long for carrier-grade NAT timeouts.
        //
        // Fail-fast detection has two layers:
        //   1. The window-change write uses a promise. A write failure (channel
        //      closed, broken pipe) immediately surfaces as a typed
        //      `keepaliveWriteFailed` error.
        //   2. The watchdog checks `lastReadAt`. A successful write also
        //      counts as liveness (a healthy idle PTY does not echo bytes back
        //      for window-change requests), so the watchdog only fires when
        //      BOTH writes and reads have stopped progressing — the wedged-
        //      TCP scenario where the kernel happily accepts our writes but
        //      nothing flows back.
        keepaliveTask = channel.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(15),
            delay: .seconds(15)
        ) { [weak self] _ in
            guard let self, let sc = self.sessionChannel else { return }

            let silentFor = NIODeadline.now() - self.lastReadAt
            if silentFor > .seconds(Int64(self.idleReadTimeoutSeconds)) {
                let timeout = self.idleReadTimeoutSeconds
                sshLog.error("SSH idle-read watchdog tripped: no progress in \(timeout)s")
                self.handleError(SSHConnectionError.idleReadTimeout(seconds: timeout))
                sc.close(promise: nil)
                return
            }

            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: self.lastCols,
                terminalRowHeight: self.lastRows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
            let writePromise = sc.eventLoop.makePromise(of: Void.self)
            sc.triggerUserOutboundEvent(event, promise: writePromise)
            writePromise.futureResult.whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    // A successful write proves the SSH/TCP path is alive in
                    // the outbound direction. Count it as liveness so the
                    // watchdog does not trip on a healthy idle session where
                    // the server simply has nothing to send.
                    self.lastReadAt = .now()
                case .failure(let error):
                    sshLog.error("SSH keepalive write failed: \(error)")
                    self.handleError(SSHConnectionError.keepaliveWriteFailed(underlying: error))
                    self.sessionChannel?.close(promise: nil)
                }
            }
        }
        sshLog.info("SSH keepalive started (15s window-change, \(self.idleReadTimeoutSeconds)s idle-read watchdog)")
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: - Private

    private func createSessionChannel(on channel: Channel) {
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleError(error)
            case .success(let sshHandler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { [weak self] childChannel, channelType in
                    guard let self else {
                        return channel.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
                    }

                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
                    }

                    return childChannel.eventLoop.makeCompletedFuture {
                        // Wrap onData so every inbound chunk also touches the
                        // idle-read watchdog. ShellChannelHandler.channelRead
                        // delivers data on the session childChannel's
                        // eventLoop — the same loop the keepalive runs on, so
                        // `lastReadAt` is single-writer. Assert the invariant
                        // explicitly rather than rely on a comment.
                        let upstreamOnData = self.onData
                        let watchdogLoop = childChannel.eventLoop
                        let onDataWithTouch: @Sendable (Data) -> Void = { [weak self] data in
                            watchdogLoop.assertInEventLoop()
                            self?.lastReadAt = .now()
                            upstreamOnData(data)
                        }
                        let handler = ShellChannelHandler(
                            term: "xterm-256color",
                            environment: ["LANG": "en_US.UTF-8"],
                            initialCols: self.initialCols,
                            initialRows: self.initialRows,
                            onData: onDataWithTouch,
                            onClose: self.onDisconnect,
                            onReady: self.onConnected  // BUG FIX: onConnected wired to onReady
                        )
                        try childChannel.pipeline.syncOperations.addHandler(handler)
                        try childChannel.pipeline.syncOperations.addHandler(
                            SSHErrorHandler { [weak self] error in
                                self?.handleError(error)
                            }
                        )
                    }
                }

                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.handleError(error)
                    case .success(let childChannel):
                        self.sessionChannel = childChannel
                        // BUG FIX: Do NOT call onConnected here — wait for ChannelSuccessEvent
                        sshLog.info("SSH session channel created, waiting for shell ready...")
                        // Start keepalive: 15s window-change request to keep
                        // NAT warm, plus a 5-min idle-read watchdog and a
                        // write-failure detector for fail-fast on dead
                        // sessions (typed errors via SSHConnectionError).
                        self.startKeepalive(on: childChannel)
                    }
                }
            }
        }
    }

    private func handleError(_ error: Error) {
        sshLog.error("SSH error: \(error)")
        onError(error)
    }

    private func shutdownGroup() {
        if let group {
            self.group = nil
            group.shutdownGracefully { error in
                if let error {
                    sshLog.error("NIO event loop group shutdown error: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - SSH Terminal Service (MainActor)

/// Manages an SSH connection to the Mac Mini with a PTY shell session.
/// Bridges SSH I/O to SwiftTerm's terminal emulator.
@MainActor
final class SSHTerminalService: ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectionError: String?

    private var connection: SSHConnection?

    /// Callback for data received from the remote shell — wired to SwiftTerm's feed()
    var onDataReceived: ((Data) -> Void)?

    /// Connect to the Mac Mini via SSH and start a shell
    func connect(host: String, port: Int = 22, username: String, password: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = nil

        sshLog.info("Connecting to \(host):\(port) as \(username)")

        let conn = SSHConnection(
            host: host,
            port: port,
            username: username,
            password: password,
            onData: { [weak self] data in
                Task { @MainActor in
                    self?.onDataReceived?(data)
                }
            },
            onConnected: { [weak self] in
                Task { @MainActor in
                    self?.isConnected = true
                    self?.isConnecting = false
                    sshLog.info("Shell session established")
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.connectionError = error.localizedDescription
                    if self?.isConnecting == true {
                        self?.isConnecting = false
                    }
                    if self?.isConnected == true {
                        self?.isConnected = false
                    }
                }
            },
            onDisconnect: { [weak self] in
                Task { @MainActor in
                    self?.isConnected = false
                    // Don't overwrite a typed error from `onError` (which is
                    // enqueued just before this `onDisconnect` whenever the
                    // close was triggered by the keepalive watchdog or write
                    // failure). Only stamp the generic "Disconnected" string
                    // when no typed error has surfaced.
                    if self?.connectionError == nil {
                        self?.connectionError = "Disconnected"
                    }
                    sshLog.info("Session ended")
                }
            }
        )
        self.connection = conn
        conn.connect()
    }

    /// Send user input to the remote shell
    func send(_ data: Data) {
        connection?.send(data)
    }

    /// Send a string to the remote shell
    func sendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            send(data)
        }
    }

    /// Resize the PTY
    func resize(cols: Int, rows: Int) {
        connection?.resize(cols: cols, rows: rows)
    }

    /// Disconnect from the remote host
    func disconnect() {
        connection?.disconnect()
        connection = nil
        isConnected = false
        isConnecting = false
        sshLog.info("Disconnected")
    }
}
