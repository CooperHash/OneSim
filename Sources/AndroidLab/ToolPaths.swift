import Foundation

struct ToolPaths: Codable, Equatable {
    var sdk: String
    var adb: String
    var emulator: String
    var avdmanager: String
    var sdkmanager: String
    var avdHome: String

    static var empty: ToolPaths {
        ToolPaths(sdk: "", adb: "", emulator: "", avdmanager: "", sdkmanager: "", avdHome: "")
    }

    static var bundledSDKRoot: String? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("AndroidSDK").path
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: "\(root)/emulator/emulator"),
              fm.isExecutableFile(atPath: "\(root)/platform-tools/adb") else { return nil }
        return root
    }

    var isBundledSDK: Bool {
        guard let bundled = Self.bundledSDKRoot else { return false }
        return (sdk as NSString).standardizingPath == (bundled as NSString).standardizingPath
    }

    static var managedSDKRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SimLab/AndroidSDK")
    }

    static func atSDK(_ root: String, avdHome: String) -> ToolPaths {
        ToolPaths(sdk: root, adb: root + "/platform-tools/adb", emulator: root + "/emulator/emulator",
                  avdmanager: root + "/cmdline-tools/latest/bin/avdmanager",
                  sdkmanager: root + "/cmdline-tools/latest/bin/sdkmanager", avdHome: avdHome)
    }

    var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: adb) &&
        FileManager.default.isExecutableFile(atPath: emulator)
    }

    var missing: [String] {
        var result: [String] = []
        if !FileManager.default.isExecutableFile(atPath: adb) { result.append("adb") }
        if !FileManager.default.isExecutableFile(atPath: emulator) { result.append("emulator") }
        return result
    }

    var environment: [String: String] {
        var env: [String: String] = [:]
        if !sdk.isEmpty {
            env["ANDROID_HOME"] = sdk
            env["ANDROID_SDK_ROOT"] = sdk
        }
        if !avdHome.isEmpty {
            env["ANDROID_AVD_HOME"] = avdHome
        }
        return env
    }

    var legacySDKManagerEnvironment: [String: String] {
        var values = environment
        if let java = Self.javaHome { values["JAVA_HOME"] = java }
        return values
    }

    private static var javaHome: String? {
        if let result = try? Shell.runSync("/usr/libexec/java_home", []), result.ok {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        for candidate in ["/opt/homebrew/opt/openjdk/bin/java", "/opt/homebrew/opt/openjdk@21/bin/java"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return (candidate as NSString).deletingLastPathComponent
            }
        }
        return nil
    }

    static func detect() -> ToolPaths {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let env = ProcessInfo.processInfo.environment

        let avdHome = env["ANDROID_AVD_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.android/avd"
        let managed = atSDK(managedSDKRoot.path, avdHome: avdHome)
        if managed.isUsable { return managed }
        if let sdk = bundledSDKRoot {
            return ToolPaths(
                sdk: sdk,
                adb: "\(sdk)/platform-tools/adb",
                emulator: "\(sdk)/emulator/emulator",
                avdmanager: "\(sdk)/cmdline-tools/latest/bin/avdmanager",
                sdkmanager: "\(sdk)/cmdline-tools/latest/bin/sdkmanager",
                avdHome: env["ANDROID_AVD_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.android/avd"
            )
        }

        var sdkCandidates: [String] = []
        if let value = env["ANDROID_HOME"], !value.isEmpty { sdkCandidates.append(value) }
        if let value = env["ANDROID_SDK_ROOT"], !value.isEmpty { sdkCandidates.append(value) }
        sdkCandidates += [
            "\(home)/Library/Android/sdk",
            "\(home)/Documents/cmdline-tools/bin",
            "\(home)/Documents/cmdline-tools/latest",
            "\(home)/Android/Sdk",
            "/opt/homebrew/share/android-commandlinetools",
        ]

        func firstExecutable(_ candidates: [String]) -> String? {
            for path in candidates where fm.isExecutableFile(atPath: path) { return path }
            return nil
        }

        func score(_ path: String) -> Int {
            var value = 0
            if fm.fileExists(atPath: "\(path)/platform-tools/adb") { value += 8 }
            if fm.fileExists(atPath: "\(path)/system-images") { value += 4 }
            if fm.fileExists(atPath: "\(path)/emulator/emulator") { value += 2 }
            if fm.fileExists(atPath: "\(path)/cmdline-tools") { value += 1 }
            return value
        }
        var sdk = sdkCandidates.max { score($0) < score($1) } ?? ""

        let adb = firstExecutable([
            "\(sdk)/platform-tools/adb",
            "\(home)/Downloads/platform-tools/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
        ]) ?? Shell.which("adb") ?? ""

        let emulator = firstExecutable([
            "\(sdk)/emulator/emulator",
            "\(home)/Library/Android/sdk/emulator/emulator",
            "\(home)/Documents/cmdline-tools/bin/emulator/emulator",
            "/opt/homebrew/bin/emulator",
        ]) ?? ""

        let avdmanager = firstExecutable([
            "\(sdk)/cmdline-tools/latest/bin/avdmanager",
            "\(sdk)/cmdline-tools/bin/avdmanager",
            "\(sdk)/bin/avdmanager",
            "\(home)/Documents/cmdline-tools/bin/avdmanager",
            "\(home)/Documents/cmdline-tools/latest/bin/avdmanager",
            "/opt/homebrew/bin/avdmanager",
        ]) ?? Shell.which("avdmanager") ?? ""

        let sdkmanager = firstExecutable([
            "\(sdk)/cmdline-tools/latest/bin/sdkmanager",
            "\(sdk)/cmdline-tools/bin/sdkmanager",
            "\(sdk)/bin/sdkmanager",
            "\(home)/Documents/cmdline-tools/bin/sdkmanager",
            "\(home)/Documents/cmdline-tools/latest/bin/sdkmanager",
            "/opt/homebrew/bin/sdkmanager",
        ]) ?? Shell.which("sdkmanager") ?? ""

        if sdk.isEmpty, !emulator.isEmpty {
            sdk = ((emulator as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        } else if sdk.isEmpty, !adb.isEmpty {
            sdk = ((adb as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        }

        return ToolPaths(
            sdk: sdk, adb: adb, emulator: emulator,
            avdmanager: avdmanager, sdkmanager: sdkmanager, avdHome: avdHome
        )
    }

    func versionSummary() async -> String {
        var lines: [String] = []
        if !emulator.isEmpty, let r = try? await Shell.run(emulator, ["-version"], environment: environment, timeout: 10) {
            let line = r.stdout.split(separator: "\n").first.map(String.init) ?? "emulator"
            lines.append(line)
        }
        if !adb.isEmpty, let r = try? await Shell.run(adb, ["version"], environment: environment, timeout: 10) {
            let line = r.stdout.split(separator: "\n").first.map(String.init) ?? "adb"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
