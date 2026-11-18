import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2

/// Low-latency input on an independent connection so screenshot traffic cannot
/// consume its HTTP/2 flow-control window. All facade state is main-actor owned.
@MainActor
final class EmulatorInputClient {
    enum State {
        case connecting
        /// The local transport is writable, not an emulator acknowledgement.
        case available
        case disconnected(String)
    }

    var onState: ((State) -> Void)?
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var connection: Channel?
    private var stream: Channel?
    private var generation = 0
    private var queue: [Pending] = []
    private var writing = false
    private var contact: (x: Int, y: Int)?
    private let capacity = 128

    deinit {
        // Normal owners call stop() to lift contact before closing.
        stream?.close(promise: nil)
        connection?.close(promise: nil)
    }

    private struct Pending {
        let bytes: [UInt8]
        let isMove: Bool
    }

    func start(port: Int, token: String) async throws {
        stop()
        let attempt = generation
        onState?(.connecting)
        var opened: Channel?
        let report: @Sendable (String) -> Void = { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                self.stop()
                self.onState?(.disconnected(reason))
            }
        }
        do {
            // Install HTTP/2 before connect enables reads. gRPC sends its server
            // SETTINGS immediately: installing after connect can lose that
            // preface, then fail on its SETTINGS ACK with ReceivedBadSettings.
            let channel = try await ClientBootstrap(group: Self.group)
                .connectTimeout(.seconds(5))
                .channelInitializer { channel in
                    channel.configureHTTP2Pipeline(mode: .client, targetWindowSize: 65_535,
                        inboundStreamInitializer: nil).flatMapThrowing { mux in
                            try channel.pipeline.syncOperations.addHandler(
                                InputConnectionHandler(report: report), position: .before(mux))
                        }
                }
                .connect(host: "127.0.0.1", port: port).get()
            opened = channel
            guard attempt == generation, !Task.isCancelled else { throw CancellationError() }
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            // Keep the non-Sendable multiplexer and handlers on the NIO loop.
            let child = try await channel.pipeline.handler(type: HTTP2StreamMultiplexer.self).flatMap { mux -> EventLoopFuture<Channel> in
                mux.createStreamChannel(promise: promise) { child in
                    do {
                        try child.pipeline.syncOperations.addHandlers([
                            HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .http),
                            InputResponseHandler(report: report),
                        ])
                        return child.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return child.eventLoop.makeFailedFuture(error)
                    }
                }
                return promise.futureResult
            }.get()
            var head = HTTPRequestHead(version: .http2, method: .POST,
                uri: "/android.emulation.control.EmulatorController/streamInputEvent")
            head.headers.add(name: "host", value: "127.0.0.1:\(port)")
            head.headers.add(name: "content-type", value: "application/grpc")
            head.headers.add(name: "te", value: "trailers")
            if !token.isEmpty { head.headers.add(name: "authorization", value: "Bearer \(token)") }
            try await child.writeAndFlush(HTTPClientRequestPart.head(head)).get()
            guard attempt == generation, !Task.isCancelled, child.isActive else { throw CancellationError() }
            connection = channel
            stream = child
            onState?(.available)
            channel.closeFuture.whenComplete { _ in report("The emulator input connection closed.") }
        } catch {
            opened?.close(promise: nil)
            if attempt == generation {
                stop()
                onState?(.disconnected(error.localizedDescription))
            }
            throw error
        }
    }

    /// Coordinates are native physical-panel pixels. True only means accepted
    /// locally; never retry this same gesture over ADB after an uncertain write.
    @discardableResult
    func sendTouch(x: Int, y: Int, pressure: Int32) -> Bool {
        guard let stream, stream.isActive else { return false }
        let touching = pressure != 0
        let moving = touching && contact != nil
        if touching && !moving && queue.count >= capacity - 1 { return false }
        if !touching && contact == nil { return true }
        let event = Pending(bytes: Proto.inputEvent(touch: Proto.touchEvent(
            x: max(0, x), y: max(0, y), identifier: 0, pressure: pressure)), isMove: moving)
        if moving, queue.last?.isMove == true {
            queue[queue.count - 1] = event
        } else if moving && queue.count >= capacity - 1 {
            // Under backpressure omit an intermediate move, never an edge.
        } else {
            queue.append(event)
        }
        contact = touching ? (max(0, x), max(0, y)) : nil
        drain()
        return true
    }

    @discardableResult
    func sendAndroidKey(_ code: Int) -> Bool {
        guard let stream, stream.isActive, queue.count < capacity - 1,
              let key = Proto.keyboardAndroidKey(code) else { return false }
        queue.append(Pending(bytes: Proto.inputEvent(key: key), isMove: false))
        drain()
        return true
    }

    private func drain() {
        guard !writing, !queue.isEmpty, let stream else { return }
        let event = queue.removeFirst()
        let attempt = generation
        writing = true
        var buffer = stream.allocator.buffer(capacity: event.bytes.count + 5)
        buffer.writeBytes(Proto.grpcFrame(event.bytes))
        stream.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer))).whenComplete { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                self.writing = false
                switch result {
                case .success: self.drain()
                case .failure(let error):
                    self.stop()
                    self.onState?(.disconnected(error.localizedDescription))
                }
            }
        }
    }

    /// Best-effort lift, then half-close the RPC. Previously accepted events
    /// remain ordered before the release. No acknowledgement or replay implied.
    func stop() {
        generation += 1
        let oldStream = stream
        let oldConnection = connection
        var remaining = queue.map(\.bytes)
        if let contact {
            remaining.append(Proto.inputEvent(touch: Proto.touchEvent(
                x: contact.x, y: contact.y, identifier: 0, pressure: 0)))
        }
        stream = nil
        connection = nil
        queue.removeAll(keepingCapacity: true)
        contact = nil
        writing = false
        guard let oldStream else {
            oldConnection?.close(promise: nil)
            return
        }
        // writeAndFlush calls already submitted by drain precede this event-loop
        // operation, so an outstanding down cannot arrive after this release.
        let pending = remaining
        oldStream.eventLoop.execute {
            for bytes in pending {
                var buffer = oldStream.allocator.buffer(capacity: bytes.count + 5)
                buffer.writeBytes(Proto.grpcFrame(bytes))
                oldStream.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            }
            oldStream.writeAndFlush(HTTPClientRequestPart.end(nil)).whenComplete { _ in
                oldConnection?.close(promise: nil)
            }
            // Bounds shutdown if the peer stops consuming input.
            oldStream.eventLoop.scheduleTask(in: .seconds(1)) {
                oldConnection?.close(promise: nil)
            }
        }
    }
}

/// NIO confines this handler's mutable state to its channel event loop.
private final class InputResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private let report: @Sendable (String) -> Void
    private var reported = false

    init(report: @escaping @Sendable (String) -> Void) { self.report = report }

    private func fail(_ reason: String) {
        guard !reported else { return }
        reported = true
        report(reason)
    }

    private func check(_ headers: HTTPHeaders) {
        if let status = headers.first(name: "grpc-status"), status != "0" {
            let message = headers.first(name: "grpc-message") ?? "Input stream rejected"
            fail("\(message.removingPercentEncoding ?? message) (gRPC \(status))")
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let response):
            if response.status.code != 200 { fail("Input stream HTTP \(response.status.code)") }
            check(response.headers)
        case .body: break
        case .end(let trailers):
            if let trailers { check(trailers) }
            fail("The emulator input stream ended.")
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error.localizedDescription)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail("The emulator input stream closed.")
        context.fireChannelInactive()
    }
}

/// Observe connection-level failures before stream teardown hides the cause.
private final class InputConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    private let report: @Sendable (String) -> Void
    init(report: @escaping @Sendable (String) -> Void) { self.report = report }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if case .goAway(_, let errorCode, let opaqueData) = frame.payload {
            let detail = opaqueData.map { String(decoding: $0.readableBytesView, as: UTF8.self) } ?? ""
            report("Input HTTP/2 GOAWAY: \(errorCode), \(detail)")
        }
        context.fireChannelRead(data)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        report("Input HTTP/2 connection error: \(error)")
        context.fireErrorCaught(error)
    }
}
