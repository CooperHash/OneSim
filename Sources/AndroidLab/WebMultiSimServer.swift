import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// The listener and WebSocket upgrade are confined to this Mac. Checking both
/// Host and Origin keeps another website from reading the simulator displays.
final class WebMultiSimServer: @unchecked Sendable {
    static let port = 8080
    static let address = URL(string: "http://127.0.0.1:\(port)")!
    private static let host = "127.0.0.1:\(port)"

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: Channel] = [:]
    private var viewers: [ObjectIdentifier: Channel] = [:]
    private var listener: Channel?
    private var stopped = false

    func start() async throws {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 128_000, high: 512_000))
            .childChannelInitializer { channel in
                guard self.register(channel, viewer: false) else { return channel.close() }
                let http = HTTPPage()
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 4096,
                    shouldUpgrade: { channel, request in
                        let allowed = request.uri == "/stream" &&
                            request.headers["host"] == [Self.host] &&
                            request.headers["origin"] == [Self.address.absoluteString]
                        return channel.eventLoop.makeSucceededFuture(allowed ? HTTPHeaders() : nil)
                    },
                    upgradePipelineHandler: { channel, _ in
                        guard self.register(channel, viewer: true) else { return channel.close() }
                        return channel.pipeline.addHandler(Viewer())
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (
                    upgraders: [upgrader],
                    completionHandler: { context in _ = context.pipeline.removeHandler(http) }
                )).flatMap { channel.pipeline.addHandler(http) }
            }
            .bind(host: "127.0.0.1", port: Self.port).get()
        if !storeListener(channel) {
            channel.close(promise: nil)
            throw CancellationError()
        }
    }

    var hasViewers: Bool {
        lock.withLock { !viewers.isEmpty }
    }

    func publish(_ image: Data, panel: UInt8) {
        let channels = lock.withLock { Array(viewers.values) }
        for channel in channels {
            channel.eventLoop.execute {
                guard channel.isActive, channel.isWritable else { return }
                var data = channel.allocator.buffer(capacity: image.count + 1)
                data.writeInteger(panel)
                data.writeBytes(image)
                channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: data), promise: nil)
            }
        }
    }

    func stop() {
        let channels: [Channel]? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            let channels = Array(connections.values) + [listener].compactMap { $0 }
            connections.removeAll()
            viewers.removeAll()
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

    private func register(_ channel: Channel, viewer: Bool) -> Bool {
        let id = ObjectIdentifier(channel)
        let registered = lock.withLock {
            guard !stopped else { return false }
            if viewer { viewers[id] = channel } else { connections[id] = channel }
            return true
        }
        if registered && !viewer {
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

    private final class Viewer: ChannelInboundHandler {
        typealias InboundIn = WebSocketFrame
        typealias OutboundOut = WebSocketFrame

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            switch frame.opcode {
            case .connectionClose:
                let reply = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
                context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in context.close(promise: nil) }
            case .ping:
                context.writeAndFlush(wrapOutboundOut(.init(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
            default: break
            }
        }
    }

    private final class HTTPPage: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .head(let request) = unwrapInboundIn(data) else { return }
            let status: HTTPResponseStatus
            let type: String
            let text: String
            switch (request.headers["host"] == [WebMultiSimServer.host], request.method, request.uri) {
            case (true, .GET, "/"): (status, type, text) = (.ok, "text/html; charset=utf-8", Self.html)
            case (true, .GET, "/app.js"): (status, type, text) = (.ok, "application/javascript", Self.javaScript)
            default: (status, type, text) = (.notFound, "text/plain", "Not found")
            }
            let headers = HTTPHeaders([
                ("Content-Type", type), ("Content-Length", String(text.utf8.count)),
                ("Connection", "close"), ("Cache-Control", "no-store"),
                ("X-Content-Type-Options", "nosniff"),
                ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src blob:; connect-src ws://127.0.0.1:8080; frame-ancestors 'none'"),
            ])
            context.write(wrapOutboundOut(.head(.init(version: request.version, status: status, headers: headers))), promise: nil)
            var body = context.channel.allocator.buffer(capacity: text.utf8.count)
            body.writeString(text)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }

        static let html = """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Web MultiSim</title>
        <style>
        :root{color-scheme:light dark;font:16px system-ui;background:Canvas;color:CanvasText}
        body{margin:0;padding:24px}header{display:flex;align-items:center;justify-content:space-between;gap:16px}
        h1{font-size:1.3rem;margin:0}h2{font-size:.875rem;margin:0 0 10px}
        #status{font-size:.8rem;color:GrayText}main{display:flex;overflow-x:auto;align-items:flex-start;gap:16px;padding:12px 0}
        section{border:1px solid GrayText;border-radius:14px;padding:12px;min-width:240px}
        img{display:block;max-height:78vh;object-fit:contain;max-width:680px;border-radius:10px;background:#151519}
        img:not([src]){height: min(540px,70vh);width:240px}
        </style><header><h1>Web MultiSim</h1><span id="status" role="status">Connecting…</span></header>
        <main><section><h2>Android</h2><img alt="Android live display"></section>
        <section><h2>iPhone 16 Pro</h2><img alt="iPhone 16 Pro live display"></section>
        <section><h2>iPhone Duo</h2><img alt="iPhone Duo live display"></section></main><script src="/app.js"></script></html>
        """

        static let javaScript = """
        const screens = Array.from(document.images);
        const status = document.getElementById('status');
        const ws = new WebSocket('ws://' + location.host + '/stream');
        ws.binaryType = 'arraybuffer';
        ws.onopen = () => status.textContent = 'Live on this Mac';
        ws.onclose = () => status.textContent = 'Disconnected. Reload after starting Web MultiSim.';
        ws.onmessage = ({data}) => {
          const slot = screens[new Uint8Array(data, 0, 1)[0]];
          if (!slot) return;
          const old = slot.getAttribute('src');
          slot.src = URL.createObjectURL(new Blob([data.slice(1)], {type:'image/jpeg'}));
          if (old) URL.revokeObjectURL(old);
        };
        """
    }
}
