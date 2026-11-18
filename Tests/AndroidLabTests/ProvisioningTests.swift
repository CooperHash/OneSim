import Foundation
import XCTest
@testable import SimLab

final class ProvisioningTests: XCTestCase {
    func testDefaultAVDCreatesBootConfigurationWithoutAndroidCLI() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sdk = dir.appendingPathComponent("sdk")
        let avd = dir.appendingPathComponent("avd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageDirectory = sdk.appendingPathComponent(DependencySetup.packages[2].id)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try Data([0]).write(to: imageDirectory.appendingPathComponent("system.img"))
        let paths = ToolPaths.atSDK(sdk.path, avdHome: avd.path)
        let device = try await AndroidRepository.create(
            name: AndroidSlimClient.defaultAVD, profile: Profiles.all[2],
            image: AndroidSlimClient.defaultImage, ramMB: 3_072, storageGB: 4, paths: paths
        )
        let config = Ini.read(URL(fileURLWithPath: device.path).appendingPathComponent("config.ini"))
        XCTAssertEqual(config["hw.ramSize"], "3072")
        XCTAssertEqual(config["image.sysdir.1"], DependencySetup.packages[2].id + "/")
        XCTAssertEqual(config["PlayStore.enabled"], "false")
        XCTAssertEqual(AndroidRepository.listDevices(paths: paths).map(\.id), [device.id])
    }

    func testManagedImageBootsAndSavesQuickBootCheckpoint() async throws {
        guard let root = ProcessInfo.processInfo.environment["SIMLAB_SMOKE_SDK"] else {
            throw XCTSkip("Set SIMLAB_SMOKE_SDK to an installed Android API 36 Google APIs ARM64 SDK.")
        }
        let avd = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: avd) }
        let paths = ToolPaths.atSDK(root, avdHome: avd.path)
        let device = try await AndroidRepository.create(
            name: AndroidSlimClient.defaultAVD, profile: Profiles.all[2],
            image: AndroidSlimClient.defaultImage, ramMB: 3_072, storageGB: 4, paths: paths
        )
        let running = try await AndroidRepository.start(device: device, coldBoot: true, wipeData: false, paths: paths)
        defer {
            if running.process.isRunning {
                running.process.terminate()
                running.process.waitUntilExit()
            }
        }
        let endpoint = try await AndroidRepository.waitForEndpoint(
            avdName: device.id, consolePort: running.consolePort, isAlive: { running.process.isRunning }
        )
        try await AndroidRepository.waitForBoot(serial: endpoint.serial, paths: paths)
        _ = try await AndroidSlimClient.reconcile(serial: endpoint.serial, avdName: device.id, paths: paths)
        try await AndroidSlimClient.prepareDefaultSnapshot(device: device, serial: endpoint.serial, paths: paths, wipe: false)
        let snapshot = URL(fileURLWithPath: device.path).appendingPathComponent("snapshots/default_boot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        await AndroidRepository.stop(serial: endpoint.serial, avdName: device.id, paths: paths)
        for _ in 0..<40 where running.process.isRunning {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard !running.process.isRunning else { return XCTFail("Cold boot emulator did not stop") }

        let previousLog = try Data(contentsOf: running.logURL).count
        let restored = try await AndroidRepository.start(device: device, coldBoot: false, wipeData: false, paths: paths)
        defer {
            if restored.process.isRunning {
                restored.process.terminate()
                restored.process.waitUntilExit()
            }
        }
        let warmEndpoint = try await AndroidRepository.waitForEndpoint(
            avdName: device.id, consolePort: restored.consolePort, isAlive: { restored.process.isRunning }
        )
        try await AndroidRepository.waitForBoot(serial: warmEndpoint.serial, paths: paths)
        let log = String(decoding: try Data(contentsOf: restored.logURL).dropFirst(previousLog), as: UTF8.self)
        XCTAssertTrue(log.contains("Successfully loaded snapshot 'default_boot'"), "The emulator cold-booted instead of restoring its checkpoint.")
        await AndroidRepository.stop(serial: warmEndpoint.serial, avdName: device.id, paths: paths)
    }

    func testWebMultiSimServesFramesAndRejectsUntrustedOrigin() async throws {
        let server = WebMultiSimServer()
        defer { server.stop() }
        try await server.start()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (page, http) = try await session.data(from: WebMultiSimServer.address)
        XCTAssertEqual((http as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("iPhone Duo"))

        let url = URL(string: "ws://127.0.0.1:8080/stream")!
        var request = URLRequest(url: url)
        request.setValue("https://example.com", forHTTPHeaderField: "Origin")
        let rejected = session.webSocketTask(with: request)
        rejected.resume()
        do {
            _ = try await rejected.receive()
            XCTFail("A cross-origin viewer joined the stream")
        } catch {
            XCTAssertFalse(server.hasViewers)
        }

        request.setValue(WebMultiSimServer.address.absoluteString, forHTTPHeaderField: "Origin")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        for _ in 0..<30 where !server.hasViewers {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard server.hasViewers else { return XCTFail("A same-origin viewer did not connect") }

        let payload = Data([0xff, 0xd8, 0xff, 0xd9])
        server.publish(payload, panel: 2)
        guard case .data(let frame) = try await socket.receive() else { return XCTFail("Expected binary frame") }
        XCTAssertEqual(frame, Data([2]) + payload)
    }
}
