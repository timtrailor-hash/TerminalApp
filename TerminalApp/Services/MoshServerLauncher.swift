import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os

private let launcherLog = Logger(subsystem: "com.timtrailor.terminal", category: "moshLauncher")

/// Result of starting mosh-server on the remote host
struct MoshServerInfo {
    let port: UInt16
    let key: String
}

// MARK: - Exec Channel Handler

/// Runs a single command over SSH exec channel and collects stdout.
private final class ExecChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let onData: @Sendable (Data) -> Void
    private let onComplete: @Sendable () -> Void

    init(command: String, onData: @escaping @Sendable (Data) -> Void, onComplete: @escaping @Sendable () -> Void) {
        self.command = command
        self.onData = onData
        self.onComplete = onComplete
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data else { return }
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        onData(Data(bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ExitStatus || event is SSHChannelRequestEvent.ExitSignal {
            onComplete()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onComplete()
    }
}

// MARK: - Error Handler

private final class LauncherErrorHandler: ChannelInboundHandler {
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

// MARK: - MoshServerLauncher

enum MoshServerLauncherError: Error, LocalizedError {
    case connectionFailed(String)
    case parseFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "SSH connection failed: \(msg)"
        case .parseFailed(let output): return "Failed to parse mosh-server output: \(output)"
        case .timeout: return "Timed out waiting for mosh-server"
        }
    }
}

/// Launches mosh-server on a remote host via SSH exec channel,
/// parses the MOSH CONNECT response, and returns connection info.
struct MoshServerLauncher {
    let host: String
    let port: Int
    let username: String
    let password: String

    /// Start mosh-server on the remote host and return connection info.
    func launch() async throws -> MoshServerInfo {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let resumeOnce: (Result<MoshServerInfo, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            var collectedOutput = Data()
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

            let serverAuthDelegate = AcceptAllHostKeysDelegate()
            let userAuthDelegate = SimplePasswordDelegate(username: username, password: password)

            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
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
                            LauncherErrorHandler { error in
                                resumeOnce(.failure(MoshServerLauncherError.connectionFailed(error.localizedDescription)))
                            }
                        )
                    }
                }
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .connectTimeout(.seconds(15))

            bootstrap.connect(host: host, port: port).whenComplete { result in
                switch result {
                case .failure(let error):
                    group.shutdownGracefully { _ in }
                    resumeOnce(.failure(MoshServerLauncherError.connectionFailed(error.localizedDescription)))

                case .success(let channel):
                    channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { sshResult in
                        switch sshResult {
                        case .failure(let error):
                            channel.close(promise: nil)
                            group.shutdownGracefully { _ in }
                            resumeOnce(.failure(error))

                        case .success(let sshHandler):
                            let promise = channel.eventLoop.makePromise(of: Channel.self)
                            sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                                guard channelType == .session else {
                                    return channel.eventLoop.makeFailedFuture(MoshServerLauncherError.connectionFailed("Invalid channel type"))
                                }

                                return childChannel.eventLoop.makeCompletedFuture {
                                    let moshServerCmd = "/opt/homebrew/bin/mosh-server new -s -c 256 -l LANG=en_US.UTF-8"
                                    let handler = ExecChannelHandler(
                                        command: moshServerCmd,
                                        onData: { data in
                                            collectedOutput.append(data)
                                            // Try parsing as soon as we get data
                                            if let info = Self.parseMoshConnect(from: collectedOutput) {
                                                launcherLog.info("mosh-server started on port \(info.port)")
                                                channel.close(promise: nil)
                                                group.shutdownGracefully { _ in }
                                                resumeOnce(.success(info))
                                            }
                                        },
                                        onComplete: {
                                            // If we haven't parsed yet, try one last time
                                            if let info = Self.parseMoshConnect(from: collectedOutput) {
                                                channel.close(promise: nil)
                                                group.shutdownGracefully { _ in }
                                                resumeOnce(.success(info))
                                            } else {
                                                let output = String(data: collectedOutput, encoding: .utf8) ?? "(binary)"
                                                channel.close(promise: nil)
                                                group.shutdownGracefully { _ in }
                                                resumeOnce(.failure(MoshServerLauncherError.parseFailed(output)))
                                            }
                                        }
                                    )
                                    try childChannel.pipeline.syncOperations.addHandler(handler)
                                    try childChannel.pipeline.syncOperations.addHandler(
                                        LauncherErrorHandler { error in
                                            channel.close(promise: nil)
                                            group.shutdownGracefully { _ in }
                                            resumeOnce(.failure(error))
                                        }
                                    )
                                }
                            }

                            promise.futureResult.whenFailure { error in
                                channel.close(promise: nil)
                                group.shutdownGracefully { _ in }
                                resumeOnce(.failure(error))
                            }
                        }
                    }
                }
            }

            // Timeout after 20 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                group.shutdownGracefully { _ in }
                resumeOnce(.failure(MoshServerLauncherError.timeout))
            }
        }
    }

    /// Parse "MOSH CONNECT <port> <key>" from mosh-server stdout
    static func parseMoshConnect(from data: Data) -> MoshServerInfo? {
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        // mosh-server outputs: MOSH CONNECT <port> <key>
        let pattern = #"MOSH CONNECT (\d+) (\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let portRange = Range(match.range(at: 1), in: output),
              let keyRange = Range(match.range(at: 2), in: output),
              let port = UInt16(output[portRange]) else {
            return nil
        }
        return MoshServerInfo(port: port, key: String(output[keyRange]))
    }
}

// Reuse from SSHTerminalService — accept all host keys on trusted LAN
private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}
