import Foundation
import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
@testable import SimLab

final class InputTransportTests: XCTestCase {
    @MainActor
    func testDisconnectedInputDoesNotClaimAdmission() {
        let client = EmulatorInputClient()
        XCTAssertFalse(client.sendTouch(x: 1, y: 2, pressure: 1))
        XCTAssertFalse(client.sendAndroidKey(4))
        client.stop()
        XCTAssertFalse(client.sendTouch(x: 1, y: 2, pressure: 0))
    }

    @MainActor
    func testPersistentStreamCoalescesMovesAndPreservesEdges() async throws {
        let received = expectation(description: "Three ordered input messages")
        let capture = InputCapture(expected: 3, expectation: received)
        let server = try await InputTestServer(capture: capture)
        let client = EmulatorInputClient()
        do {
            try await client.start(port: server.port, token: "test-token")
            XCTAssertTrue(client.sendTouch(x: 10, y: 20, pressure: 1))
            // No main-actor suspension: the down is in flight, so these moves
            // deterministically collapse to the newest pending coordinate.
            for x in 11...1_000 {
                XCTAssertTrue(client.sendTouch(x: x, y: 20, pressure: 1))
            }
            XCTAssertTrue(client.sendTouch(x: 1_000, y: 20, pressure: 0))
            await fulfillment(of: [received], timeout: 5)
            let snapshot = capture.snapshot()
            XCTAssertEqual(snapshot.path, "/android.emulation.control.EmulatorController/streamInputEvent")
            XCTAssertEqual(snapshot.authorization, "Bearer test-token")
            XCTAssertEqual(snapshot.messages, [
                Proto.inputEvent(touch: Proto.touchEvent(x: 10, y: 20, identifier: 0, pressure: 1)),
                Proto.inputEvent(touch: Proto.touchEvent(x: 1_000, y: 20, identifier: 0, pressure: 1)),
                Proto.inputEvent(touch: Proto.touchEvent(x: 1_000, y: 20, identifier: 0, pressure: 0)),
            ])
            XCTAssertFalse(snapshot.ended, "Input request must remain open between events")
            client.stop()
            XCTAssertFalse(client.sendAndroidKey(4))
            try await server.close()
        } catch {
            client.stop()
            try? await server.close()
            throw error
        }
    }

    @MainActor
    func testUnsupportedRPCReportsStatusAndDisablesInput() async throws {
        let rejected = expectation(description: "Unsupported input RPC reported")
        let capture = InputCapture(expected: 0, expectation: nil)
        let server = try await InputTestServer(capture: capture, reject: true)
        let client = EmulatorInputClient()
        client.onState = { state in
            if case .disconnected(let reason) = state, reason.contains("gRPC 12") {
                rejected.fulfill()
            }
        }
        do {
            // Rejection can race start completion; either throw or subsequently
            // become unavailable, but the explicit server status must surface.
            try? await client.start(port: server.port, token: "")
            await fulfillment(of: [rejected], timeout: 5)
            XCTAssertFalse(client.sendTouch(x: 1, y: 2, pressure: 1))
            client.stop()
            try await server.close()
        } catch {
            client.stop()
            try? await server.close()
            throw error
        }
    }
}

/// Test-only shared capture; every mutable field is protected by lock.
private final class InputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var path = ""
    private var authorization: String?
    private var messages: [[UInt8]] = []
    private var ended = false
    private let expected: Int
    private let expectation: XCTestExpectation?

    init(expected: Int, expectation: XCTestExpectation?) {
        self.expected = expected
        self.expectation = expectation
    }

    func head(_ head: HTTPRequestHead) {
        lock.lock(); defer { lock.unlock() }
        path = head.uri
        authorization = head.headers.first(name: "authorization")
    }

    func message(_ bytes: [UInt8]) {
        lock.lock()
        messages.append(bytes)
        let complete = messages.count == expected
        lock.unlock()
        if complete { expectation?.fulfill() }
    }

    func end() { lock.lock(); ended = true; lock.unlock() }

    func snapshot() -> (path: String, authorization: String?, messages: [[UInt8]], ended: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (path, authorization, messages, ended)
    }
}

private struct InputTestServer {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    var port: Int { channel.localAddress!.port! }

    init(capture: InputCapture, reject: Bool = false) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        do {
            channel = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.configureHTTP2Pipeline(mode: .server,
                        targetWindowSize: 65_535, inboundStreamInitializer: { child in
                            do {
                                try child.pipeline.syncOperations.addHandlers([
                                    HTTP2FramePayloadToHTTP1ServerCodec(),
                                    InputCaptureHandler(capture: capture, reject: reject),
                                ])
                                return child.eventLoop.makeSucceededVoidFuture()
                            } catch { return child.eventLoop.makeFailedFuture(error) }
                        }).map { _ in () }
                }.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func close() async throws {
        try await channel.close().get()
        try await group.shutdownGracefully()
    }
}

private final class InputCaptureHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    private let capture: InputCapture
    private let reject: Bool
    private var buffer = ByteBufferAllocator().buffer(capacity: 128)

    init(capture: InputCapture, reject: Bool) {
        self.capture = capture
        self.reject = reject
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            capture.head(request)
            var response = HTTPResponseHead(version: .http2, status: .ok)
            response.headers.add(name: "content-type", value: "application/grpc")
            if reject {
                response.headers.add(name: "grpc-status", value: "12")
                response.headers.add(name: "grpc-message", value: "unimplemented")
            }
            context.write(NIOAny(HTTPServerResponsePart.head(response)), promise: nil)
            if reject { context.write(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil) }
            context.flush()
        case .body(var part):
            buffer.writeBuffer(&part)
            while buffer.readableBytes >= 5 {
                guard let size: UInt32 = buffer.getInteger(at: buffer.readerIndex + 1),
                      buffer.readableBytes >= 5 + Int(size) else { return }
                buffer.moveReaderIndex(forwardBy: 5)
                if let bytes = buffer.readBytes(length: Int(size)) { capture.message(bytes) }
            }
        case .end:
            capture.end()
        }
    }
}
