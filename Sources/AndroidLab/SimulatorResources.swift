import Darwin
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

struct SimulatorResourceUsage: Equatable {
    let processCount: Int
    let measuredProcessCount: Int
    let memoryBytes: Int64
    /// Sum of macOS process %CPU values; multicore simulators can exceed 100%.
    let cpuPercent: Double

    var memoryLabel: String {
        guard measuredProcessCount > 0 else { return "—" }
        let value = ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .memory)
        return measuredProcessCount == processCount ? value : "≥" + value
    }
}

@MainActor
final class SimulatorResourceMonitor: ObservableObject {
    @Published private(set) var readings: [String: SimulatorResourceUsage] = [:]

    func refresh(_ targets: [SimulatorResourceTarget]) async {
        guard !targets.isEmpty else {
            if !readings.isEmpty { readings = [:] }
            return
        }
        let result = try? await SimulatorResourceSampler.sample(targets)
        guard !Task.isCancelled else { return }
        let next = result ?? [:]
        if readings != next { readings = next }
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
        .help("Host CPU and summed process memory for this simulator; refreshed every 5 seconds. CPU may exceed 100% on multiple cores. ≥ marks a partial RAM reading.")
    }
}

/// Take one process tree snapshot, then read physical footprint only for the target descendants.
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

        let processes = try await Shell.run("/bin/ps", ["-axo", "pid,ppid,%cpu"], timeout: 10)
        guard processes.ok else { return [:] }
        let (children, cpu) = parseProcesses(processes.stdout)
        return roots.compactMapValues { root in
            guard cpu[root] != nil else { return nil }
            var stack = [root]
            var visited: Set<Int> = []
            var totalCPU = 0.0
            var totalBytes: Int64 = 0
            var measured = 0
            while let pid = stack.popLast() {
                guard visited.insert(pid).inserted else { continue }
                totalCPU += cpu[pid] ?? 0
                if let bytes = physicalFootprint(pid: pid) {
                    totalBytes += bytes
                    measured += 1
                }
                stack.append(contentsOf: children[pid] ?? [])
            }
            return SimulatorResourceUsage(processCount: visited.count, measuredProcessCount: measured,
                                          memoryBytes: totalBytes, cpuPercent: totalCPU)
        }
    }

    static func physicalFootprint(pid: Int) -> Int64? {
        guard let pid = Int32(exactly: pid), pid > 0 else { return nil }
        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        return result == 0 ? Int64(usage.ri_phys_footprint) : nil
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

}
