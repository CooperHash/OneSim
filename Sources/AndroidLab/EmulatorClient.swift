import Foundation
import CoreGraphics
import QuartzCore
import Accelerate
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2

final class EmulatorClient: @unchecked Sendable {
    enum ConnectionState {
        case connecting
        case connected
        case disconnected(String)
    }

    var onFrame: ((CGImage, FrameCoordinates) -> Void)?
    var onState: ((ConnectionState) -> Void)?

    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let decodeQueue = DispatchQueue(label: "com.androidlab.frame-decode", qos: .userInitiated)
    private let lock = NSLock()
    private var channel: Channel?
    private var stream: Channel?
    private var port: Int?
    private var token: String = ""
    private var displayRotation = 0
    private var generation = 0
    private var latestFrame: (ImageFrame, Int, Int)?
    private var lastPanelFrame: (ImageFrame, Int)?
    private var frameInFlight = false
    private var receivedFrame = false
    private var timeoutTask: Task<Void, Never>?
    private let frameLock = NSLock()

    func start(port: Int, token: String) async throws {
        stop()
        lock.lock()
        generation += 1
        let generation = generation
        lock.unlock()
        frameLock.lock()
        receivedFrame = false
        frameLock.unlock()

        onState?(.connecting)
        let channel = try await ClientBootstrap(group: Self.group)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                // gRPC may send SETTINGS as soon as TCP connects. Installing
                // this after connect can lose the preface and break the stream.
                channel.configureHTTP2Pipeline(mode: .client, targetWindowSize: 8 * 1024 * 1024,
                    inboundStreamInitializer: nil).map { _ in () }
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        guard isCurrent(generation), !Task.isCancelled else {
            channel.close(promise: nil)
            throw CancellationError()
        }
        let multiplexer = try await channel.pipeline.handler(type: HTTP2StreamMultiplexer.self).get()

        let finished = channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: finished) { [weak self] streamChannel, streamID in
            guard let self else { return streamChannel.eventLoop.makeSucceededVoidFuture() }

            var head = HTTPRequestHead(
                version: .http2,
                method: .POST,
                uri: "/android.emulation.control.EmulatorController/streamScreenshot"
            )
            head.headers.add(name: "host", value: "127.0.0.1:\(port)")
            head.headers.add(name: "content-type", value: "application/grpc")
            head.headers.add(name: "te", value: "trailers")
            if !token.isEmpty {
                head.headers.add(name: "authorization", value: "Bearer \(token)")
            }

            let handler = FrameHandler(
                generation: generation,
                onFrame: { [weak self] frame in
                    guard let self, self.isCurrent(generation) else { return }
                    PerformanceMetrics.record("received", bytes: frame.pixels.count)
                    let displayRotation = self.currentDisplayRotation()
                    self.frameLock.lock()
                    self.receivedFrame = true
                    self.frameLock.unlock()
                    self.timeoutTask?.cancel()
                    self.enqueueFrame(frame, rotation: displayRotation, generation: generation)
                },
                onState: { [weak self] state in
                    guard let self, self.isCurrent(generation) else { return }
                    self.onState?(state)
                }
            )

            streamChannel.pipeline.addHandlers([
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .http),
                handler,
            ]).whenComplete { result in
                switch result {
                case .failure(let error):
                    handler.report(error: error)
                case .success:
                    streamChannel.write(HTTPClientRequestPart.head(head))
                    var body = streamChannel.allocator.buffer(capacity: 8)
                    body.writeBytes(Proto.grpcFrame(Proto.imageFormatRGBA()))
                    streamChannel.write(HTTPClientRequestPart.body(.byteBuffer(body)))
                    streamChannel.write(HTTPClientRequestPart.end(nil))
                    streamChannel.flush()
                }
            }
            return streamChannel.eventLoop.makeSucceededVoidFuture()
        }

        let stream = try await finished.futureResult.get()
        guard isCurrent(generation), !Task.isCancelled else {
            stream.close(promise: nil)
            channel.close(promise: nil)
            throw CancellationError()
        }
        lock.withLock {
            self.channel = channel
            self.stream = stream
            self.port = port
            self.token = token
        }

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, self.isCurrent(generation) else { return }
            self.frameLock.lock()
            let gotFrame = self.receivedFrame
            self.frameLock.unlock()
            guard !gotFrame else { return }
            DebugLog.write("screen stream timeout port=\(port)")
            self.onState?(.disconnected("The emulator did not respond to the screen stream."))
            self.stop()
        }
    }

    func setDisplayRotation(_ rotation: Int, redrawLatest: Bool = false) {
        let normalized = ((rotation % 4) + 4) % 4
        lock.lock()
        let changed = displayRotation != normalized
        displayRotation = normalized
        lock.unlock()
        // Folding can change Android's orientation while the screenshot is
        // static. Re-present its raw pixels rather than waiting for another
        // screen change (which can otherwise leave it sideways indefinitely).
        if changed && redrawLatest {
            frameLock.lock()
            let last = lastPanelFrame
            frameLock.unlock()
            if let (frame, generation) = last, isCurrent(generation) {
                enqueueFrame(frame, rotation: normalized, generation: generation)
            }
        }
    }

    private func currentDisplayRotation() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return displayRotation
    }

    func setPhysicalModel(target: Int, values: [Float]) {
        let payload = Proto.physicalModel(target: target, values: values)
        Task { [weak self] in
            do {
                try await self?.sendUnary(method: "setPhysicalModel", payload: payload)
            } catch {
                DebugLog.write("setPhysicalModel failed: \(error.localizedDescription)")
            }
        }
    }

    func sendKeyboardEvent(_ payload: [UInt8]) async throws {
        try await sendUnary(method: "sendKey", payload: payload)
    }

    func setClipboard(_ text: String) async throws {
        try await sendUnary(method: "setClipboard", payload: Proto.clipData(text))
    }

    private func sendUnary(method: String, payload: [UInt8]) async throws {
        let endpoint = lock.withLock { (channel, port, token) }
        guard let channel = endpoint.0, let port = endpoint.1 else {
            throw AndroidLabError.message("The emulator control channel is not connected.")
        }
        let response = channel.eventLoop.makePromise(of: Void.self)
        let stream: Channel = try await channel.pipeline.handler(type: HTTP2StreamMultiplexer.self).flatMap { mux -> EventLoopFuture<Channel> in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            mux.createStreamChannel(promise: promise) { child in
                var head = HTTPRequestHead(version: .http2, method: .POST,
                    uri: "/android.emulation.control.EmulatorController/\(method)")
                head.headers.add(name: "host", value: "127.0.0.1:\(port)")
                head.headers.add(name: "content-type", value: "application/grpc")
                head.headers.add(name: "te", value: "trailers")
                if !endpoint.2.isEmpty { head.headers.add(name: "authorization", value: "Bearer " + endpoint.2) }
                do {
                    try child.pipeline.syncOperations.addHandlers([
                        HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .http), UnaryResponseHandler(response),
                    ])
                    var body = child.allocator.buffer(capacity: payload.count + 5)
                    body.writeBytes(Proto.grpcFrame(payload))
                    child.write(HTTPClientRequestPart.head(head), promise: nil)
                    child.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
                    child.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                    return child.eventLoop.makeSucceededVoidFuture()
                } catch { return child.eventLoop.makeFailedFuture(error) }
            }
            return promise.futureResult
        }.flatMapErrorThrowing { error in
            response.fail(error)
            throw error
        }.get()
        let timeout = stream.eventLoop.scheduleTask(in: .seconds(5)) { stream.close(promise: nil) }
        defer { timeout.cancel() }
        try await response.futureResult.get()
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        frameLock.lock()
        latestFrame = nil
        lastPanelFrame = nil
        frameLock.unlock()
        lock.lock()
        generation += 1
        let stream = self.stream
        let channel = self.channel
        self.stream = nil
        self.channel = nil
        self.port = nil
        self.token = ""
        lock.unlock()
        if let stream { stream.close(promise: nil) }
        if let channel { channel.close(promise: nil) }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }

    /// One frame in flight and one replaceable latest frame. Main-thread stalls
    /// cannot build a queue of obsolete CGImages or delay input behind old frames.
    func enqueueFrame(_ frame: ImageFrame, rotation: Int, generation: Int) {
        frameLock.lock()
        lastPanelFrame = (frame, generation)
        latestFrame = (frame, rotation, generation)
        let shouldStart = !frameInFlight
        frameInFlight = true
        frameLock.unlock()
        if shouldStart { decodeQueue.async { [weak self] in self?.decodeLatestFrame() } }
    }

    private func decodeLatestFrame() {
        frameLock.lock()
        let next = latestFrame
        latestFrame = nil
        if next == nil { frameInFlight = false }
        frameLock.unlock()
        guard let (frame, rotation, generation) = next else { return }
        let image = Self.makeCGImage(frame, displayRotation: rotation)
        let sourceRotation = ((frame.rotation != 0 ? frame.rotation : rotation) % 4 + 4) % 4
        let coordinates = FrameCoordinates(width: frame.width, height: frame.height, rotation: sourceRotation, offsetX: frame.offsetX, offsetY: frame.offsetY)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let image, self.isCurrent(generation) {
                PerformanceMetrics.record("delivered")
                self.onFrame?(image, coordinates)
            }
            self.decodeQueue.async { [weak self] in self?.decodeLatestFrame() }
        }
    }

    private static func makeCGImage(_ frame: ImageFrame, displayRotation: Int) -> CGImage? {
        let byteCount = frame.width * frame.height * 4
        guard frame.pixels.count >= byteCount else { return nil }
        var width = frame.width
        var height = frame.height
        var data = frame.pixels

        // The emulator's screenshot stream is in the physical panel orientation
        // and reports how the panel is rotated. Rotate the raw RGBA buffer so the
        // image is upright and the device frame can follow the real aspect ratio.
        let sourceRotation = ((frame.rotation != 0 ? frame.rotation : displayRotation) % 4 + 4) % 4
        // The emulator reports the display orientation; the panel buffer is rotated
        // in the opposite direction, so invert it before drawing.
        let turns = (4 - sourceRotation) % 4
        if turns != 0 {
            let rotated = rotatePixels(data, width: width, height: height, turns: turns)
            data = rotated.data
            width = rotated.width
            height = rotated.height
        }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func rotatePixels(_ data: Data, width: Int, height: Int, turns: Int) -> (data: Data, width: Int, height: Int) {
        let newWidth = turns % 2 == 0 ? width : height
        let newHeight = turns % 2 == 0 ? height : width
        var output = Data(count: width * height * 4)
        data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var dst = vImage_Buffer(data: destination.baseAddress!, height: vImagePixelCount(newHeight), width: vImagePixelCount(newWidth), rowBytes: newWidth * 4)
                var background: [UInt8] = [0, 0, 0, 255]
                // vImage's positive quarter turns are counterclockwise; the
                // previous pixel loop used clockwise turns in top-left space.
                vImageRotate90_ARGB8888(&src, &dst, UInt8((4 - turns) % 4), &background, vImage_Flags(kvImageNoFlags))
            }
        }
        return (output, newWidth, newHeight)
    }

    deinit {
        stream?.close(promise: nil)
        channel?.close(promise: nil)
    }
}

private final class UnaryResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private let response: EventLoopPromise<Void>
    private var status: String?

    init(_ response: EventLoopPromise<Void>) { self.response = response }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): status = head.headers.first(name: "grpc-status")
        case .end(let trailers):
            if (trailers?.first(name: "grpc-status") ?? status) == "0" { response.succeed(()) }
            else { response.fail(AndroidLabError.message("The emulator rejected the control request.")) }
        case .body: break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        response.fail(ChannelError.eof)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        response.fail(error)
        context.close(promise: nil)
    }
}

private final class FrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let generation: Int
    private let onFrame: (ImageFrame) -> Void
    private let onState: (EmulatorClient.ConnectionState) -> Void
    private var buffer = ByteBufferAllocator().buffer(capacity: 64 * 1024)
    private var ended = false

    init(
        generation: Int,
        onFrame: @escaping (ImageFrame) -> Void,
        onState: @escaping (EmulatorClient.ConnectionState) -> Void
    ) {
        self.generation = generation
        self.onFrame = onFrame
        self.onState = onState
    }

    func report(error: Error) {
        guard !ended else { return }
        ended = true
        onState(.disconnected(error.localizedDescription))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !ended else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            if head.status.code == 200 {
                onState(.connected)
            } else {
                ended = true
                onState(.disconnected("HTTP \(head.status.code)"))
            }
        case .body(var byteBuffer):
            buffer.writeBuffer(&byteBuffer)
            drain()
        case .end:
            ended = true
            onState(.disconnected("The screen stream ended."))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        report(error: error)
        context.close(promise: nil)
    }

    private func drain() {
        while buffer.readableBytes >= 5 && !ended {
            guard let compressed: UInt8 = buffer.getInteger(at: buffer.readerIndex),
                  let size: UInt32 = buffer.getInteger(at: buffer.readerIndex + 1) else { return }
            let length = Int(size)
            guard compressed == 0, length > 0, length <= 128 * 1024 * 1024 else {
                report(error: AndroidLabError.message("Invalid screenshot frame."))
                return
            }
            guard buffer.readableBytes >= 5 + length else { return }
            buffer.moveReaderIndex(forwardBy: 5)
            guard let message = buffer.readSlice(length: length) else { return }
            // A single contiguous copy per message instead of allocating a
            // [UInt8] for every HTTP/2 fragment and another full-frame subdata.
            if let frame = Proto.parseImage(Data(message.readableBytesView)) {
                onFrame(frame)
            }
        }
        if buffer.readerIndex > 1024 * 1024 { buffer.discardReadBytes() }
    }
}
