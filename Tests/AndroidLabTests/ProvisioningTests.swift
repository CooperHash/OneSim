import Foundation
import IOSurface
import XCTest
@testable import SimLab

final class ProvisioningTests: XCTestCase {
    func testRuntimeSelectionAcceptsOlderCompatibleIOSWithoutDuo() {
        let version = "com.apple.CoreSimulator.SimRuntime.iOS-18-1"
        let installed: [[String: Any]] = [[
            "identifier": version, "version": "18.1", "isAvailable": true,
            "supportedDeviceTypes": [["identifier": IOSSimulatorKind.iphone16Pro.deviceTypeIdentifier]],
        ], [
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "version": "27.1", "isAvailable": false,
            "supportedDeviceTypes": [["identifier": IOSSimulatorKind.iphoneDuo.deviceTypeIdentifier]],
        ]]
        XCTAssertEqual(IOSSimulatorRuntime.compatibleRuntimeIDs(runtimes: installed), [.iphone16Pro: version])
        XCTAssertTrue(DependencySetup.Report(android: [], iosNotes: ["Duo unavailable"]).isReady)
    }

    func testRuntimeSelectionReadsOldDeviceTypeBoundsAndHonorsExplicitSupport() {
        let id = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
        let older: [String: Any] = ["identifier": id, "version": "18.0", "isAvailable": true]
        let types: [[String: Any]] = [
            ["identifier": IOSSimulatorKind.iphone16Pro.deviceTypeIdentifier,
             "minRuntimeVersion": 18 << 16, "maxRuntimeVersion": Int(UInt32.max)],
            ["identifier": IOSSimulatorKind.iphoneDuo.deviceTypeIdentifier,
             "minRuntimeVersion": (27 << 16) | (1 << 8), "maxRuntimeVersion": Int(UInt32.max)],
        ]
        let duoID = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"
        let duo: [String: Any] = ["identifier": duoID, "version": "27.1", "isAvailable": true,
                                  "supportedDeviceTypes": [["identifier": IOSSimulatorKind.iphoneDuo.deviceTypeIdentifier]]]
        XCTAssertEqual(IOSSimulatorRuntime.compatibleRuntimeIDs(runtimes: [older, duo], deviceTypes: types),
                       [.iphone16Pro: id, .iphoneDuo: duoID])
    }

    func testSetupAcceptsInstalledPlayStoreARM64AndPrefersTheDefaultImageWhenAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ToolPaths.atSDK(root.path, avdHome: root.appendingPathComponent("avd").path)
        let requirement = try XCTUnwrap(DependencySetup.packages.last)

        let playStore = root.appendingPathComponent("system-images/android-37.0/google_apis_playstore/arm64-v8a")
        let intel = root.appendingPathComponent("system-images/android-37.0/google_apis_playstore/x86_64")
        for directory in [playStore, intel] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data([0]).write(to: playStore.appendingPathComponent("package.xml"))
        try Data([0]).write(to: intel.appendingPathComponent("system.img"))
        XCTAssertFalse(DependencySetup.hasPackage(requirement, paths: paths))
        XCTAssertNil(DependencySetup.defaultAndroidImage(from: AndroidRepository.listImages(paths: paths)))

        try Data([0]).write(to: playStore.appendingPathComponent("system.img"))
        XCTAssertTrue(DependencySetup.hasPackage(requirement, paths: paths))
        let fallback = try XCTUnwrap(DependencySetup.defaultAndroidImage(from: AndroidRepository.listImages(paths: paths)))
        XCTAssertEqual(fallback.id, "system-images;android-37.0;google_apis_playstore;arm64-v8a")
        let device = try await AndroidRepository.create(name: "PlayStoreFixture", profile: Profiles.all[2],
            image: fallback, ramMB: 3_072, storageGB: 4, paths: paths)
        let config = Ini.read(URL(fileURLWithPath: device.path).appendingPathComponent("config.ini"))
        XCTAssertEqual(config["PlayStore.enabled"], "true")
        XCTAssertEqual(config["image.sysdir.1"], "system-images/android-37.0/google_apis_playstore/arm64-v8a/")

        let preferred = root.appendingPathComponent(requirement.id)
        try FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)
        try Data([0]).write(to: preferred.appendingPathComponent("system.img"))
        XCTAssertEqual(DependencySetup.defaultAndroidImage(from: AndroidRepository.listImages(paths: paths)),
                       AndroidSlimClient.defaultImage)
    }

    func testSetupReusesAVDWithAnAbsoluteBootImageAndPrefersARegularPhone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let avdHome = root.appendingPathComponent("avd")
        let paths = ToolPaths.atSDK(root.appendingPathComponent("sdk").path, avdHome: avdHome.path)
        let image = root.appendingPathComponent("custom-image")
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        try Data([0]).write(to: image.appendingPathComponent("system.img"))

        for (name, fold, path) in [("01-stale", false, "/missing-image"),
                                   ("02-fold", true, image.path), ("03-phone", false, image.path)] {
            let directory = avdHome.appendingPathComponent("\(name).avd")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Ini.write(avdHome.appendingPathComponent("\(name).ini"), values: ["path": directory.path])
            try Ini.write(directory.appendingPathComponent("config.ini"), values: [
                "image.sysdir.1": path, "abi.type": "arm64-v8a", "hw.sensor.hinge": fold ? "yes" : "no",
            ])
        }
        XCTAssertTrue(AndroidRepository.listImages(paths: paths).isEmpty)
        XCTAssertTrue(DependencySetup.hasPackage(try XCTUnwrap(DependencySetup.packages.last), paths: paths))
        let devices = AndroidRepository.listDevices(paths: paths)
        XCTAssertEqual(AndroidRepository.preferredWorkspaceDevice(devices, paths: paths)?.id, "03-phone")
        XCTAssertEqual(AndroidRepository.preferredWorkspaceDevice(devices.filter { $0.isFoldable }, paths: paths)?.id, "02-fold")
    }

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
        let server = WebMultiSimServer(port: 18081)
        defer { server.stop() }
        try await server.start()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (page, http) = try await session.data(from: server.address)
        XCTAssertEqual((http as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("/app.js"))
        let (script, scriptResponse) = try await session.data(from: server.address.appendingPathComponent("app.js"))
        XCTAssertEqual((scriptResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: script, as: UTF8.self).contains("iPhone Duo"))

        let url = URL(string: "ws://127.0.0.1:18081/stream")!
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

        request.setValue(server.address.absoluteString, forHTTPHeaderField: "Origin")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        for _ in 0..<30 where !server.hasViewers {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard server.hasViewers else { return XCTFail("A same-origin viewer did not connect") }

        let payload = Data([0xff, 0xd8, 0xff, 0xd9])
        server.publish(payload, panel: 2, revision: 1)
        guard case .data(let frame) = try await socket.receive() else { return XCTFail("Expected binary frame") }
        XCTAssertEqual(frame, Data([2, 0, 0, 0, 1]) + payload)
    }

    func testWebMultiSimLANRequiresCurrentKeyForInput() async throws {
        let key = "0123456789abcdef0123456789abcdef"
        let received = expectation(description: "Authenticated input reached the server")
        let server = WebMultiSimServer(port: 18080, accessKey: key) { _, command in
            guard let command else { return }
            XCTAssertEqual(command.panel, 2)
            XCTAssertEqual(command.action, .down)
            XCTAssertEqual(command.revision, 1)
            XCTAssertEqual(command.point, CGPoint(x: 0.25, y: 0.75))
            received.fulfill()
        }
        defer { server.stop() }
        try await server.start()
        XCTAssertEqual(server.shareURL.fragment, "key=\(key)")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:18080/stream")!)
        request.setValue("http://127.0.0.1:18080", forHTTPHeaderField: "Origin")
        request.setValue("simlab, key.expired", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let rejected = session.webSocketTask(with: request)
        rejected.resume()
        do {
            _ = try await rejected.receive()
            XCTFail("An expired key was accepted")
        } catch {
            XCTAssertFalse(server.hasViewers)
        }

        request.setValue("simlab, key.\(key)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = session.webSocketTask(with: request)
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        socket.resume()
        try await socket.send(.string(#"{"panel":2,"action":"down","x":1.5,"y":0.75,"revision":1}"#))
        try await socket.send(.string(#"{"panel":2,"action":"down","x":0.25,"y":0.75,"revision":1}"#))
        await fulfillment(of: [received], timeout: 3)
    }

    func testWebH264KeyIncludesDecodeConfigurationForAnIOSurface() throws {
        guard let surface = IOSurface(properties: [
            .width: 1206, .height: 2622, .bytesPerElement: 4, .pixelFormat: 0x42475241,
        ]) else { return XCTFail("Could not allocate sample IOSurface") }
        let encoder = WebH264Encoder()
        guard let frame = encoder.encode(.ios(surface), forceKey: true) else {
            throw XCTSkip("The host did not supply a hardware H.264 session")
        }
        XCTAssertTrue(frame.isKey)
        XCTAssertGreaterThan(frame.bytes.count, 40)
        guard frame.bytes.count >= 5 else { return }
        XCTAssertEqual(Array(frame.bytes.prefix(4)), [0, 0, 0, 1])
        XCTAssertEqual(frame.bytes[4] & 0x1f, 7)
    }

    func testWebMultiSimReplaysStaticFrameToNewViewer() async throws {
        let server = WebMultiSimServer(port: 18082)
        defer { server.stop() }
        try await server.start()
        server.publish(WebDeviceStatus(panel: 1, revision: 7, width: 1206, height: 2622))
        server.publish(Data([0xff, 0xd8, 0xff, 0xd9]), panel: 1, revision: 7)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:18082/stream")!)
        request.setValue(server.address.absoluteString, forHTTPHeaderField: "Origin")
        let viewer = session.webSocketTask(with: request)
        viewer.resume()
        defer { viewer.cancel(with: .normalClosure, reason: nil) }
        guard case .string(let state) = try await viewer.receive(), state.contains("\"revision\":7"),
              case .data(let frame) = try await viewer.receive() else {
            return XCTFail("Expected cached display state before cached pixels")
        }
        XCTAssertEqual(Array(frame), [1, 0, 0, 0, 7, 255, 216, 255, 217])
    }
}
