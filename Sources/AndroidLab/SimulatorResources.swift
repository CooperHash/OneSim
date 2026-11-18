import Foundation
import SwiftUI

enum SimulatorResourceTarget {
    case android(key: String, avdName: String)
    case ios(key: String, udid: String)

    var key: String {
        switch self {
        case .android(let key, _), .ios(let key, _): key
        }
    }
}

struct SimulatorResourceUsage {
    let processCount: Int
    let memoryBytes: Int64
    /// Sum of macOS process %CPU values; multicore simulators can exceed 100%.
    let cpuPercent: Double

    var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .memory)
    }
}

@MainActor
final class SimulatorResourceMonitor: ObservableObject {
    @Published private(set) var readings: [String: SimulatorResourceUsage] = [:]

    func refresh(_ targets: [SimulatorResourceTarget]) async {
        guard !targets.isEmpty else {
            readings = [:]
            return
        }
        let result = try? await SimulatorResourceSampler.sample(targets)
        guard !Task.isCancelled else { return }
        readings = result ?? [:]
    }
}

struct SimulatorResourceBadge: View {
    let usage: SimulatorResourceUsage?

    var body: some View {
        HStack(spacing: 12) {
            if let usage {
                Text(String(format: "CPU %.0f%%", usage.cpuPercent))
                Text("RAM \(usage.memoryLabel)")
                Text("\(usage.processCount) processes")
            } else {
                Text("Measuring CPU and RAM…")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .help("Host CPU and summed process memory for this simulator; refreshed every 5 seconds. CPU may exceed 100% on multiple cores.")
    }
}

/// One host-wide ps/top sweep feeds every visible simulator, avoiding one top
/// process per device. Memory uses top's phys_footprint, matching Activity Monitor.
enum SimulatorResourceSampler {
    static func sample(_ targets: [SimulatorResourceTarget]) async throws -> [String: SimulatorResourceUsage] {
        let endpoints = AndroidRepository.runningEndpoints()
        var roots: [String: Int] = [:]
        for target in targets {
            switch target {
            case .android(let key, let avdName):
                roots[key] = endpoints[avdName]?.pid
            case .ios(let key, let udid):
                let result = try? await Shell.run("/usr/bin/pgrep",
                    ["-f", "\(udid)/data/var/run/launchd_bootstrap"], timeout: 5)
                roots[key] = result?.stdout.split(whereSeparator: \.isWhitespace)
                    .first.flatMap { Int($0) }
            }
        }
        guard !roots.isEmpty else { return [:] }

        async let processResult = Shell.run("/bin/ps", ["-axo", "pid,ppid,%cpu"], timeout: 10)
        async let memoryResult = Shell.run("/usr/bin/top", ["-l", "1", "-stats", "pid,mem"], timeout: 15)
        let processes = try await processResult
        let memory = try await memoryResult
        guard processes.ok, memory.ok else { return [:] }

        let (children, cpu) = parseProcesses(processes.stdout)
        let bytes = parseMemory(memory.stdout)
        return roots.reduce(into: [:]) { result, entry in
            let (key, root) = entry
            var visited: Set<Int> = []
            var stack = [root]
            var usage = SimulatorResourceUsage(processCount: 0, memoryBytes: 0, cpuPercent: 0)
            while let pid = stack.popLast() {
                guard visited.insert(pid).inserted, cpu[pid] != nil else { continue }
                usage = SimulatorResourceUsage(
                    processCount: usage.processCount + 1,
                    memoryBytes: usage.memoryBytes + (bytes[pid] ?? 0),
                    cpuPercent: usage.cpuPercent + (cpu[pid] ?? 0)
                )
                stack.append(contentsOf: children[pid] ?? [])
            }
            if usage.processCount > 0 { result[key] = usage }
        }
    }

    static func parseProcesses(_ output: String) -> ([Int: [Int]], [Int: Double]) {
        var children: [Int: [Int]] = [:]
        var cpu: [Int: Double] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  let pid = Int(fields[0]), let parent = Int(fields[1]),
                  let percent = Double(fields[2]) else { continue }
            children[parent, default: []].append(pid)
            cpu[pid] = percent
        }
        return (children, cpu)
    }

    static func parseMemory(_ output: String) -> [Int: Int64] {
        var bytes: [Int: Int64] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let pid = Int(fields[0]),
                  let value = memoryBytes(String(fields[1])) else { continue }
            bytes[pid] = value
        }
        return bytes
    }

    static func memoryBytes(_ raw: String) -> Int64? {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        guard let suffix = value.last else { return nil }
        let multiplier: Double
        switch suffix {
        case "K": multiplier = 1_024
        case "M": multiplier = 1_048_576
        case "G": multiplier = 1_073_741_824
        case "B": multiplier = 1
        default: return Int64(value)
        }
        guard let number = Double(value.dropLast()) else { return nil }
        return Int64(number * multiplier)
    }
}
