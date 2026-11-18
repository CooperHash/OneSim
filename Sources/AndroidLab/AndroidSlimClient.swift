import Foundation

enum AndroidSlimMode: String, Codable {
    case balanced
    case standard

    var title: String { self == .balanced ? "Balanced" : "Standard" }
}

/// Per-AVD, reversible guest-service profile. Only packages that SimLab itself
/// disabled are recorded and later re-enabled; apps and their data stay intact.
enum AndroidSlimClient {
    static let memoryLimitMB = 8_192

    // Keep Google Play services, Store, WebView, notifications, account, media,
    // location, input, camera, accessibility, and all app-testing infrastructure.
    private static let optionalSystemPackages = [
        "com.google.android.apps.wellbeing",             // Digital Wellbeing
        "com.google.android.apps.restore",               // Device restore
        "com.google.android.googlequicksearchbox",       // Google app / Assistant
        "com.google.android.apps.wallpaper",             // Pixel live wallpapers
        "com.google.android.settings.intelligence",      // Settings search
        "com.google.android.apps.youtube.music",         // Preinstalled media app
        "com.google.android.printservice.recommendation", // Printer suggestions
        "com.android.dreams.basic",                       // Screensaver
    ]

    private struct Record: Codable {
        var mode: AndroidSlimMode = .balanced
        var disabledBySimLab: [String] = []
    }

    static func mode(avdName: String, paths: ToolPaths) -> AndroidSlimMode {
        (try? load(avdName: avdName, paths: paths).mode) ?? .standard
    }

    static func effectiveMemoryMB(configuredMB: Int, mode: AndroidSlimMode) -> Int {
        mode == .balanced ? min(configuredMB, memoryLimitMB) : configuredMB
    }

    static func setMode(_ mode: AndroidSlimMode, avdName: String, paths: ToolPaths) throws {
        var record = try load(avdName: avdName, paths: paths)
        record.mode = mode
        try save(record, avdName: avdName, paths: paths)
    }

    static func reconcile(serial: String, avdName: String, paths: ToolPaths) async throws -> Int {
        var record = try load(avdName: avdName, paths: paths)
        let installed = try await packages(serial: serial, arguments: ["list", "packages", "-s"], paths: paths)
        var disabled = try await packages(serial: serial, arguments: ["list", "packages", "-d"], paths: paths)

        if record.mode == .balanced {
            for package in optionalSystemPackages where installed.contains(package) && !disabled.contains(package) {
                try await changePackage(package, command: "disable-user", serial: serial, paths: paths)
                disabled.insert(package)
                if !record.disabledBySimLab.contains(package) {
                    record.disabledBySimLab.append(package)
                    try save(record, avdName: avdName, paths: paths)
                }
            }
        } else {
            var changed = false
            for package in record.disabledBySimLab {
                if disabled.contains(package) {
                    try await changePackage(package, command: "enable", serial: serial, paths: paths)
                    disabled.remove(package)
                    changed = true
                }
            }
            // PackageManager may defer package-restrictions.xml writes for ten
            // seconds. Keep the restore journal through the next boot so an
            // interrupted or early restart can retry instead of losing it.
            if changed {
                try await Task.sleep(nanoseconds: 12_000_000_000)
            } else if !record.disabledBySimLab.isEmpty {
                record.disabledBySimLab = []
                try save(record, avdName: avdName, paths: paths)
            }
        }
        let observedDisabled = try await packages(serial: serial, arguments: ["list", "packages", "-d"], paths: paths)
        let managedDisabled = record.disabledBySimLab.filter { observedDisabled.contains($0) }
        let expectedManaged = Set(record.disabledBySimLab).intersection(installed)
        let verified = record.mode == .standard
            ? managedDisabled.isEmpty
            : expectedManaged.isSubset(of: observedDisabled)
        guard verified else {
            throw AndroidSlimError.message("Android did not confirm the requested package states.")
        }
        return managedDisabled.count
    }

    private static func packages(serial: String, arguments: [String], paths: ToolPaths) async throws -> Set<String> {
        let result = try await Shell.run(paths.adb,
            ["-s", serial, "shell", "pm"] + arguments,
            environment: paths.environment, timeout: 20)
        guard result.ok else { throw AndroidSlimError.message(result.combined) }
        return Set(result.stdout.split(separator: "\n").compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst("package:".count)) : nil
        })
    }

    private static func changePackage(_ package: String, command: String, serial: String, paths: ToolPaths) async throws {
        let result = try await Shell.run(paths.adb,
            ["-s", serial, "shell", "pm", command, "--user", "0", package],
            environment: paths.environment, timeout: 20)
        guard result.ok, result.stdout.contains("new state:") else {
            throw AndroidSlimError.message("Could not \(command) \(package): \(result.combined)")
        }
    }

    private static func recordURL(avdName: String, paths: ToolPaths) -> URL {
        URL(fileURLWithPath: paths.avdHome)
            .appendingPathComponent("\(avdName).avd/.simlab-slim.json")
    }

    private static func load(avdName: String, paths: ToolPaths) throws -> Record {
        let url = recordURL(avdName: avdName, paths: paths)
        guard FileManager.default.fileExists(atPath: url.path) else { return Record() }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }

    private static func save(_ record: Record, avdName: String, paths: ToolPaths) throws {
        let url = recordURL(avdName: avdName, paths: paths)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
}

private enum AndroidSlimError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
