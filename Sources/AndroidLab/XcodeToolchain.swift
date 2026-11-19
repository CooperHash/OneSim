import Foundation

struct InstalledXcode: Identifiable, Equatable, Sendable {
    let bundle: URL
    let version: String
    let build: String

    var id: String { bundle.standardizedFileURL.path }
    var developerDirectory: String { bundle.appendingPathComponent("Contents/Developer").path }
    var label: String { build.isEmpty ? "Xcode \(version)" : "Xcode \(version) (\(build))" }

    init?(bundle: URL) {
        let contents = bundle.appendingPathComponent("Contents")
        guard let info = Self.plist(contents.appendingPathComponent("Info.plist")),
              info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode",
              let version = info["CFBundleShortVersionString"] as? String,
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("Developer/usr/bin/xcodebuild").path)
        else { return nil }
        self.bundle = bundle.standardizedFileURL
        self.version = version
        let metadata = Self.plist(contents.appendingPathComponent("version.plist"))
        build = metadata?["ProductBuildVersion"] as? String ?? info["DTXcodeBuild"] as? String ?? ""
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let file = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: file, format: nil)) as? [String: Any]
    }
}

enum XcodeToolchain {
    static let selectionKey = "SimLab.xcodeBundlePath"
    static let applications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SimLab/Xcode", isDirectory: true)

    // Called once, before any CoreSimulator framework or subprocess is loaded.
    static func applySelection() {
        let saved = UserDefaults.standard.string(forKey: selectionKey).flatMap(xcode(at:))
        let system = (try? Shell.runSync("/usr/bin/xcode-select", ["-p"], timeout: 5))
            .flatMap { $0.ok ? xcode(at: $0.stdout) : nil }
        guard let xcode = preferredXcode(saved: saved, system: system, installed: installedXcodes(active: nil)) else {
            return
        }
        setenv("DEVELOPER_DIR", xcode.developerDirectory, 1)
    }

    static func preferredXcode(saved: InstalledXcode?, system: InstalledXcode?,
                               installed: @autoclosure () -> [InstalledXcode]) -> InstalledXcode? {
        saved ?? system ?? installed().first
    }

    static func activeXcode() async -> InstalledXcode? {
        if let path = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], let xcode = xcode(at: path) {
            return xcode
        }
        guard let response = try? await Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 5), response.ok else { return nil }
        return xcode(at: response.stdout)
    }

    static func xcode(at path: String) -> InstalledXcode? {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        if url.pathExtension == "app" { return InstalledXcode(bundle: url) }
        guard url.lastPathComponent == "Developer", url.deletingLastPathComponent().lastPathComponent == "Contents" else {
            return nil
        }
        return InstalledXcode(bundle: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    static func installedXcodes(active: InstalledXcode?) -> [InstalledXcode] {
        let directories = [URL(fileURLWithPath: "/Applications"), applications]
        var byPath: [String: InstalledXcode] = [:]
        for directory in directories {
            let apps = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" {
                if let value = InstalledXcode(bundle: app) { byPath[value.id] = value }
            }
        }
        if let active { byPath[active.id] = active }
        return byPath.values.sorted {
            let order = $0.version.compare($1.version, options: .numeric)
            return order == .orderedSame ? $0.label < $1.label : order == .orderedDescending
        }
    }

    static func simulatorSDKVersion() async -> String? {
        guard let result = try? await Shell.run("/usr/bin/xcrun",
            ["--sdk", "iphonesimulator", "--show-sdk-version"], timeout: 10), result.ok else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).lazy.map {
            $0.trimmingCharacters(in: .whitespaces)
        }.last { IOSRuntimeVersion($0) != nil }
    }
}

struct IOSRuntimeVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    var packed: Int { (major << 16) | (minor << 8) | patch }
    var release: Int { packed & ~255 }

    init?(_ version: String) {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        let values = fields.compactMap { Int($0) }
        guard (1...3).contains(values.count), values.count == fields.count,
              (0...65535).contains(values[0]) else { return nil }
        major = values[0]
        minor = values.count > 1 ? values[1] : 0
        patch = values.count > 2 ? values[2] : 0
        guard (0...255).contains(minor), (0...255).contains(patch) else { return nil }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.packed < rhs.packed }
}
