import Foundation
import XCTest
@testable import SimLab

final class ProtobufTests: XCTestCase {
    func testTouchUsesInt32PressureAndExplicitRelease() {
        XCTAssertEqual(Proto.touchEvent(x: 10, y: 20, identifier: 0, pressure: 1),
                       [0x0a, 8, 8, 10, 16, 20, 24, 0, 32, 1])
        XCTAssertEqual(Proto.touchEvent(x: 10, y: 20, identifier: 0, pressure: 0),
                       [0x0a, 8, 8, 10, 16, 20, 24, 0, 32, 0])
    }

    func testStreamingEnvelopes() {
        XCTAssertEqual(Proto.inputEvent(touch: [8, 1]), [18, 2, 8, 1])
        XCTAssertEqual(Proto.inputEvent(key: [16, 2]), [10, 2, 16, 2])
        XCTAssertEqual(Array(Proto.grpcFrame([18, 0])), [0, 0, 0, 0, 2, 18, 0])
    }

    func testKeyboardEncoding() {
        XCTAssertEqual(Proto.keyboardText("Hi"), [42, 2, 72, 105])
        XCTAssertEqual(Proto.keyboardKeyCode(158), [8, 1, 16, 2, 24, 158, 1])
        for (code, key) in [(3, "GoHome"), (4, "GoBack"), (187, "AppSwitch"), (26, "Power")] {
            XCTAssertEqual(Proto.keyboardAndroidKey(code), [16, 2, 34, UInt8(key.utf8.count)] + Array(key.utf8))
        }
        XCTAssertNil(Proto.keyboardAndroidKey(9999))
    }

    func testScreenshotBounds() {
        XCTAssertEqual(Proto.imageFormatRGBA(), [8, 1])
        XCTAssertEqual(Proto.imageFormatRGBA(width: 128), [8, 1, 24, 128, 1])
        XCTAssertEqual(Proto.imageFormatRGBA(width: 128, height: 64), [8, 1, 24, 128, 1, 32, 64])
        XCTAssertEqual(Proto.imageFormatRGBA(width: 0, height: -1), [8, 1])
    }

    private func image(width: UInt64 = 1, height: UInt64 = 1, pixels: [UInt8] = [1, 2, 3, 4]) -> Data {
        let format = Proto.field(3, varint: width) + Proto.field(4, varint: height)
        return Data(Proto.field(1, bytes: format) + Proto.field(4, bytes: pixels))
    }

    func testValidImageAndDataSlice() {
        let encoded = image()
        let decoded = Proto.parseImage(encoded)
        XCTAssertEqual(decoded?.width, 1)
        XCTAssertEqual(decoded?.height, 1)
        XCTAssertEqual(decoded?.pixels, Data([1, 2, 3, 4]))
        let prefixed = Data([0xff]) + encoded
        XCTAssertEqual(Proto.parseImage(prefixed.dropFirst())?.width, 1)
    }

    func testRejectsMalformedMessagesWithoutTrapping() {
        let malformed: [[UInt8]] = [
            [0],                         // Illegal field zero.
            [0x0a, 0x80],                // Truncated length varint.
            [0x0a, 0x7f, 1],             // Truncated embedded message.
            [0x0a] + Array(repeating: 0xff, count: 11),
            [0x0a, 2, 24, 0x80],         // Truncated nested dimension.
            [0x0a, 3, 18, 1, 0x80],      // Truncated nested rotation tag.
        ]
        for bytes in malformed { XCTAssertNil(Proto.parseImage(Data(bytes))) }
        XCTAssertNil(Proto.parseImage(image(width: UInt64.max)))
        XCTAssertNil(Proto.parseImage(image(width: 2)))
        XCTAssertNil(Proto.parseImage(image() + Data([0x2d, 1]))) // Truncated unknown fixed32.
        XCTAssertNil(Proto.parseImage(image() + Data([0x29, 1]))) // Truncated unknown fixed64.
    }

    func testReaderMaximumAndOverlongVarints() {
        var valid = Proto.Reader(Data(Proto.varint(UInt64.max)))
        XCTAssertEqual(valid.readVarint(), UInt64.max)
        XCTAssertFalse(valid.failed)
        var invalid = Proto.Reader(Data(Array(repeating: 0x80, count: 10)))
        XCTAssertEqual(invalid.readVarint(), 0)
        XCTAssertTrue(invalid.failed)
    }

    func testDeprecatedDimensionsAreConsumedWhenModernDimensionsExist() {
        var encoded = image()
        encoded.append(contentsOf: Proto.field(2, varint: 99) + Proto.field(3, varint: 99))
        XCTAssertEqual(Proto.parseImage(encoded)?.width, 1)
        XCTAssertEqual(Proto.parseImage(encoded)?.height, 1)
    }
}
