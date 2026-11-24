import Foundation

enum Shell {
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment extraEnv: [String: String] = [:],
        stdin: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runSync(
                        executable, arguments,
                        environment: extraEnv, stdin: stdin, timeout: timeout
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runSync(
        _ executable: String,
        _ arguments: [String] = [],
        environment extraEnv: [String: String] = [:],
        stdin: String? = nil,
        timeout: TimeInterval? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        env["PATH"] = "\(extraPath):\(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")"
        for (key, value) in extraEnv { env[key] = value }
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let input = stdin.map { _ in Pipe() }
        if let input { process.standardInput = input }
        try process.run()
        if let input, let stdin {
            let writer = input.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? writer.close() }
                try? writer.write(contentsOf: Data(stdin.utf8))
            }
        }

        var timedOut = false
        let deadline = timeout.map { DispatchTime.now() + $0 }
        let watchdog: DispatchWorkItem? = deadline.map { _ in
            DispatchWorkItem {
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
        }
        if let deadline, let watchdog {
            DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
        }
        defer { watchdog?.cancel() }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        if timedOut {
            throw ShellError.timeout(executable)
        }

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    static func which(_ name: String) -> String? {
        guard let result = try? runSync("/usr/bin/which", [name]), result.ok else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

enum ShellError: LocalizedError {
    case timeout(String)
    case notExecutable(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let exe): return "\(exe) timed out."
        case .notExecutable(let path): return "Not executable: \(path)"
        }
    }
}
