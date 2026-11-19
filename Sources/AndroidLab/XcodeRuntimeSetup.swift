import Foundation

enum XcodeRuntimeSetup {
    struct Plan: Equatable {
        let sdk: String
        let missing: [IOSSimulatorKind]

        func nextDownload(available: Set<IOSSimulatorKind>, attempted: Set<String>) -> String? {
            let remaining = Set(missing).subtracting(available)
            guard !remaining.isEmpty else { return nil }
            if remaining.contains(.iphone16Pro), let version = IOSRuntimeVersion(sdk),
               version.major == 27, version.minor >= 1,
               remaining == [.iphone16Pro] || attempted.contains(sdk) {
                return attempted.contains("27.0") ? nil : "27.0"
            }
            return attempted.contains(sdk) ? nil : sdk
        }
    }

    struct Inventory {
        let sdk: String
        let installed: [IOSSimulatorKind: String]
        let supported: Set<IOSSimulatorKind>
        let reportedIOS: [String]

        var plan: Plan? {
            let missing = IOSSimulatorKind.allCases.filter { installed[$0] == nil && supported.contains($0) }
            return missing.isEmpty ? nil : Plan(sdk: sdk, missing: missing)
        }
    }

    static func inventory() async throws -> Inventory {
        async let sdk = XcodeToolchain.simulatorSDKVersion()
        let runtimes: [[String: Any]]
        let deviceTypes: [[String: Any]]
        if let all = try? await simctlJSON(["list", "-j"]),
           let allRuntimes = all["runtimes"] as? [[String: Any]],
           let allTypes = all["devicetypes"] as? [[String: Any]] {
            runtimes = allRuntimes
            deviceTypes = allTypes
        } else {
            // Older Xcode versions and a freshly started CoreSimulator service
            // can return diagnostics or an incomplete combined list.
            async let listedRuntimes = readList("runtimes")
            async let listedTypes = readList("devicetypes")
            (runtimes, deviceTypes) = try await (listedRuntimes, listedTypes)
        }
        guard let version = await sdk else {
            throw SetupError("Xcode could not report an iPhone Simulator SDK. Check the selected Xcode’s first-launch setup.")
        }
        return inventory(sdk: version, runtimes: runtimes, deviceTypes: deviceTypes)
    }

    static func inventory(sdk: String, runtimes: [[String: Any]], deviceTypes: [[String: Any]]) -> Inventory {
        let installed = IOSSimulatorRuntime.compatibleRuntimeIDs(runtimes: runtimes, deviceTypes: deviceTypes, sdk: sdk)
        let ceiling = IOSRuntimeVersion(sdk)
        let supported = Set(IOSSimulatorKind.allCases.filter { kind in
            if installed[kind] != nil { return true }
            guard let type = deviceTypes.first(where: { ($0["identifier"] as? String) == kind.deviceTypeIdentifier }) else {
                return false
            }
            guard let minimum = runtimeBound(type, "min"), let ceiling else { return true }
            return minimum & ~255 <= ceiling.release
        })
        let reportedIOS = runtimes.compactMap { runtime -> String? in
            guard let id = runtime["identifier"] as? String, id.hasPrefix(iosPrefix) else { return nil }
            let version = runtimeVersion(runtime) ?? id
            guard !isAvailable(runtime) else { return "iOS \(version)" }
            let reason = runtime["availabilityError"] as? String ?? runtime["availability"] as? String
            return "iOS \(version) · \(reason ?? "Unavailable")"
        }
        return Inventory(sdk: sdk, installed: installed, supported: supported, reportedIOS: reportedIOS)
    }

    static let iosPrefix = "com.apple.CoreSimulator.SimRuntime.iOS-"

    static func runtimeVersion(_ runtime: [String: Any]) -> String? {
        if let version = runtime["version"] as? String, IOSRuntimeVersion(version) != nil { return version }
        guard let id = runtime["identifier"] as? String, id.hasPrefix(iosPrefix) else { return nil }
        let version = id.dropFirst(iosPrefix.count).replacingOccurrences(of: "-", with: ".")
        return IOSRuntimeVersion(version) == nil ? nil : version
    }

    static func isAvailable(_ entry: [String: Any]) -> Bool {
        if let available = entry["isAvailable"] as? Bool { return available }
        if let reason = entry["availabilityError"] as? String, !reason.isEmpty { return false }
        return (entry["availability"] as? String).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "() ")).lowercased() == "available"
        } ?? true
    }

    static func runtimeBound(_ type: [String: Any], _ bound: String) -> Int? {
        if let value = type["\(bound)RuntimeVersion"] as? Int { return value }
        if let value = type["\(bound)RuntimeVersionString"] as? String {
            return IOSRuntimeVersion(value)?.packed
        }
        return nil
    }

    static func simctlJSON(_ arguments: [String]) async throws -> [String: Any] {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: 30)
        guard result.ok else { throw SetupError(commandFailure("CoreSimulator could not read its simulator inventory", result)) }
        return try decodeList(result.stdout)
    }

    static func decodeList(_ output: String) throws -> [String: Any] {
        func decode(_ text: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        if let json = decode(output) { return json }
        // Preserve the JSON when Apple emits a warning before or after it.
        let lines = output.split(whereSeparator: \.isNewline)
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
           let end = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("}") }), start <= end,
           let json = decode(lines[start...end].joined(separator: "\n")) {
            return json
        }
        throw SetupError("CoreSimulator returned an unreadable simulator list. Check Again to refresh the selected Xcode.")
    }

    private static func readList(_ section: String) async throws -> [[String: Any]] {
        let json = try await simctlJSON(["list", "-j", section])
        guard let rows = json[section] as? [[String: Any]] else {
            throw SetupError("The selected Xcode did not return a CoreSimulator \(section) list.")
        }
        return rows
    }

    static func install(_ plan: Plan, progress: @escaping @MainActor (String) -> Void) async throws {
        var current = try await inventory()
        let needed = Set(plan.missing)
        guard !needed.isSubset(of: Set(current.installed.keys)) else { return }
        var attempted: Set<String> = []
        var failure: Error?
        while let version = plan.nextDownload(available: Set(current.installed.keys), attempted: attempted) {
            attempted.insert(version)
            await progress("Downloading iOS \(version) from Apple…")
            do {
                let arguments = ["-downloadPlatform", "iOS"] + (version == plan.sdk ? [] : ["-buildVersion", version])
                try await runInstaller(arguments, operation: "Apple could not download the iOS \(version) Simulator Runtime")
            } catch {
                failure = error
            }
            try Task.checkCancellation()
            await progress("Checking installed iOS Simulator runtimes…")
            current = try await waitForInventory(gaining: needed.subtracting(current.installed.keys))
            if needed.isSubset(of: Set(current.installed.keys)) { return }
        }
        if let failure { throw failure }
        let names = plan.missing.filter { current.installed[$0] == nil }.map(\.name).joined(separator: ", ")
        throw SetupError("Xcode finished installing, but CoreSimulator still has no usable runtime for \(names).")
    }

    static func importRuntime(_ file: URL, progress: @escaping @MainActor (String) -> Void) async throws {
        let accessed = file.startAccessingSecurityScopedResource()
        defer { if accessed { file.stopAccessingSecurityScopedResource() } }
        let before = try? await inventory()
        await progress("Importing \(file.lastPathComponent)…")
        try await runInstaller(["-importPlatform", file.path], operation: "Xcode could not import the Simulator Runtime")
        let missing = Set(before?.plan?.missing ?? [])
        _ = try await waitForInventory(gaining: missing)
    }

    private static func waitForInventory(gaining expected: Set<IOSSimulatorKind>) async throws -> Inventory {
        for _ in 0..<4 {
            if let result = try? await inventory(), expected.isEmpty || !expected.isDisjoint(with: result.installed.keys) {
                return result
            }
            try await Task.sleep(for: .seconds(2))
        }
        return try await inventory()
    }

    private static func runInstaller(_ arguments: [String], operation: String) async throws {
        let result = try await Shell.run("/usr/bin/xcodebuild", arguments, timeout: 7_200)
        guard result.ok else { throw SetupError(commandFailure(operation, result)) }
    }

    private static func commandFailure(_ operation: String, _ result: CommandResult) -> String {
        let lines = result.combined.split(whereSeparator: \.isNewline).suffix(5)
        let details = String(lines.joined(separator: "\n").suffix(950))
        return details.isEmpty ? "\(operation) (exit \(result.status))." : "\(operation) (exit \(result.status)).\n\(details)"
    }
}
