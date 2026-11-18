import XCTest
@testable import SimLab

final class FrameCoordinatesTests: XCTestCase {
    @MainActor
    func testConfirmedRotationRedrawsAStaticFrame() async {
        let initial = expectation(description: "original frame")
        let rotated = expectation(description: "cached frame reoriented")
        let client = EmulatorClient()
        var count = 0
        client.onFrame = { image, _ in
            count += 1
            if count == 1 {
                XCTAssertEqual(image.width, 2); XCTAssertEqual(image.height, 1)
                initial.fulfill()
            } else {
                XCTAssertEqual(image.width, 1); XCTAssertEqual(image.height, 2)
                rotated.fulfill()
            }
        }
        client.enqueueFrame(ImageFrame(width: 2, height: 1, pixels: Data(repeating: 255, count: 8), rotation: 0), rotation: 0, generation: 0)
        await fulfillment(of: [initial], timeout: 2)
        client.setDisplayRotation(1, redrawLatest: true)
        await fulfillment(of: [rotated], timeout: 2)
        client.stop()
    }

    func testAllPanelRotationsAndClamping() {
        XCTAssertEqual(FrameCoordinates(width: 3, height: 2, rotation: 0).panelPoint(x: 2, y: 1).0, 2)
        let a = FrameCoordinates(width: 3, height: 2, rotation: 1).panelPoint(x: 1, y: 2)
        XCTAssertEqual(a.0, 0); XCTAssertEqual(a.1, 1)
        let b = FrameCoordinates(width: 3, height: 2, rotation: 2).panelPoint(x: 2, y: 1)
        XCTAssertEqual(b.0, 0); XCTAssertEqual(b.1, 0)
        let c = FrameCoordinates(width: 3, height: 2, rotation: 3).panelPoint(x: 1, y: 2)
        XCTAssertEqual(c.0, 2); XCTAssertEqual(c.1, 0)
        let d = FrameCoordinates(width: 3, height: 2, rotation: 0).panelPoint(x: -1, y: 99)
        XCTAssertEqual(d.0, 0); XCTAssertEqual(d.1, 1)
    }

    func testAcceleratedRotationMatchesOriginalPixelOrder() {
        let pixels = Data((0..<6).flatMap { [UInt8($0), 0, 0, 255] })
        let expected: [[UInt8]] = [[0,1,2,3,4,5], [3,0,4,1,5,2], [5,4,3,2,1,0], [2,5,1,4,0,3]]
        for turn in 0..<4 {
            let rotated = EmulatorClient.rotatePixels(pixels, width: 3, height: 2, turns: turn)
            XCTAssertEqual(stride(from: 0, to: rotated.data.count, by: 4).map { rotated.data[$0] }, expected[turn])
            XCTAssertEqual(rotated.width, turn % 2 == 0 ? 3 : 2)
            XCTAssertEqual(rotated.height, turn % 2 == 0 ? 2 : 3)
        }
    }
}
