import Foundation

enum IOSMemoryMode: Equatable {
    case unknown
    case normal
    case balanced
    case custom

    var title: String {
        switch self {
        case .unknown: "Memory"
        case .normal: "Standard"
        case .balanced: "Balanced"
        case .custom: "Custom"
        }
    }
}

struct IOSMemorySnapshot {
    let mode: IOSMemoryMode
    let bytes: Int64?
    let disabledServices: Int
    let managedServices: Int

    var formattedFootprint: String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

/// Calls the pinned SimSlim CLI. It manages a simulator's launchd overrides;
/// SimLab continues to own CoreSimulator booting, display, and input.
enum SimSlimClient {
    private struct Status: Decodable {
        let managedDisabled: Int
        let managedTotal: Int
    }
    private struct Verify: Decodable { let ok: Bool }
    private struct Measure: Decodable { let bytes: Int64 }

    private static var bundledDirectory: URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        return root.appendingPathComponent("SimSlim")
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func paths() throws -> (binary: String, profile: String) {
        let fileManager = FileManager.default
        if let directory = bundledDirectory {
            let binary = directory.appendingPathComponent("simslim").path
            let profile = directory.appendingPathComponent("SimLabBalanced.json").path
            if fileManager.isExecutableFile(atPath: binary), fileManager.fileExists(atPath: profile) {
                return (binary, profile)
            }
        }
        let binary = sourceRoot.appendingPathComponent("Vendor/SimSlim/bin/simslim").path
        let profile = sourceRoot.appendingPathComponent("Resources/SimSlim/SimLabBalanced.json").path
        guard fileManager.isExecutableFile(atPath: binary), fileManager.fileExists(atPath: profile) else {
            throw SimSlimError.message("SimSlim is missing. Rebuild SimLab.app to include its memory tool.")
        }
        return (binary, profile)
    }

    static func optimize(udid: String) async throws {
        let paths = try paths()
        let result = try await Shell.run(paths.binary,
            ["on", udid, "--profile", paths.profile], timeout: 660)
        guard result.ok else { throw SimSlimError.message(result.combined) }
    }

    static func restore(udid: String) async throws {
        let paths = try paths()
        let result = try await Shell.run(paths.binary, ["off", udid], timeout: 660)
        guard result.ok else { throw SimSlimError.message(result.combined) }
    }

    static func snapshot(udid: String) async throws -> IOSMemorySnapshot {
        let paths = try paths()
        let statusResult = try await Shell.run(paths.binary, ["status", udid, "--json"], timeout: 45)
        guard statusResult.ok else { throw SimSlimError.message(statusResult.combined) }
        let status = try JSONDecoder().decode(Status.self, from: Data(statusResult.stdout.utf8))

        let mode: IOSMemoryMode
        if status.managedDisabled == 0 {
            mode = .normal
        } else {
            let verifyResult = try await Shell.run(paths.binary,
                ["verify", udid, "--profile", paths.profile, "--json"], timeout: 45)
            // A profile mismatch exits 1 but still returns its JSON verdict.
            if let verified = try? JSONDecoder().decode(Verify.self, from: Data(verifyResult.stdout.utf8)) {
                mode = verified.ok ? .balanced : .custom
            } else {
                throw SimSlimError.message(verifyResult.combined)
            }
        }

        let measureResult = try? await Shell.run(paths.binary, ["measure", udid, "--json"], timeout: 45)
        let measurement = measureResult.flatMap {
            try? JSONDecoder().decode(Measure.self, from: Data($0.stdout.utf8))
        }
        return IOSMemorySnapshot(
            mode: mode,
            bytes: measurement?.bytes,
            disabledServices: status.managedDisabled,
            managedServices: status.managedTotal)
    }
}

private enum SimSlimError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
