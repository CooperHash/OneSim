import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// A listener for one browser origin. Shared listeners require a per-session key
/// before joining the stream or receiving any simulator controls.
final class WebMultiSimServer: @unchecked Sendable {
    static let port = 8080
    static let address = URL(string: "http://127.0.0.1:\(port)")!
    let address: URL
    private var browserOrigin: URL?
    private let accessKey: String?
    private let onInput: @Sendable (UUID, WebInputCommand?) -> Void

    init(bindAddress: String = "127.0.0.1", port: Int = WebMultiSimServer.port,
         accessKey: String? = nil, onInput: @escaping @Sendable (UUID, WebInputCommand?) -> Void = { _, _ in }) {
        self.accessKey = accessKey
        self.onInput = onInput
        address = URL(string: "http://\(bindAddress):\(port)")!
        browserOrigin = address
    }

    convenience init(tunnelKey: String, onInput: @escaping @Sendable (UUID, WebInputCommand?) -> Void) {
        self.init(bindAddress: "127.0.0.1", port: 0, accessKey: tunnelKey, onInput: onInput)
        browserOrigin = nil
    }

    func acceptPublicOrigin(_ origin: URL) {
        guard address.port == 0, accessKey != nil, CloudflareQuickTunnel.origin(in: origin.absoluteString) == origin else { return }
        lock.withLock { if !stopped && browserOrigin == nil { browserOrigin = origin } }
    }

    var shareURL: URL {
        let origin = lock.withLock { browserOrigin } ?? address
        guard let accessKey else { return origin }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.fragment = "key=" + accessKey
        return components.url!
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: Channel] = [:]
    private struct Connection {
        let channel: Channel
        let acceptsVideo: Bool
    }
    private var viewers: [ObjectIdentifier: Connection] = [:]
    private var videoRequest: UInt64 = 0
    private var statuses: [Int: (WebDeviceStatus, Data)] = [:]
    private var frames: [UInt8: (revision: UInt32, bytes: Data, videoFallback: Bool)] = [:]
    private var listener: Channel?
    private var stopped = false

    @discardableResult
    func start() async throws -> Int {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 32_768, high: 131_072))
            .childChannelInitializer { [self] channel in
                guard self.registerConnection(channel),
                      let origin = self.lock.withLock({ self.browserOrigin }),
                      let hostname = origin.host else { return channel.close() }
                let host = hostname + (origin.port.map { ":\($0)" } ?? "")
                let webSocketOrigin = (origin.scheme == "https" ? "wss://" : "ws://") + host
                let http = HTTPPage(host: host, webSocketOrigin: webSocketOrigin, requiresKey: self.accessKey != nil)
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 4096,
                    shouldUpgrade: { channel, request in
                        let protocols = request.headers["sec-websocket-protocol"]
                            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                        guard request.uri == "/stream",
                              request.headers["host"] == [host],
                              request.headers["origin"] == [origin.absoluteString],
                              self.accessKey.map({ protocols.contains("key." + $0) && protocols.contains("simlab") }) ?? true
                        else { return channel.eventLoop.makeSucceededFuture(nil) }
                        let headers = protocols.contains("simlab")
                            ? HTTPHeaders([("Sec-WebSocket-Protocol", "simlab")]) : HTTPHeaders()
                        return channel.eventLoop.makeSucceededFuture(headers)
                    },
                    upgradePipelineHandler: { [self] channel, request in
                        let acceptsVideo = request.headers["sec-websocket-protocol"].contains(where: {
                            $0.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "simlab.avc" }
                        })
                        return channel.pipeline.addHandler(Viewer(onInput: self.onInput, requestKeyFrame: { [weak self] in
                            self?.lock.withLock { self?.videoRequest &+= 1 }
                        }, replay: { [weak self] channel in
                            self?.replay(on: channel, recovering: true)
                        })).flatMap {
                            guard self.registerViewer(channel, acceptsVideo: acceptsVideo) else { return channel.close() }
                            self.replay(on: channel, recovering: false)
                            return channel.eventLoop.makeSucceededFuture(())
                        }
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (
                    upgraders: [upgrader],
                    completionHandler: { context in _ = context.pipeline.removeHandler(http) }
                )).flatMap { channel.pipeline.addHandler(http) }
            }
            .bind(host: address.host!, port: address.port!).get()
        guard let port = channel.localAddress?.port, storeListener(channel) else {
            channel.close(promise: nil)
            throw CancellationError()
        }
        return port
    }

    var hasViewers: Bool {
        lock.withLock { !viewers.isEmpty }
    }

    var demand: (jpeg: Bool, videoRequest: UInt64?) {
        lock.withLock {
            (viewers.values.contains { !$0.acceptsVideo },
             viewers.values.contains { $0.acceptsVideo } ? videoRequest : nil)
        }
    }

    func publish(_ status: WebDeviceStatus) {
        guard let payload = try? JSONEncoder().encode(status) else { return }
        let channels = lock.withLock {
            let index = UInt8(status.panel)
            if frames[index]?.revision != (status.revision ?? 0) { frames[index] = nil }
            statuses[status.panel] = (status, payload)
            return viewers.values.map(\.channel)
        }
        for channel in channels { Self.send(payload, opcode: .text, to: channel) }
    }

    func publish(_ image: Data, panel: UInt8, revision: UInt32, videoFallback: Bool = false) {
        var frame = Data([panel])
        withUnsafeBytes(of: revision.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(image)
        let channels = lock.withLock {
            frames[panel] = (revision, frame, videoFallback)
            return viewers.values.filter { !$0.acceptsVideo || videoFallback }.map(\.channel)
        }
        for channel in channels { Self.send(frame, opcode: .binary, to: channel) }
    }

    func publishVideo(_ value: WebH264Encoder.Frame, panel: UInt8, revision: UInt32) {
        var frame = Data([panel | 0x80])
        withUnsafeBytes(of: revision.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(value.isKey ? 1 : 0)
        withUnsafeBytes(of: value.sequence.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(value.bytes)
        let channels = lock.withLock { viewers.values.filter(\.acceptsVideo).map(\.channel) }
        for channel in channels { Self.send(frame, opcode: .binary, to: channel) }
    }

    private func replay(on channel: Channel, recovering: Bool) {
        let (states, images) = lock.withLock {
            let acceptsVideo = viewers[ObjectIdentifier(channel)]?.acceptsVideo == true
            if acceptsVideo && recovering { videoRequest &+= 1 }
            return (statuses.values.map { $0.1 },
                    frames.values.filter { !acceptsVideo || $0.videoFallback }.map(\.bytes))
        }
        for state in states { Self.send(state, opcode: .text, to: channel) }
        for image in images { Self.send(image, opcode: .binary, to: channel) }
    }

    private static func send(_ bytes: Data, opcode: WebSocketOpcode, to channel: Channel) {
        let write: @Sendable () -> Void = {
            guard channel.isActive, channel.isWritable else { return }
            var data = channel.allocator.buffer(capacity: bytes.count)
            data.writeBytes(bytes)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: opcode, data: data), promise: nil)
        }
        if channel.eventLoop.inEventLoop { write() } else { channel.eventLoop.execute(write) }
    }

    func stop() {
        let channels: [Channel]? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            let channels = Array(connections.values) + [listener].compactMap { $0 }
            connections.removeAll()
            viewers.removeAll()
            statuses.removeAll()
            frames.removeAll()
            listener = nil
            return channels
        }
        guard let channels else { return }
        for channel in channels { channel.close(promise: nil) }
        group.shutdownGracefully { _ in }
    }

    private func storeListener(_ channel: Channel) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            listener = channel
            return true
        }
    }

    private func registerConnection(_ channel: Channel) -> Bool {
        let id = ObjectIdentifier(channel)
        let registered = lock.withLock {
            guard !stopped else { return false }
            connections[id] = channel
            return true
        }
        if registered {
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                lock.withLock {
                    self.connections[id] = nil
                    self.viewers[id] = nil
                }
            }
        }
        return registered
    }

    private func registerViewer(_ channel: Channel, acceptsVideo: Bool) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            viewers[ObjectIdentifier(channel)] = Connection(channel: channel, acceptsVideo: acceptsVideo)
            if acceptsVideo { videoRequest &+= 1 }
            return true
        }
    }

    private final class Viewer: ChannelInboundHandler {
        typealias InboundIn = WebSocketFrame
        typealias OutboundOut = WebSocketFrame
        private let id = UUID()
        private let onInput: @Sendable (UUID, WebInputCommand?) -> Void
        private let requestKeyFrame: @Sendable () -> Void
        private let replay: @Sendable (Channel) -> Void
        private var rateWindow = ContinuousClock.now
        private var received = 0

        init(onInput: @escaping @Sendable (UUID, WebInputCommand?) -> Void,
             requestKeyFrame: @escaping @Sendable () -> Void,
             replay: @escaping @Sendable (Channel) -> Void) {
            self.onInput = onInput
            self.requestKeyFrame = requestKeyFrame
            self.replay = replay
        }

        func channelWritabilityChanged(context: ChannelHandlerContext) {
            if context.channel.isWritable {
                let channel = context.channel
                channel.eventLoop.execute { [replay] in replay(channel) }
            }
            context.fireChannelWritabilityChanged()
        }

        func channelInactive(context: ChannelHandlerContext) {
            onInput(id, nil)
            context.fireChannelInactive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            switch frame.opcode {
            case .connectionClose:
                let reply = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
                context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in context.close(promise: nil) }
            case .ping:
                context.writeAndFlush(wrapOutboundOut(.init(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
            case .text:
                if ContinuousClock.now - rateWindow >= .seconds(1) {
                    rateWindow = .now
                    received = 0
                }
                received += 1
                guard received <= 240 else {
                    context.close(promise: nil)
                    return
                }
                guard frame.fin, frame.maskKey != nil,
                      let command = try? JSONDecoder().decode(WebInputCommand.self, from: Data(frame.unmaskedData.readableBytesView)),
                      command.isValid else { return }
                if command.action == .refreshVideo {
                    requestKeyFrame()
                } else {
                    onInput(id, command)
                }
            default: break
            }
        }
    }

    private final class HTTPPage: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        private let host: String
        private let requiresKey: Bool
        private let webSocketOrigin: String

        init(host: String, webSocketOrigin: String, requiresKey: Bool) {
            self.host = host
            self.webSocketOrigin = webSocketOrigin
            self.requiresKey = requiresKey
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .head(let request) = unwrapInboundIn(data) else { return }
            let resource = request.headers["host"] == [host] && request.method == .GET
                ? WebResources.resource(request.uri, requiresKey: requiresKey) : nil
            let status: HTTPResponseStatus = resource == nil ? .notFound : .ok
            let (content, type) = resource ?? (Data("Not found".utf8), "text/plain")
            let headers = HTTPHeaders([
                ("Content-Type", type), ("Content-Length", String(content.count)),
                ("Connection", "close"), ("Cache-Control", request.uri.hasPrefix("/assets/") ? "private, max-age=86400" : "no-store"),
                ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
                ("Content-Security-Policy", "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' blob:; connect-src 'self' blob: \(webSocketOrigin); form-action 'none'; frame-ancestors 'none'"),
            ])
            context.write(wrapOutboundOut(.head(.init(version: request.version, status: status, headers: headers))), promise: nil)
            var body = context.channel.allocator.buffer(capacity: content.count)
            body.writeBytes(content)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }
    }
}
