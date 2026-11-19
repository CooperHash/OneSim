import AppKit
import CryptoKit
import Foundation
import SwiftUI

struct XcodeRelease: Decodable, Identifiable, Sendable {
    struct Version: Decodable, Sendable {
        struct Stage: Decodable, Sendable {
            var release: Bool?
            var beta: Int?
            var rc: Int?
        }
        let build: String
        let number: String
        let release: Stage
    }

    let version: Version
    let requires: String?

    var id: String { version.build }
    var argument: String {
        if let beta = version.release.beta { return "\(version.number) Beta \(beta)" }
        if let rc = version.release.rc { return "\(version.number) RC \(rc)" }
        return version.number
    }
    var canInstall: Bool {
        guard let requires, let minimum = IOSRuntimeVersion(requires) else { return true }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = IOSRuntimeVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        return current.map { $0 >= minimum } ?? false
    }

    static func catalog() async throws -> [XcodeRelease] {
        let url = URL(string: "https://xcodereleases.com/data.json")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SetupError("The Xcode version catalog is unavailable.")
        }
        var seen: Set<String> = []
        return try JSONDecoder().decode([XcodeRelease].self, from: data).filter { item in
            (IOSRuntimeVersion(item.version.number)?.major ?? 0) >= 16 &&
                (item.version.release.release == true || item.version.release.beta != nil || item.version.release.rc != nil) &&
                seen.insert(item.id).inserted
        }
    }
}

@MainActor
final class XcodeManager: ObservableObject {
    @Published private(set) var active: InstalledXcode?
    @Published private(set) var installed: [InstalledXcode] = []
    @Published private(set) var releases: [XcodeRelease] = []
    @Published private(set) var loadingCatalog = false
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published var error: String?

    func refresh() async {
        let selected = await XcodeToolchain.activeXcode()
        active = selected
        installed = await Task.detached(priority: .utility) {
            XcodeToolchain.installedXcodes(active: selected)
        }.value
    }

    func loadCatalog() async {
        guard !loadingCatalog, releases.isEmpty else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do { releases = try await XcodeRelease.catalog() }
        catch { self.error = error.localizedDescription }
    }

    func install(_ release: XcodeRelease) async {
        guard !busy, release.canInstall else { return }
        busy = true
        status = "Preparing the Xcode download…"
        error = nil
        defer { busy = false; status = "" }
        do {
            let helper = try await XcodesHelper.executable()
            try FileManager.default.createDirectory(at: XcodeToolchain.applications, withIntermediateDirectories: true)
            status = "Downloading and installing in Terminal"
            try await runInTerminal([
                [helper.path, "install", release.argument, "--directory", XcodeToolchain.applications.path, "--no-superuser"]
            ])
            await refresh()
            guard installed.contains(where: { $0.build == release.id }) else {
                throw SetupError("Xcodes finished, but the selected build was not found. Refresh Installed Xcode.")
            }
        } catch {
            await refresh()
            self.error = error.localizedDescription
        }
    }

    func prepareActiveXcode() async -> Bool {
        guard !busy, let active else { return false }
        busy = true
        status = "Finishing Xcode setup in Terminal"
        error = nil
        defer { busy = false; status = "" }
        do {
            let env = ["DEVELOPER_DIR=\(active.developerDirectory)"]
            let developer = ["/usr/bin/sudo", "/usr/bin/env"] + env + ["/usr/bin/xcodebuild"]
            let license = try? await Shell.run("/usr/bin/xcodebuild", ["-license", "check"],
                                               environment: ["DEVELOPER_DIR": active.developerDirectory], timeout: 12)
            let help = try? await Shell.run("/usr/bin/xcodebuild", ["-help"],
                                            environment: ["DEVELOPER_DIR": active.developerDirectory], timeout: 12)
            let componentCheck = help?.combined.contains("-checkForNewerComponents") == true
                ? ["-checkForNewerComponents"] : []
            let commands = (license?.ok == true ? [] : [developer + ["-license"]]) +
                [developer + ["-runFirstLaunch"] + componentCheck]
            try await runInTerminal(commands)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func use(_ xcode: InstalledXcode?) async {
        guard !busy else { return }
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: XcodeToolchain.selectionKey)
        guard previous != xcode?.id else { return }
        // Apple simulator frameworks loaded into this process cannot be swapped safely.
        defaults.set(xcode?.id, forKey: XcodeToolchain.selectionKey)
        let launch = NSWorkspace.OpenConfiguration()
        launch.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: launch)
            NSApp.terminate(nil)
        } catch {
            defaults.set(previous, forKey: XcodeToolchain.selectionKey)
            self.error = error.localizedDescription
        }
    }

    private func runInTerminal(_ commands: [[String]]) async throws {
        let directory = XcodeToolchain.support.appendingPathComponent("Jobs/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("SimLab Xcode Setup.command")
        let exitFile = directory.appendingPathComponent("exit")
        let shell = """
        #!/bin/bash
        set -e
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        trap 'exit 130' INT TERM HUP
        finish() {
          local status=$?
          printf '%s\\n' "$status" > \(Self.quote(exitFile.path))
        }
        trap finish EXIT
        \(commands.map { $0.map(Self.quote).joined(separator: " ") }.joined(separator: "\n"))
        """
        try shell.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init())

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(43_200)
        while clock.now < deadline {
            if let data = try? String(contentsOf: exitFile, encoding: .utf8),
               let code = Int(data.trimmingCharacters(in: .whitespacesAndNewlines)) {
                try? FileManager.default.removeItem(at: directory)
                guard code == 0 else { throw SetupError("Xcode setup ended with code \(code). See Terminal for the details.") }
                return
            }
            try await clock.sleep(for: .seconds(2))
        }
        throw SetupError("Xcode setup is still pending. Check Terminal and refresh the installed versions.")
    }

    nonisolated static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum XcodesHelper {
    static func executable() async throws -> URL {
        let directory = XcodeToolchain.support.appendingPathComponent("xcodes-2.2.0")
        let executable = directory.appendingPathComponent("xcodes")
        let files = FileManager.default
        if files.isExecutableFile(atPath: executable.path) { return executable }

        let url = URL(string: "https://github.com/XcodesOrg/xcodes/releases/download/2.2.0/xcodes.zip")!
        let (download, response) = try await URLSession.shared.download(from: url)
        defer { try? files.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SetupError("The Xcodes helper could not be downloaded.")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: download, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == "3c3ce6c550f079300c578b741e20ea0405fbe1eea808b8002ef591d568cea564" else {
            throw SetupError("The Xcodes helper download did not match its published checksum.")
        }
        let staging = XcodeToolchain.support.appendingPathComponent("helper-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let extraction = try await Shell.run("/usr/bin/ditto", ["-x", "-k", download.path, staging.path], timeout: 60)
        guard extraction.ok else { throw SetupError(extraction.combined) }
        let staged = staging.appendingPathComponent("xcodes")
        let signature = try await Shell.run("/usr/bin/codesign", ["--verify", "--strict", staged.path], timeout: 20)
        guard signature.ok, files.isExecutableFile(atPath: staged.path) else {
            throw SetupError("The Xcodes helper signature could not be verified.")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.moveItem(at: staged, to: executable)
        return executable
    }
}
