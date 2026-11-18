import Foundation

struct FoldStateSnapshot: Equatable {
    let currentID: Int
    let foldedID: Int
    let unfoldedID: Int
    var isFolded: Bool { currentID == foldedID }

    static func parse(current: String, supported: String) throws -> FoldStateSnapshot {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentID = Int(trimmed) else {
            throw AndroidLabError.message("Cannot read current fold state: \(trimmed)")
        }
        let pattern = #"DeviceState\{identifier=(\d+),\s*name=['\"]([^'\"]+)['\"]"#
        let regex = try NSRegularExpression(pattern: pattern)
        var states: [Int: String] = [:]
        for match in regex.matches(in: supported, range: NSRange(supported.startIndex..., in: supported)) {
            guard let idRange = Range(match.range(at: 1), in: supported),
                  let nameRange = Range(match.range(at: 2), in: supported),
                  let id = Int(supported[idRange]) else { continue }
            let name = String(supported[nameRange])
            guard states[id] == nil else {
                throw AndroidLabError.message("Ambiguous supported fold states: \(supported)")
            }
            states[id] = name
        }
        let closed = states.filter { $0.value == "CLOSED" }.map(\.key)
        let opened = states.filter { $0.value == "OPENED" }.map(\.key)
        guard closed.count == 1, opened.count == 1 else {
            throw AndroidLabError.message("This emulator does not report unique CLOSED and OPENED states: \(supported)")
        }
        guard let name = states[currentID], ["CLOSED", "OPENED", "HALF_OPENED"].contains(name) else {
            throw AndroidLabError.message("Unknown fold posture \(currentID): \(supported)")
        }
        return FoldStateSnapshot(currentID: currentID, foldedID: closed[0], unfoldedID: opened[0])
    }
}

/// A small injectable command boundary keeps error handling and confirmation testable.
enum FoldStateControl {
    typealias Runner = ([String], TimeInterval) async throws -> CommandResult

    static func checkEmulatorReply(_ result: CommandResult) throws {
        let lines = result.combined.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard result.ok, lines.contains("OK"), !lines.contains(where: { $0.hasPrefix("KO:") }) else {
            throw AndroidLabError.message("Emulator fold command failed (exit \(result.status)): \(result.combined.isEmpty ? "Missing OK reply." : result.combined)")
        }
    }

    static func checked(_ arguments: [String], timeout: TimeInterval = 8, run: Runner) async throws -> String {
        try Task.checkCancellation()
        let result = try await run(arguments, timeout)
        guard result.ok else {
            throw AndroidLabError.message("Fold command failed (exit \(result.status)): \(result.combined)")
        }
        return result.stdout
    }

    static func read(run: Runner) async throws -> FoldStateSnapshot {
        let supported = try await checked(["print-states"], run: run)
        let current = try await checked(["print-state"], run: run)
        return try FoldStateSnapshot.parse(current: current, supported: supported)
    }

    static func set(folded: Bool, confirmationTimeout: TimeInterval = 3, run: Runner) async throws -> FoldStateSnapshot {
        let supported = try await checked(["print-states"], run: run)
        let current = try await checked(["print-state"], run: run)
        let initial = try FoldStateSnapshot.parse(current: current, supported: supported)
        let target = folded ? initial.foldedID : initial.unfoldedID
        _ = try await checked(["state", String(target)], timeout: 12, run: run)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(confirmationTimeout))
        var lastOutput = current
        while clock.now < deadline {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            lastOutput = try await checked(["print-state"], timeout: max(0.01, seconds), run: run)
            let snapshot = try FoldStateSnapshot.parse(current: lastOutput, supported: supported)
            if snapshot.currentID == target { return snapshot }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AndroidLabError.message("The emulator did not confirm \(folded ? "folding" : "unfolding") within \(confirmationTimeout) seconds (requested state \(target), last state: \(lastOutput.trimmingCharacters(in: .whitespacesAndNewlines))).")
    }
}
