import Foundation
import Darwin

final class RunningEmulator {
    let process: Process
    let consolePort: Int
    let grpcPort: Int
    let logURL: URL

    init(process: Process, consolePort: Int, grpcPort: Int, logURL: URL) {
        self.process = process
        self.consolePort = consolePort
        self.grpcPort = grpcPort
        self.logURL = logURL
    }

    var isRunning: Bool { process.isRunning }
}

enum PortAllocator {
    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    static func consolePort() -> Int {
        for port in stride(from: 5554, through: 5680, by: 2) where isFree(port) {
            return port
        }
        return 5554
    }

    static func grpcPort() -> Int {
        for port in stride(from: 8554, through: 9200, by: 2) where isFree(port) {
            return port
        }
        return 8554
    }
}

enum AndroidRepository {
    static var runtimeDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running")]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] {
            dirs.append(URL(fileURLWithPath: tmp).appendingPathComponent("avd/running"))
        }
        dirs.append(home.appendingPathComponent(".android/avd/running"))
        return dirs
    }

    static func runningEndpoints() -> [String: EmulatorEndpoint] {
        var result: [String: EmulatorEndpoint] = [:]
        let fm = FileManager.default
        for dir in runtimeDirectories {
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files where file.hasSuffix(".ini") && file.hasPrefix("pid_") {
                let url = dir.appendingPathComponent(file)
                let values = Ini.read(url)
                guard
                    let avdName = values["avd.name"],
                    let serialPort = values["port.serial"].flatMap(Int.init),
                    let grpcPort = values["grpc.port"].flatMap(Int.init)
                else { continue }
                let pid = Int(file.dropFirst(4).prefix { $0.isNumber }) ?? 0
                guard pid > 0, isProcessAlive(pid), !PortAllocator.isFree(grpcPort) else { continue }
                let endpoint = EmulatorEndpoint(
                    serial: "emulator-\(serialPort)",
                    consolePort: serialPort,
                    adbPort: values["port.adb"].flatMap(Int.init) ?? (serialPort + 1),
                    grpcPort: grpcPort,
                    token: values["grpc.token"] ?? "",
                    avdName: avdName,
                    pid: pid
                )
                result[avdName] = endpoint
            }
        }
        return result
    }

    static func freeDiskGB() -> Double {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: home),
              let free = values[.systemFreeSize] as? NSNumber else { return 0 }
        return free.doubleValue / 1_073_741_824
    }

    static func isProcessAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    static func listDevices(paths: ToolPaths) -> [AvdDevice] {
        let fm = FileManager.default
        let avdHome = URL(fileURLWithPath: paths.avdHome)
        guard let files = try? fm.contentsOfDirectory(atPath: avdHome.path) else { return [] }
        let endpoints = runningEndpoints()
        let adbSerials = (try? Shell.runSync(paths.adb, ["devices"], environment: paths.environment, timeout: 5))?.stdout ?? ""

        var devices: [AvdDevice] = []
        for file in files where file.hasSuffix(".ini") {
            let name = String(file.dropLast(4))
            let iniURL = avdHome.appendingPathComponent(file)
            let ini = Ini.read(iniURL)
            let dir = URL(fileURLWithPath: ini["path"] ?? avdHome.appendingPathComponent("\(name).avd").path)
            let config = Ini.read(dir.appendingPathComponent("config.ini"))
            let imagePath = config["image.sysdir.1"] ?? ""
            let api = extractAPI(imagePath) ?? config["target"] ?? ""
            let width = Int(config["hw.lcd.width"] ?? "") ?? 1080
            let height = Int(config["hw.lcd.height"] ?? "") ?? 2400
            let density = Int(config["hw.lcd.density"] ?? "") ?? 420
            let ram = parseRAMMB(config["hw.ramSize"] ?? "") ?? 0
            let storage = parseGB(config["disk.dataPartition.size"] ?? "") ?? 0
            let displayName = config["avd.ini.displayname"] ?? name
            let foldable = (config["hw.sensor.hinge"] ?? "") == "yes" ||
                (Int(config["hw.sensor.hinge.count"] ?? "0") ?? 0) > 0

            var device = AvdDevice(
                id: name,
                displayName: displayName.isEmpty ? name : displayName,
                width: width, height: height, density: density,
                api: api,
                tag: config["tag.id"] ?? "",
                imagePath: imagePath,
                path: dir.path,
                state: .stopped,
                ramMB: ram,
                storageGB: storage,
                isFoldable: foldable
            )

            if let endpoint = endpoints[name] {
                device.serial = endpoint.serial
                device.grpcPort = endpoint.grpcPort
                device.grpcToken = endpoint.token
                device.state = .running
                if !adbSerials.contains("\(endpoint.serial)\tdevice") {
                    device.state = .booting
                }
            }
            devices.append(device)
        }
        return devices.sorted {
            if $0.state.isLive != $1.state.isLive { return $0.state.isLive }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func listImages(paths: ToolPaths) -> [SystemImage] {
        let fm = FileManager.default
        guard !paths.sdk.isEmpty else { return [] }
        let roots = ["\(paths.sdk)/system-images"]
        var images: [SystemImage] = []
        var seen = Set<String>()
        for root in roots {
            guard let apis = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for api in apis {
                let apiDir = "\(root)/\(api)"
                guard let tags = try? fm.contentsOfDirectory(atPath: apiDir) else { continue }
                for tag in tags {
                    let tagDir = "\(apiDir)/\(tag)"
                    guard let abis = try? fm.contentsOfDirectory(atPath: tagDir) else { continue }
                    for abi in abis where abi == "arm64-v8a" || abi == "x86_64" {
                        let abiDir = "\(tagDir)/\(abi)"
                        let contents = (try? fm.contentsOfDirectory(atPath: abiDir)) ?? []
                        let hasImage = contents.contains { $0.hasSuffix(".img") || $0 == "package.xml" }
                        guard hasImage else { continue }
                        let id = "system-images;\(api);\(tag);\(abi)"
                        guard seen.insert(id).inserted else { continue }
                        images.append(SystemImage(id: id, api: api, tag: tag, abi: abi))
                    }
                }
            }
        }
        return images.sorted {
            if $0.api != $1.api { return $0.api > $1.api }
            if $0.tag != $1.tag { return $0.tag < $1.tag }
            return $0.abi < $1.abi
        }
    }

    static func adbDevices(paths: ToolPaths) -> [String] {
        guard let result = try? Shell.runSync(paths.adb, ["devices"], environment: paths.environment, timeout: 5) else {
            DebugLog.write("adbDevices: failed to run \(paths.adb)")
            return []
        }
        return result.stdout.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard text.hasSuffix("\tdevice") else { return nil }
            return String(text.prefix { $0 != "\t" })
        }
    }

    static func displayRotation(serial: String, paths: ToolPaths) async -> Int? {
        guard let result = try? await Shell.run(
            paths.adb, ["-s", serial, "shell", "dumpsys", "display"],
            environment: paths.environment, timeout: 10
        ) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "mCurrentOrientation=([0-3])"),
              let match = regex.firstMatch(in: result.stdout, range: NSRange(result.stdout.startIndex..., in: result.stdout)),
              let range = Range(match.range(at: 1), in: result.stdout) else { return nil }
        return Int(result.stdout[range])
    }

    static func isBooted(serial: String, paths: ToolPaths) async -> Bool {
        guard let result = try? await Shell.run(
            paths.adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"],
            environment: paths.environment, timeout: 8
        ) else { return false }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func create(
        name: String,
        profile: DeviceProfile,
        image: SystemImage,
        ramMB: Int,
        storageGB: Int,
        paths: ToolPaths
    ) async throws -> AvdDevice {
        let fm = FileManager.default
        let avdHome = URL(fileURLWithPath: paths.avdHome)
        let avdDir = avdHome.appendingPathComponent("\(name).avd")
        let iniURL = avdHome.appendingPathComponent("\(name).ini")
        guard !fm.fileExists(atPath: avdDir.path) && !fm.fileExists(atPath: iniURL.path) else {
            throw AndroidLabError.message("An emulator named “\(name)” already exists.")
        }
        try fm.createDirectory(at: avdHome, withIntermediateDirectories: true)

        var creationError = ""

        // Prefer the modern `android emulator create` CLI. It produces a clean
        // AVD skeleton and avoids avdmanager's Java/SDK-root quirks.
        if let cli = paths.androidCLI {
            for base in baseProfiles(for: profile) {
                let baseDir = avdHome.appendingPathComponent("\(base).avd")
                let baseIni = avdHome.appendingPathComponent("\(base).ini")
                guard !fm.fileExists(atPath: baseDir.path),
                      !fm.fileExists(atPath: baseIni.path) else { continue }
                let maybeResult = try? await Shell.run(
                    cli,
                    ["--sdk=\(paths.sdk)", "emulator", "create", base],
                    environment: paths.environment,
                    timeout: 120
                )
                guard let result = maybeResult,
                      result.combined.contains("Successfully created"),
                      fm.fileExists(atPath: baseDir.appendingPathComponent("config.ini").path) else {
                    creationError = maybeResult?.combined ?? creationError
                    continue
                }
                do {
                    try fm.moveItem(at: baseDir, to: avdDir)
                    try fm.moveItem(at: baseIni, to: iniURL)
                    Ini.patch(iniURL, values: [
                        "path": avdDir.path,
                        "path.rel": "avd/\(name).avd",
                        "target": image.api,
                        "avd.ini.displayname": name,
                    ])
                    return finishCreate(
                        name: name, profile: profile, image: image,
                        ramMB: ramMB, storageGB: storageGB,
                        avdDir: avdDir, iniURL: iniURL, paths: paths
                    )
                } catch {
                    creationError = error.localizedDescription
                    try? fm.removeItem(at: baseDir)
                    try? fm.removeItem(at: baseIni)
                }
            }
        }

        // Fallback: avdmanager.
        if !paths.avdmanager.isEmpty {
            let result = try await Shell.run(
                paths.avdmanager,
                ["create", "avd", "-n", name, "-k", image.id, "-p", avdDir.path],
                environment: paths.environment,
                stdin: "no\n",
                timeout: 90
            )
            if result.ok, fm.fileExists(atPath: avdDir.appendingPathComponent("config.ini").path) {
                Ini.patch(iniURL, values: [
                    "path": avdDir.path,
                    "path.rel": "avd/\(name).avd",
                    "target": image.api,
                    "avd.ini.displayname": name,
                ])
                return finishCreate(
                    name: name, profile: profile, image: image,
                    ramMB: ramMB, storageGB: storageGB,
                    avdDir: avdDir, iniURL: iniURL, paths: paths
                )
            }
            creationError = result.combined
        }

        throw AndroidLabError.message(creationError.isEmpty ? "Could not create the emulator." : creationError)
    }

    private static func baseProfiles(for profile: DeviceProfile) -> [String] {
        switch profile.category {
        case "tablet": return ["medium_tablet", "small_phone", "medium_phone"]
        case "tv": return ["medium_desktop", "small_desktop", "large_desktop"]
        case "watch": return ["small_phone", "medium_phone"]
        case "foldable": return ["medium_phone", "small_phone"]
        default: return ["medium_phone", "small_phone"]
        }
    }

    private static func finishCreate(
        name: String,
        profile: DeviceProfile,
        image: SystemImage,
        ramMB: Int,
        storageGB: Int,
        avdDir: URL,
        iniURL: URL,
        paths: ToolPaths
    ) -> AvdDevice {
        let imagePath = image.id
            .replacingOccurrences(of: "system-images;", with: "system-images/")
            .replacingOccurrences(of: ";", with: "/") + "/"
        let playStore = image.tag.contains("playstore")

        var values: [String: String] = [
            "AvdId": name,
            "avd.ini.displayname": name,
            "abi.type": image.abi,
            "hw.cpu.arch": image.abi == "arm64-v8a" ? "arm64" : "x86_64",
            "image.sysdir.1": imagePath,
            "target": image.api,
            "tag.id": image.tag,
            "tag.ids": image.tag,
            "tag.display": playStore ? "Google Play" : image.friendlyTag,
            "tag.displaynames": playStore ? "Google Play" : image.friendlyTag,
            "PlayStore.enabled": playStore ? "true" : "false",
            "playstore.enabled": playStore ? "true" : "false",
            "hw.lcd.width": "\(profile.width)",
            "hw.lcd.height": "\(profile.height)",
            "hw.lcd.density": "\(profile.density)",
            "hw.lcd.circular": profile.isCircular ? "yes" : "no",
            "hw.ramSize": "\(ramMB)",
            "disk.dataPartition.size": "\(storageGB)G",
            "hw.gpu.enabled": "yes",
            "hw.gpu.mode": "host",
            "hw.keyboard": "yes",
            "hw.mainKeys": "no",
            "hw.screen": "multi-touch",
            "hw.audioInput": "yes",
            "hw.audioOutput": "yes",
            "hw.gps": "yes",
            "hw.sdCard": "yes",
            "hw.camera.back": "virtualscene",
            "hw.camera.front": "emulated",
            "hw.device.name": profile.id,
            "hw.device.manufacturer": "SimLab",
            "showDeviceFrame": "no",
            "skin.dynamic": "yes",
            "fastboot.forceColdBoot": "no",
            "fastboot.forceFastBoot": "yes",
        ]
        if profile.isCircular {
            values["hw.rotaryInput"] = "yes"
            values["hw.lcd.circular"] = "yes"
        }
        if profile.category == "tv" {
            values["hw.dPad"] = "yes"
            values["hw.keyboard"] = "no"
        }
        let configURL = avdDir.appendingPathComponent("config.ini")
        Ini.patch(configURL, values: values)
        Ini.remove(configURL, keys: ["skin.name", "skin.path"])
        Ini.patch(iniURL, values: [
            "path": avdDir.path,
            "path.rel": "avd/\(name).avd",
            "target": image.api,
            "avd.ini.displayname": name,
        ])

        return AvdDevice(
            id: name, displayName: name,
            width: profile.width, height: profile.height, density: profile.density,
            api: image.api, tag: image.tag, imagePath: image.id,
            path: avdDir.path, state: .stopped,
            ramMB: ramMB, storageGB: storageGB,
            isFoldable: profile.isFoldable
        )
    }

    static func start(
        device: AvdDevice,
        coldBoot: Bool,
        wipeData: Bool,
        paths: ToolPaths
    ) async throws -> RunningEmulator {
        let fm = FileManager.default
        let consolePort = PortAllocator.consolePort()
        let grpcPort = PortAllocator.grpcPort()

        var arguments = [
            "-avd", device.id,
            "-port", "\(consolePort)",
            "-no-window",
            "-grpc", "\(grpcPort)",
            "-grpc-use-token",
            "-no-boot-anim",
            "-no-snapshot-save",
        ]
        let effectiveRAM = AndroidSlimClient.effectiveMemoryMB(
            configuredMB: device.ramMB,
            mode: AndroidSlimClient.mode(avdName: device.id, paths: paths)
        )
        if device.ramMB > effectiveRAM {
            arguments += ["-memory", "\(effectiveRAM)"]
        }
        if coldBoot { arguments.append("-no-snapshot-load") }
        if wipeData { arguments.append("-wipe-data") }

        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AndroidLab")
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("\(device.id).log")
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: logURL)
        try? handle.seekToEnd()
        handle.write(Data("\n\n===== \(Date()) =====\n$ \(paths.emulator) \(arguments.joined(separator: " "))\n".utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: paths.emulator)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in paths.environment { env[key] = value }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(env["PATH"] ?? "")"
        process.environment = env
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice

        try process.run()
        return RunningEmulator(process: process, consolePort: consolePort, grpcPort: grpcPort, logURL: logURL)
    }

    static func waitForEndpoint(
        avdName: String,
        consolePort: Int,
        timeout: TimeInterval = 60,
        isAlive: @escaping () -> Bool = { true }
    ) async throws -> EmulatorEndpoint {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let endpoint = runningEndpoints()[avdName], endpoint.consolePort == consolePort {
                return endpoint
            }
            guard isAlive() else {
                throw AndroidLabError.message("The emulator exited before its control endpoint became available. Check the device log.")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw AndroidLabError.message("The emulator did not expose its control endpoint in time.")
    }

    static func waitForBoot(serial: String, paths: ToolPaths, timeout: TimeInterval = 180) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isBooted(serial: serial, paths: paths) { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw AndroidLabError.message("Android did not finish booting in time.")
    }

    static func stop(serial: String?, avdName: String, paths: ToolPaths) async {
        if let serial, !serial.isEmpty,
           let result = try? await Shell.run(paths.adb, ["-s", serial, "emu", "kill"], environment: paths.environment, timeout: 8),
           result.ok {
            return
        }
        guard let result = try? await Shell.run("/usr/bin/pgrep", ["-f", "-avd \(avdName) "], timeout: 5) else { return }
        for line in result.stdout.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                kill(pid, SIGTERM)
            }
        }
    }

    static func delete(name: String, paths: ToolPaths) async throws {
        if !paths.avdmanager.isEmpty {
            _ = try? await Shell.run(paths.avdmanager, ["delete", "avd", "-n", name], environment: paths.environment, stdin: "yes\n", timeout: 30)
        }
        let fm = FileManager.default
        let avdHome = URL(fileURLWithPath: paths.avdHome)
        if fm.fileExists(atPath: avdHome.appendingPathComponent("\(name).avd").path) {
            try? fm.removeItem(at: avdHome.appendingPathComponent("\(name).avd"))
        }
        if fm.fileExists(atPath: avdHome.appendingPathComponent("\(name).ini").path) {
            try? fm.removeItem(at: avdHome.appendingPathComponent("\(name).ini"))
        }
    }

    // MARK: - Input

    static func tap(serial: String, x: Int, y: Int, paths: ToolPaths) async {
        _ = try? await Shell.run(paths.adb, ["-s", serial, "shell", "input", "tap", "\(x)", "\(y)"], environment: paths.environment, timeout: 10)
    }

    static func swipe(serial: String, x1: Int, y1: Int, x2: Int, y2: Int, duration: Int, paths: ToolPaths) async {
        _ = try? await Shell.run(
            paths.adb,
            ["-s", serial, "shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(duration)"],
            environment: paths.environment, timeout: 15
        )
    }

    static func key(serial: String, code: Int, paths: ToolPaths) async {
        _ = try? await Shell.run(paths.adb, ["-s", serial, "shell", "input", "keyevent", "\(code)"], environment: paths.environment, timeout: 10)
    }

    static func text(serial: String, text: String, paths: ToolPaths) async throws {
        guard text.canBeConverted(to: .ascii) else {
            throw AndroidLabError.message("The emulator input command only supports ASCII text. Use the on-screen keyboard for other languages.")
        }
        let escaped = text
            .replacingOccurrences(of: " ", with: "%s")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        _ = try await Shell.run(paths.adb, ["-s", serial, "shell", "input", "text", escaped], environment: paths.environment, timeout: 10)
    }

    static func foldState(serial: String, paths: ToolPaths) async throws -> FoldStateSnapshot {
        try await FoldStateControl.read { arguments, timeout in
            try await Shell.run(
                paths.adb, ["-s", serial, "shell", "cmd", "device_state"] + arguments,
                environment: paths.environment, timeout: timeout
            )
        }
    }

    static func setFoldState(serial: String, folded: Bool, paths: ToolPaths) async throws -> FoldStateSnapshot {
        // Android's device_state override alone does not switch the emulator's
        // physical panel/screenshot source. Await the console acknowledgement,
        // then reconcile and verify the guest posture as a separate step.
        let physical = try await Shell.run(
            paths.adb, ["-s", serial, "emu", folded ? "fold" : "unfold"],
            environment: paths.environment, timeout: 8
        )
        try FoldStateControl.checkEmulatorReply(physical)
        return try await FoldStateControl.set(folded: folded) { arguments, timeout in
            try await Shell.run(
                paths.adb, ["-s", serial, "shell", "cmd", "device_state"] + arguments,
                environment: paths.environment, timeout: timeout
            )
        }
    }

    static func rotate(serial: String, quarter: Int, paths: ToolPaths) async {
        _ = try? await Shell.run(paths.adb, ["-s", serial, "shell", "settings", "put", "system", "accelerometer_rotation", "0"], environment: paths.environment, timeout: 10)
        _ = try? await Shell.run(paths.adb, ["-s", serial, "shell", "settings", "put", "system", "user_rotation", "\(quarter)"], environment: paths.environment, timeout: 10)
    }

    // MARK: - Apps

    static func installAPK(url: URL, serial: String, paths: ToolPaths) async throws -> String {
        let result = try await Shell.run(
            paths.adb, ["-s", serial, "install", "-r", "-t", url.path],
            environment: paths.environment, timeout: 180
        )
        guard result.ok, result.combined.contains("Success") else {
            throw AndroidLabError.message(result.combined.isEmpty ? "adb install failed." : result.combined)
        }
        return result.combined
    }

    static func packages(serial: String, paths: ToolPaths) async -> [String] {
        guard let result = try? await Shell.run(
            paths.adb, ["-s", serial, "shell", "pm", "list", "packages", "-3"],
            environment: paths.environment, timeout: 20
        ) else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("package:") else { return nil }
            return String(text.dropFirst("package:".count))
        }.sorted()
    }

    static func launch(package: String, serial: String, paths: ToolPaths) async {
        _ = try? await Shell.run(
            paths.adb, ["-s", serial, "shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"],
            environment: paths.environment, timeout: 20
        )
    }

    static func screenshot(serial: String, paths: ToolPaths) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: paths.adb)
                process.arguments = ["-s", serial, "exec-out", "screencap", "-p"]
                var env = ProcessInfo.processInfo.environment
                for (key, value) in paths.environment { env[key] = value }
                process.environment = env
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let errorData = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: data)
                    } else {
                        let message = String(decoding: errorData, as: UTF8.self)
                        continuation.resume(throwing: AndroidLabError.message(message.isEmpty ? "screencap failed." : message))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - SDK

    static func installImage(_ image: SystemImage, paths: ToolPaths) async throws -> String {
        guard !paths.isBundledSDK else {
            throw AndroidLabError.message("The bundled SDK is read-only. Use an external SDK to install more system images.")
        }
        guard !paths.sdkmanager.isEmpty else { throw AndroidLabError.message("sdkmanager not found.") }
        let result = try await Shell.run(
            paths.sdkmanager,
            ["--sdk_root=\(paths.sdk)", "--install", image.id],
            environment: paths.environment,
            stdin: String(repeating: "y\n", count: 40),
            timeout: 1800
        )
        guard result.ok else { throw AndroidLabError.message(result.combined) }
        return result.combined
    }

    static func acceptLicenses(paths: ToolPaths) async throws {
        guard !paths.isBundledSDK else {
            throw AndroidLabError.message("The bundled SDK is read-only. Use an external SDK to install more system images.")
        }
        guard !paths.sdkmanager.isEmpty else { throw AndroidLabError.message("sdkmanager not found.") }
        let result = try await Shell.run(
            paths.sdkmanager,
            ["--sdk_root=\(paths.sdk)", "--licenses"],
            environment: paths.environment,
            stdin: String(repeating: "y\n", count: 80),
            timeout: 120
        )
        guard result.ok else { throw AndroidLabError.message(result.combined) }
    }

    // MARK: - Helpers

    private static func extractAPI(_ imagePath: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "android-([^/;\\\\]+)") else { return nil }
        let range = NSRange(imagePath.startIndex..., in: imagePath)
        guard let match = regex.firstMatch(in: imagePath, range: range),
              let r = Range(match.range(at: 1), in: imagePath) else { return nil }
        return "android-\(imagePath[r])"
    }

    private static func parseGB(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("G"), let number = Int(trimmed.dropLast()) {
            return number
        }
        if trimmed.hasSuffix("M"), let number = Int(trimmed.dropLast()) {
            return max(1, number / 1024)
        }
        if let bytes = Int64(trimmed) {
            return max(1, Int(bytes / 1_073_741_824))
        }
        return nil
    }

    private static func parseRAMMB(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.hasSuffix("G"), let number = Int(trimmed.dropLast()) {
            return number * 1024
        }
        if trimmed.hasSuffix("M"), let number = Int(trimmed.dropLast()) {
            return number
        }
        return Int(trimmed)
    }
}

enum AndroidLabError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
