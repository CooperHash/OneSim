import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import ImageIO
import UniformTypeIdentifiers

struct Ini {
    var values: [String: String] = [:]
    init(path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq])
            let v = String(line[line.index(after: eq)...])
            values[k] = v
        }
    }
}

func findEndpoint(serial: String) -> (Int, String) {
    let dir = ("~/Library/Caches/TemporaryItems/avd/running" as NSString).expandingTildeInPath
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: dir) else { fatalError("no running dir") }
    let want = serial.replacingOccurrences(of: "emulator-", with: "")
    for f in files where f.hasSuffix(".ini") {
        let ini = Ini(path: dir + "/" + f)
        if ini.values["port.serial"] == want,
           let p = ini.values["grpc.port"], let port = Int(p),
           let token = ini.values["grpc.token"] {
            return (port, token)
        }
    }
    fatalError("no endpoint for \(serial)")
}

// MARK: - minimal protobuf

struct ProtoReader {
    let bytes: [UInt8]
    var i = 0
    init(_ data: [UInt8]) { bytes = data }
    var isAtEnd: Bool { i >= bytes.count }
    mutating func varint() -> UInt64 {
        var shift: UInt64 = 0
        var value: UInt64 = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            value |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        return value
    }
    mutating func tag() -> (Int, Int) {
        let t = varint()
        return (Int(t >> 3), Int(t & 7))
    }
    mutating func lengthDelimited() -> [UInt8] {
        let len = Int(varint())
        let out = Array(bytes[i..<min(i + len, bytes.count)])
        i += len
        return out
    }
    mutating func skip(wire: Int) {
        switch wire {
        case 0: _ = varint()
        case 1: i += 8
        case 2: _ = lengthDelimited()
        case 5: i += 4
        default: i = bytes.count
        }
    }
}

struct ImageFrame {
    var width = 0
    var height = 0
    var pixels: [UInt8] = []
}

func parseImage(_ data: [UInt8]) -> ImageFrame? {
    var r = ProtoReader(data)
    var frame = ImageFrame()
    while !r.isAtEnd {
        let (field, wire) = r.tag()
        if field == 1 && wire == 2 {
            let fmt = r.lengthDelimited()
            var f = ProtoReader(fmt)
            while !f.isAtEnd {
                let (ff, fw) = f.tag()
                if ff == 3 && fw == 0 { frame.width = Int(f.varint()) }
                else if ff == 4 && fw == 0 { frame.height = Int(f.varint()) }
                else { f.skip(wire: fw) }
            }
        } else if field == 4 && wire == 2 {
            frame.pixels = r.lengthDelimited()
        } else {
            r.skip(wire: wire)
        }
    }
    return frame.width > 0 && frame.height > 0 ? frame : nil
}

// MARK: - response handler

final class DebugHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame
    typealias OutboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame
    func channelActive(context: ChannelHandlerContext) {
        print("DEBUG active"); fflush(stdout)
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let f = unwrapInboundIn(data)
        print("DEBUG in \(f.payload)"); fflush(stdout)
        context.fireChannelRead(data)
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let f = unwrapOutboundIn(data)
        print("DEBUG out \(f.payload)"); fflush(stdout)
        context.write(data, promise: promise)
    }
}

final class ResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    private var buffer: [UInt8] = []
    private let onFrame: (ImageFrame) -> Void
    private let onEnd: (Error?) -> Void
    private var done = false

    init(onFrame: @escaping (ImageFrame) -> Void, onEnd: @escaping (Error?) -> Void) {
        self.onFrame = onFrame
        self.onEnd = onEnd
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            fputs("HTTP \(head.status.code)\n", stderr)
        case .body(var buf):
            if let bytes = buf.readBytes(length: buf.readableBytes) {
                buffer.append(contentsOf: bytes)
            }
            drain()
        case .end:
            done = true
            onEnd(nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; onEnd(error) }
        context.close(promise: nil)
    }

    private func drain() {
        while buffer.count >= 5 {
            let len = Int(buffer[1]) << 24 | Int(buffer[2]) << 16 | Int(buffer[3]) << 8 | Int(buffer[4])
            guard buffer.count >= 5 + len else { return }
            let msg = Array(buffer[5..<(5 + len)])
            buffer.removeFirst(5 + len)
            if let frame = parseImage(msg) {
                onFrame(frame)
                if done { return }
            }
        }
    }
}

// MARK: - main

@main
struct ProbeMain {
    static func main() async throws {
        let serial = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "emulator-5556"
        var (port, token) = findEndpoint(serial: serial)
        if let override = ProcessInfo.processInfo.environment["PROBE_PORT"], let p = Int(override) { port = p }
        print("serial=\(serial) grpc=\(port)")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: port).get()
        let multiplexer = try await channel.configureHTTP2Pipeline(
            mode: .client,
            targetWindowSize: 8 * 1024 * 1024
        ).get()

        let finished = group.next().makePromise(of: Void.self)

        let streamPromise = channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamPromise) { ch, streamID in
            ch.pipeline.addHandlers([
                DebugHandler(),
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .http),
                ResponseHandler(onFrame: { frame in
                    print("frame \(frame.width)x\(frame.height) bytes=\(frame.pixels.count)")
                    if let cg = makeCGImage(frame) {
                        let url = URL(fileURLWithPath: "/tmp/probe-frame.png")
                        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                            CGImageDestinationAddImage(dest, cg, nil)
                            CGImageDestinationFinalize(dest)
                            print("wrote \(url.path)")
                        }
                    }
                    finished.succeed(())
                }, onEnd: { error in
                    if let error { finished.fail(error) } else { finished.succeed(()) }
                })
            ])
        }
        let stream = try await streamPromise.futureResult.get()
        print("stream created"); fflush(stdout)

        var head = HTTPRequestHead(
            version: .http2,
            method: .POST,
            uri: "/android.emulation.control.EmulatorController/streamScreenshot"
        )
        head.headers.add(name: "host", value: "127.0.0.1:\(port)")
        head.headers.add(name: "content-type", value: "application/grpc")
        head.headers.add(name: "te", value: "trailers")
        head.headers.add(name: "authorization", value: "Bearer \(token)")
        head.headers.add(name: "grpc-timeout", value: "30S")

        stream.write(HTTPClientRequestPart.head(head))
        var body = stream.allocator.buffer(capacity: 16)
        body.writeInteger(UInt8(0))
        body.writeInteger(UInt32(2), endianness: .big)
        body.writeInteger(UInt8(0x08)) // field 1, varint
        body.writeInteger(UInt8(0x01)) // RGBA8888
        body.setInteger(UInt32(2), at: 1) // gRPC message length
        stream.write(HTTPClientRequestPart.body(.byteBuffer(body)))
        stream.write(HTTPClientRequestPart.end(nil))
        stream.flush()

        // Force a frame: the emulator only streams on change.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ("~/Downloads/platform-tools/adb" as NSString).expandingTildeInPath)
            p.arguments = ["-s", serial, "shell", "input", "tap", "640", "1200"]
            try? p.run()
            p.waitUntilExit()
        }

        try await finished.futureResult.get()
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }
}

func makeCGImage(_ frame: ImageFrame) -> CGImage? {
    guard frame.pixels.count >= frame.width * frame.height * 4 else { return nil }
    let data = Data(frame.pixels.prefix(frame.width * frame.height * 4))

    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    let info = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
    return CGImage(
        width: frame.width,
        height: frame.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: frame.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: info,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}
