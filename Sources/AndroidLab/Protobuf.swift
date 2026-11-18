import Foundation

struct ImageFrame {
    let width: Int
    let height: Int
    let pixels: Data
    let rotation: Int
    var offsetX: Int = 0
    var offsetY: Int = 0
}

enum Proto {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func field(_ number: Int, varint value: UInt64) -> [UInt8] {
        var out = varint(UInt64(number << 3))
        out += varint(value)
        return out
    }

    static func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
        var out = varint(UInt64((number << 3) | 2))
        out += varint(UInt64(bytes.count))
        out += bytes
        return out
    }

    static func field(_ number: Int, string: String) -> [UInt8] {
        field(number, bytes: Array(string.utf8))
    }

    static func grpcFrame(_ message: [UInt8]) -> Data {
        var data = Data()
        data.append(0)
        let length = UInt32(message.count)
        data.append(UInt8((length >> 24) & 0xff))
        data.append(UInt8((length >> 16) & 0xff))
        data.append(UInt8((length >> 8) & 0xff))
        data.append(UInt8(length & 0xff))
        data.append(contentsOf: message)
        return data
    }

    /// ImageFormat { format: RGBA8888 }
    static func imageFormatRGBA() -> [UInt8] {
        field(1, varint: 1)
    }

    /// Bounds screenshot dimensions while preserving the emulator's aspect ratio.
    static func imageFormatRGBA(width: Int) -> [UInt8] {
        imageFormatRGBA(width: width, height: 0)
    }

    static func imageFormatRGBA(width: Int, height: Int) -> [UInt8] {
        var out = field(1, varint: 1)
        if width > 0 { out += field(3, varint: UInt64(width)) }
        if height > 0 { out += field(4, varint: UInt64(height)) }
        return out
    }

    /// Pressure is int32, not float: nonzero is contact, zero releases the slot.
    static func touchEvent(x: Int, y: Int, identifier: Int, pressure: Int32) -> [UInt8] {
        var touch = field(1, varint: UInt64(bitPattern: Int64(x)))
        touch += field(2, varint: UInt64(bitPattern: Int64(y)))
        touch += field(3, varint: UInt64(max(0, identifier)))
        touch += field(4, varint: UInt64(bitPattern: Int64(pressure)))
        return field(1, bytes: touch)
    }

    /// InputEvent oneof envelopes for the ordered streamInputEvent RPC.
    static func inputEvent(touch: [UInt8]) -> [UInt8] { field(2, bytes: touch) }
    static func inputEvent(key: [UInt8]) -> [UInt8] { field(1, bytes: key) }

    static func keyboardText(_ text: String) -> [UInt8] {
        field(5, string: text)
    }

    /// A complete key press; the proto default would instead leave a key held down.
    static func keyboardKey(_ key: String) -> [UInt8] {
        field(2, varint: 2) + field(4, string: key)
    }

    /// codeType: USB=0, Linux evdev=1, XKB=2, Windows=3, macOS=4.
    /// Android KEYCODE_* values are not evdev codes.
    static func keyboardKeyCode(_ code: Int32, codeType: Int = 1) -> [UInt8] {
        field(1, varint: UInt64(codeType)) + field(2, varint: 2)
            + field(3, varint: UInt64(bitPattern: Int64(code)))
    }

    /// Android navigation mappings documented by emulator_controller.proto.
    /// Unknown Android codes stay on the existing ADB fallback path.
    static func keyboardAndroidKey(_ code: Int) -> [UInt8]? {
        let key: String
        switch code {
        case 3: key = "GoHome"
        case 4: key = "GoBack"
        case 187: key = "AppSwitch"
        case 26: key = "Power"
        default: return nil
        }
        return keyboardKey(key)
    }

    /// ClipData { text: "..." }
    static func clipData(_ text: String) -> [UInt8] {
        field(1, string: text)
    }

    /// PhysicalModelValue { target: <physical type>, value: [floats], interpolation: STEP }
    static func physicalModel(target: Int, values: [Float]) -> [UInt8] {
        var floatBytes: [UInt8] = []
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { floatBytes.append(contentsOf: $0) }
        }
        let parameter = field(1, bytes: floatBytes)
        var model = field(1, varint: UInt64(target))
        model += field(3, bytes: parameter)
        model += field(4, varint: 1) // Interpolation.STEP
        return model
    }

    /// Rotation in degrees. PhysicalType.ROTATION = 1.
    static func rotation(degrees: Float) -> [UInt8] {
        physicalModel(target: 1, values: [degrees])
    }

    /// Hinge angle in degrees. PhysicalType.HINGE_ANGLE0 = 10.
    static func hinge(angle: Float) -> [UInt8] {
        physicalModel(target: 10, values: [angle])
    }

    static func parseImage(_ data: Data) -> ImageFrame? {
        var reader = Reader(data)
        var width = 0
        var height = 0
        var rotation = 0
        var offsetX = 0
        var offsetY = 0
        var pixels: Data?
        while let (field, wire) = reader.nextTag() {
            switch (field, wire) {
            case (1, 2):
                let format = reader.readLengthDelimited()
                var inner = Reader(format)
                while let (f, w) = inner.nextTag() {
                    if f == 3, w == 0 { width = Int(clamping: inner.readVarint()) }
                    else if f == 4, w == 0 { height = Int(clamping: inner.readVarint()) }
                    else if f == 2, w == 2 {
                        var rotationReader = Reader(inner.readLengthDelimited())
                        while let (rf, rw) = rotationReader.nextTag() {
                            if rf == 1, rw == 0 { rotation = Int(clamping: rotationReader.readVarint()) }
                            else { rotationReader.skip(wire: rw) }
                        }
                        guard !rotationReader.failed else { return nil }
                    }
                    else if f == 7, w == 2 {
                        var folded = Reader(inner.readLengthDelimited())
                        while let (ff, fw) = folded.nextTag() {
                            if ff == 3, fw == 0 { offsetX = Int(clamping: folded.readVarint()) }
                            else if ff == 4, fw == 0 { offsetY = Int(clamping: folded.readVarint()) }
                            else { folded.skip(wire: fw) }
                        }
                        guard !folded.failed else { return nil }
                    }
                    else { inner.skip(wire: w) }
                }
                guard !inner.failed else { return nil }
            case (4, 2):
                pixels = reader.readLengthDelimited()
            case (2, 0):
                let value = Int(clamping: reader.readVarint())
                if width == 0 { width = value }
            case (3, 0):
                let value = Int(clamping: reader.readVarint())
                if height == 0 { height = value }
            default:
                reader.skip(wire: wire)
            }
        }
        guard !reader.failed, width > 0, height > 0, let pixels else { return nil }
        // Validate before any downstream width * height * 4 arithmetic.
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = area.multipliedReportingOverflow(by: 4)
        guard !areaOverflow, !byteOverflow, pixels.count >= byteCount else { return nil }
        return ImageFrame(width: width, height: height, pixels: pixels, rotation: rotation, offsetX: offsetX, offsetY: offsetY)
    }

    struct Reader {
        let data: Data
        var index: Int = 0
        private(set) var failed = false
        init(_ data: Data) { self.data = data }

        var isAtEnd: Bool { failed || index >= data.count }

        private mutating func fail() {
            failed = true
            index = data.count
        }

        mutating func readVarint() -> UInt64 {
            guard !failed else { return 0 }
            var value: UInt64 = 0
            for offset in 0..<10 {
                guard index < data.count else { fail(); return 0 }
                let byte = data[data.startIndex + index]
                index += 1
                // UInt64 has only one bit left in the tenth byte.
                guard offset < 9 || byte <= 1 else { fail(); return 0 }
                value |= UInt64(byte & 0x7f) << (offset * 7)
                if byte & 0x80 == 0 { return value }
            }
            fail()
            return 0
        }

        mutating func nextTag() -> (Int, Int)? {
            guard !isAtEnd else { return nil }
            let tag = readVarint()
            let field = tag >> 3
            let wire = Int(tag & 7)
            guard !failed, field > 0, field <= 0x1fff_ffff,
                  [0, 1, 2, 5].contains(wire) else { fail(); return nil }
            return (Int(field), wire)
        }

        mutating func readLengthDelimited() -> Data {
            let length = readVarint()
            guard !failed, length <= UInt64(data.count - index) else {
                fail()
                return Data()
            }
            let start = data.startIndex + index
            index += Int(length)
            return data[start..<(start + Int(length))]
        }

        private mutating func advance(_ count: Int) {
            guard !failed, count <= data.count - index else { fail(); return }
            index += count
        }

        mutating func skip(wire: Int) {
            switch wire {
            case 0: _ = readVarint()
            case 1: advance(8)
            case 2: _ = readLengthDelimited()
            case 5: advance(4)
            default: fail()
            }
        }
    }
}
