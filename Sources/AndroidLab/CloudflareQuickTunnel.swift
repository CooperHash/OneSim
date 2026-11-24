import Foundation

@MainActor
final class CloudflareQuickTunnel {
    private let process = Process()
    private let lifetime = Pipe()
    private var timedOut = false

    static var executable: URL? {
        [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cloudflared"),
         URL(fileURLWithPath: "/opt/homebrew/bin/cloudflared"),
         URL(fileURLWithPath: "/usr/local/bin/cloudflared")].first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    nonisolated static func origin(in line: String) -> URL? {
        for word in line.split(whereSeparator: \.isWhitespace) {
            let text = String(word)
            if text.range(of: #"\Ahttps://[a-z0-9]+(?:-[a-z0-9]+)*\.trycloudflare\.com\z"#,
                          options: .regularExpression) != nil {
                return URL(string: text)
            }
        }
        return nil
    }

    func run(port: Int, onReady: (URL) async throws -> Void) async throws {
        guard let executable = Self.executable else {
            throw SetupError("Install cloudflared with brew install cloudflared, then enable Public Access again.")
        }
        try Task.checkCancellation()
        defer { stop() }
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // EOF on the app-owned pipe also stops the connector after an unexpected app exit.
        let supervise = """
        exec 3<&0
        "$@" </dev/null 3<&- &
        connector=$!
        (read -r unused <&3; kill -TERM "$connector" 2>/dev/null) &
        watcher=$!
        wait "$connector"
        status=$?
        kill "$watcher" 2>/dev/null
        wait "$watcher" 2>/dev/null
        exit "$status"
        """
        process.arguments = ["-c", supervise, "SimLab", executable.path, "tunnel", "--config", "/dev/null",
                             "--no-autoupdate", "--protocol", "auto", "--grace-period", "1s",
                             "--metrics", "127.0.0.1:0", "--url", "http://127.0.0.1:\(port)"]
        process.standardInput = lifetime
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TUNNEL_") }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try? output.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close() }

        let timeout = Task {
            try await Task.sleep(for: .seconds(60))
            timedOut = true
            stop()
        }
        defer { timeout.cancel() }
        var origin: URL?
        var registered = false
        var announced = false
        for try await line in output.fileHandleForReading.bytes.lines {
            try Task.checkCancellation()
            guard !timedOut else { break }
            if !announced {
                if origin == nil { origin = Self.origin(in: line) }
                if line.contains("Registered tunnel connection") { registered = true }
                if let origin, registered {
                    timeout.cancel()
                    try await onReady(origin)
                    announced = true
                }
            }
        }
        try Task.checkCancellation()
        if timedOut {
            throw SetupError("Cloudflare did not connect within 60 seconds. Check internet access and outbound TCP port 7844, then retry.")
        }
        throw SetupError(announced ? "The Cloudflare tunnel closed. Enable Public Access again to get a new link."
                                    : "Cloudflare could not start the tunnel. Check your network and try again.")
    }

    func stop() {
        try? lifetime.fileHandleForWriting.close()
    }
}
