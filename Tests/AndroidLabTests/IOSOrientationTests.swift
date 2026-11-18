import XCTest
import simd
@testable import SimLab

final class IOSOrientationTests: XCTestCase {
    func testDuoPortraitDirectionsUseOppositeFrameRotations() {
        XCTAssertEqual(IOSDeviceOrientation.landscapeRight.duoInnerQuarterTurns, 2)
        XCTAssertEqual(IOSDeviceOrientation.landscapeLeft.duoInnerQuarterTurns, 0)
        XCTAssertEqual(IOSDeviceOrientation.portrait.duoInnerQuarterTurns, 1)
        XCTAssertEqual(IOSDeviceOrientation.portraitUpsideDown.duoInnerQuarterTurns, 3)
    }

    func testDuoDisplayHysteresisDeadbandMatchesSafeAreaInfo() {
        XCTAssertEqual(DuoActiveDisplay.resolve(angleDegrees: 45, current: .inner), .outer)
        XCTAssertEqual(DuoActiveDisplay.resolve(angleDegrees: 50, current: .outer), .outer)
        XCTAssertEqual(DuoActiveDisplay.resolve(angleDegrees: 50, current: .inner), .inner)
        XCTAssertEqual(DuoActiveDisplay.resolve(angleDegrees: 55, current: .outer), .inner)
    }

    func testHingeSpringSettlesSmoothlyWithoutOvershoot() {
        var spring = DuoHingeSpring(angle: 180)
        spring.target = 0
        var settled = false
        for _ in 0..<240 {
            settled = spring.step(dt: 1.0 / 120.0)
            XCTAssertGreaterThanOrEqual(spring.angle, 0)
            XCTAssertLessThanOrEqual(spring.angle, 180)
            if settled { break }
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(spring.angle, 0, accuracy: 1e-5)
    }

    func testQuaternionSpringFlipsBetweenInnerAndOuterAlongHingeForwardPath() {
        let qInner = DuoQuaternionSpring.targetQuaternion(display: .inner, orientation: .portrait)
        let qOuter = DuoQuaternionSpring.targetQuaternion(display: .outer, orientation: .portrait)
        var spring = DuoQuaternionSpring(initial: qInner)
        var moving = true
        var sawPositiveYComponent = false
        for _ in 0..<240 {
            moving = spring.step(target: qOuter, dt: 1.0 / 120.0)
            if spring.current.imag.y > 0.3 {
                sawPositiveYComponent = true
            }
            if !moving { break }
        }
        XCTAssertFalse(moving)
        XCTAssertTrue(sawPositiveYComponent)
        XCTAssertGreaterThan(abs(simd_dot(spring.current.vector, qOuter.vector)), 0.999)
    }

    func testPosePresetMatching() {
        XCTAssertEqual(DuoPosePreset.matching(angle: 0), .closed)
        XCTAssertEqual(DuoPosePreset.matching(angle: 135), .partiallyOpen)
        XCTAssertEqual(DuoPosePreset.matching(angle: 180), .open)
        XCTAssertNil(DuoPosePreset.matching(angle: 90))
    }

    @MainActor
    func test3DDigitizerPointHitsBothFoldedWingsAndOuterScreen() {
        let view = DuoFlipSceneView(frame: NSRect(x: 0, y: 0, width: 800, height: 720))
        guard view.canAnimate else { return }

        view.updateDisplay(.inner, visible: true)
        view.syncPoseIfIdle(angleDegrees: 85, orientation: .portrait)
        _ = view.snapshot()

        let leftWingHit = view.digitizerPoint(at: CGPoint(x: 250, y: 360), for: .inner)
        let rightWingHit = view.digitizerPoint(at: CGPoint(x: 550, y: 360), for: .inner)
        XCTAssertNotNil(leftWingHit)
        XCTAssertNotNil(rightWingHit)
        if let leftWingHit, let rightWingHit {
            XCTAssertEqual(leftWingHit.x, 0.5, accuracy: 0.02)
            XCTAssertEqual(rightWingHit.x, 0.5, accuracy: 0.02)
            XCTAssertGreaterThan(leftWingHit.y, 0.6)
            XCTAssertLessThan(rightWingHit.y, 0.4)
        }

        view.finish()
        view.updateDisplay(.outer, visible: false)
        view.syncPoseIfIdle(angleDegrees: 30, orientation: .portrait)
        _ = view.snapshot()

        let outerHit = view.digitizerPoint(at: CGPoint(x: 400, y: 360), for: .outer)
        XCTAssertNotNil(outerHit)
        if let outerHit {
            XCTAssertEqual(outerHit.x, 0.45, accuracy: 0.15)
            XCTAssertEqual(outerHit.y, 0.50, accuracy: 0.05)
        }
    }
}
