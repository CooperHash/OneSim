import AppKit
import CFNetwork
import Foundation
import SwiftUI

struct ForesightDevConfiguration {
    static let iosBundleID = "pro.foresightnews.app"
    static let androidPackage = "pro.foresightnews.app.local"
    static let port = 8081
    let projectDirectory: URL

    init(projectDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/app/fn/apps/mobile")) {
        self.projectDirectory = projectDirectory
    }

    var expoCLI: URL { projectDirectory.appendingPathComponent("node_modules/expo/bin/cli") }

    static func localHTTPProxyPort(in settings: [String: Any]) -> Int? {
        guard settings["HTTPEnable"] as? Int == 1,
              let host = settings["HTTPProxy"] as? String,
              ["127.0.0.1", "localhost"].contains(host),
              let port = settings["HTTPPort"] as? Int, (1...65535).contains(port) else { return nil }
        return port
    }

    func validateMetro(body: Data, response: HTTPURLResponse) throws {
        guard response.statusCode == 200,
              String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == "packager-status:running",
              let root = response.value(forHTTPHeaderField: "X-React-Native-Project-Root")?.removingPercentEncoding,
              URL(fileURLWithPath: root).resolvingSymlinksInPath().path == projectDirectory.resolvingSymlinksInPath().path else {
            throw SetupError("Port 8081 is used by another server or project. Stop that server before starting FN.")
        }
    }
}

/// Runs the installed development apps; never builds or replaces a simulator app.
@MainActor
final class ForesightDevLauncher: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var stage = ""
    @Published var error: String?
    private let configuration: ForesightDevConfiguration
    private var task: Task<Void, Never>?
    private var metro: Process?
    private var metroOutput: FileHandle?
    private var androidProxy: ForesightMetroProxy?
    let logURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.simlab.app/fn-metro.log")

    init(configuration: ForesightDevConfiguration = .init()) {
        self.configuration = configuration
    }

    func start(model: AppModel, workspace: MultiSimWorkspace) {
        guard !isStarting else { return }
        isStarting = true
        error = nil
        stage = "Starting FN Metro on port 8081…"
        task = Task {
            defer { isStarting = false; task = nil }
            do {
                try await ensureMetro()
                model.startMultiSim(androidID: workspace.androidID)
                var failures: [String] = []
                var launched = 0
                for member in workspace.members {
                    try Task.checkCancellation()
                    do {
                        switch member {
                        case .android(let id):
                            stage = "Opening FN on \(id)…"
                            guard let runtime = model.runtimes[id] else { throw SetupError("Android device \(id) is unavailable.") }
                            try await waitForDevice {
                                if runtime.state == .error { throw SetupError(runtime.errorMessage ?? "Android failed to start.") }
                                return runtime.state == .running && runtime.serial != nil
                            }
                            try await launchAndroid(serial: runtime.serial!, paths: model.settings)
                        case .ios(let kind):
                            stage = "Opening FN on \(kind.name)…"
                            guard let runtime = model.iosRuntimes[kind] else { throw SetupError("\(kind.name) is unavailable.") }
                            try await waitForDevice {
                                if case .error(let message) = runtime.state { throw SetupError(message) }
                                return runtime.state == .running && runtime.udid != nil
                            }
                            try await launchIOS(udid: runtime.udid!)
                        }
                        launched += 1
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures.append("\(member.id): \(error.localizedDescription)") }
                }
                stage = "FN opened on \(launched) simulator\(launched == 1 ? "" : "s") · Metro :8081"
                if !failures.isEmpty { error = failures.joined(separator: "\n\n") }
            } catch is CancellationError {
                stage = ""
            } catch {
                stage = "FN could not start"
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        androidProxy?.stop()
        androidProxy = nil
        if let metro, metro.isRunning { metro.terminate() }
        metro = nil
        try? metroOutput?.close()
        metroOutput = nil
    }

    private func ensureMetro() async throws {
        guard FileManager.default.fileExists(atPath: configuration.expoCLI.path) else {
            throw SetupError("FN's Expo CLI was not found at \(configuration.projectDirectory.path). Install the workspace dependencies first.")
        }
        if try await metroIsReady() { return }
        if metro?.isRunning != true { try startMetro() }
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if try await metroIsReady() { return }
            guard metro?.isRunning == true else {
                throw SetupError("FN Metro exited before it was ready. See \(logURL.path).")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw SetupError("FN Metro did not become ready on port 8081 within 90 seconds. See \(logURL.path).")
    }

    private func metroIsReady() async throws -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8081/status")!)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
        guard let response = result.1 as? HTTPURLResponse else { return false }
        try configuration.validateMetro(body: result.0, response: response)
        return true
    }

    private func startMetro() throws {
        let fm = FileManager.default
        let nvmRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        let nvmNodes = ((try? fm.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/node").path }
        let candidates = [Shell.which("node"), "/opt/homebrew/bin/node", "/usr/local/bin/node"].compactMap { $0 } + nvmNodes
        guard let node = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw SetupError("Node.js was not found. Install Node.js to run FN Metro.")
        }
        try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        try output.truncate(atOffset: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [configuration.expoCLI.path, "start", "--host", "lan", "--port", "8081"]
        process.currentDirectoryURL = configuration.projectDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path
            + ":/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["CI"] = nil // CI mode disables Metro's file watching / Fast Refresh.
        environment["EXPO_NO_TELEMETRY"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do { try process.run() }
        catch { try? output.close(); throw error }
        metroOutput = output
        metro = process
    }

    private func waitForDevice(_ ready: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(240)
        while try !ready() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SetupError("Timed out waiting for the simulator to boot.") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func launchIOS(udid: String) async throws {
        let installed = try await Shell.run("/usr/bin/xcrun", ["simctl", "get_app_container", udid,
            ForesightDevConfiguration.iosBundleID, "app"], timeout: 20)
        guard installed.ok else { throw SetupError("Install the FN iOS development app on this simulator first.") }
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl", "launch", "--terminate-running-process", udid,
            ForesightDevConfiguration.iosBundleID, "-RCT_jsLocation", "localhost:8081"], timeout: 30)
        guard result.ok else { throw SetupError(result.combined) }
    }

    private func launchAndroid(serial: String, paths: ToolPaths) async throws {
        let package = ForesightDevConfiguration.androidPackage
        let activity = try await Shell.run(paths.adb, ["-s", serial, "shell", "cmd", "package",
            "resolve-activity", "--brief", package], environment: paths.environment, timeout: 15)
        guard activity.ok, let component = activity.stdout.split(whereSeparator: \.isNewline).last,
              component.hasPrefix(package + "/") else {
            throw SetupError("Install FN's Android development app (\(package)) on this simulator first.")
        }
        let reverse = try await Shell.run(paths.adb, ["-s", serial, "reverse", "tcp:8081", "tcp:8081"],
                                          environment: paths.environment, timeout: 15)
        guard reverse.ok else { throw SetupError(reverse.combined) }
        // Android's virtual network cannot use the Mac's loopback proxy directly.
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
           let port = ForesightDevConfiguration.localHTTPProxyPort(in: settings) {
            let currentProxy = try await Shell.run(paths.adb, ["-s", serial, "shell", "settings", "get", "global", "http_proxy"],
                                                   environment: paths.environment, timeout: 10)
            let current = currentProxy.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentProxy.ok && (["null", "", ":0"].contains(current) || current.hasPrefix("127.0.0.1:")) {
                if androidProxy?.upstreamPort != UInt16(port) {
                    androidProxy?.stop()
                    androidProxy = ForesightMetroProxy(upstreamPort: UInt16(port))
                }
                let relayPort: UInt16
                if let active = androidProxy?.port { relayPort = active }
                else { relayPort = try await androidProxy!.start() }
                let proxyReverse = try await Shell.run(paths.adb, ["-s", serial, "reverse", "tcp:8888", "tcp:\(relayPort)"],
                                                       environment: paths.environment, timeout: 15)
                guard proxyReverse.ok else { throw SetupError(proxyReverse.combined) }
                let result = try await Shell.run(paths.adb, ["-s", serial, "shell", "settings", "put", "global",
                    "http_proxy", "127.0.0.1:8888"], environment: paths.environment, timeout: 10)
                guard result.ok else { throw SetupError(result.combined) }
            }
        }
        let result = try await Shell.run(paths.adb, ["-s", serial, "shell", "am", "start", "-S", "-n", String(component)],
                                         environment: paths.environment, timeout: 30)
        guard result.ok, !result.combined.contains("Error:") else { throw SetupError(result.combined) }
    }
}

struct ForesightDevToolbar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var launcher: ForesightDevLauncher
    let workspace: MultiSimWorkspace

    var body: some View {
        Button {
            launcher.start(model: model, workspace: workspace)
        } label: {
            if launcher.isStarting {
                ProgressView().controlSize(.small)
            } else {
                Label("Run FN", systemImage: "play.fill")
            }
        }
        .disabled(launcher.isStarting)
        .help(launcher.stage.isEmpty ? "Run FN with Metro on every simulator in this workspace" : launcher.stage)
        .accessibilityLabel("Run FN with Metro on MultiSim")
        .alert("Run FN", isPresented: Binding(
            get: { launcher.error != nil },
            set: { if !$0 { launcher.error = nil } }
        )) {
            Button("OK") { launcher.error = nil }
            Button("Open Metro Log") { NSWorkspace.shared.open(launcher.logURL) }
        } message: {
            Text(launcher.error ?? "")
        }
    }
}
