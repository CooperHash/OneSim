import Foundation
import QuartzCore

/// Opt-in counters for repeatable profiling; no per-frame I/O in normal runs.
enum PerformanceMetrics {
    static let enabled = ProcessInfo.processInfo.environment["ANDROIDLAB_PERF"] == "1"
    private static let lock = NSLock()
    private static var samples: [String: (start: Double, count: Int, bytes: Int, last: Double, maxGap: Double)] = [:]
    static func record(_ name: String, bytes: Int = 0) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        var value = samples[name] ?? (now, 0, 0, now, 0)
        value.count += 1
        value.bytes += bytes
        value.maxGap = max(value.maxGap, now - value.last)
        value.last = now
        if now - value.start >= 5 {
            DebugLog.write(String(format: "PERF %@ count=%d fps=%.2f MBps=%.2f maxGapMs=%.1f", name, value.count, Double(value.count) / (now-value.start), Double(value.bytes) / (now-value.start) / 1_000_000, value.maxGap * 1000))
            value = (now, 0, 0, now, 0)
        }
        samples[name] = value
        lock.unlock()
    }
}
