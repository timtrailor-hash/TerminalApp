import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os

private let sshLog = Logger(subsystem: "com.timtrailor.terminal", category: "ssh")

// MARK: - Host Key Validation (accept all — trusted LAN)

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
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

        guard case .byteBuffer(let buffer) = payload.data else { return }
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

private enum SSHConnectionError: Error {
    case invalidChannelType
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
        self.onData = onData
        self.onConnected = onConnected
        self.onError = onError
        self.onDisconnect = onDisconnect
    }

    private var keepaliveTask: RepeatedTask?

    func connect() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let serverAuthDelegate = AcceptAllHostKeysDelegate()
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
        sessionChannel.eventLoop.execute {
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
        // Send an SSH channel data keepalive every 15 seconds to prevent idle timeout
        keepaliveTask = channel.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(15),
            delay: .seconds(15)
        ) { [weak self] _ in
            guard let self, let sc = self.sessionChannel else { return }
            // Send empty ignore data — keeps the connection alive without affecting the shell
            var buffer = sc.allocator.buffer(capacity: 0)
            // Write nothing — just flush to keep TCP alive
            sc.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        }
        sshLog.info("SSH keepalive started (15s interval)")
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
                        let handler = ShellChannelHandler(
                            term: "xterm-256color",
                            environment: ["LANG": "en_US.UTF-8"],
                            initialCols: self.initialCols,
                            initialRows: self.initialRows,
                            onData: self.onData,
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
                        // Start keepalive — send a zero-length NOP every 15s to prevent idle disconnect
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
            group.shutdownGracefully { _ in }
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
                    self?.connectionError = "Disconnected"
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
