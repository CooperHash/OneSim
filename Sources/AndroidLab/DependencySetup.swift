import Foundation
import CryptoKit

struct DependencySetup {
    struct Package: Identifiable, Sendable {
        let id: String
        let name: String
        let archive: URL
        let bytes: Int64
        let sha1: String
        let archiveDirectory: String
    }

    static let packages = [
        Package(id: "platform-tools", name: "Android adb",
                archive: URL(string: "https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip")!,
                bytes: 16_110_554, sha1: "6ae73f4de6452dc57e62ec02b68eed92a4c21661", archiveDirectory: "platform-tools"),
        Package(id: "emulator", name: "Android Emulator (Apple silicon)",
                archive: URL(string: "https://dl.google.com/android/repository/emulator-darwin_aarch64-16740729.zip")!,
                bytes: 416_113_219, sha1: "6c5e61b873e11c7d1d08683bea089f762baee070", archiveDirectory: "emulator"),
        Package(id: "system-images/android-36/google_apis/arm64-v8a", name: "Android API 36 Google APIs image (ARM64)",
                archive: URL(string: "https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-36_r07.zip")!,
                bytes: 1_872_691_175, sha1: "5a99183b6d924da606260e45fd41a3eb8eca6eb7", archiveDirectory: "arm64-v8a"),
    ]

    struct Report {
        var android: [Package]
        var xcode: InstalledXcode?
        var ios: XcodeRuntimeSetup.Inventory?
        var iosIssue: String?
        var xcodeNeedsSetup = false
        var iosPlan: XcodeRuntimeSetup.Plan? { xcodeNeedsSetup ? nil : ios?.plan }
        var platformError: String? {
            #if arch(arm64)
            nil
            #else
            "SimLab requires an Apple silicon Mac."
            #endif
        }
        var isReady: Bool { android.isEmpty && platformError == nil }
    }

    static func scan(paths: ToolPaths) async -> Report {
        var report = Report(android: missingAndroidPackages(paths: paths))
        report.xcode = await XcodeToolchain.activeXcode()
        guard report.xcode != nil else {
            report.iosIssue = "A full Xcode installation is needed for iPhone simulators. Choose or download one in Xcode Versions."
            return report
        }
        do {
            report.ios = try await XcodeRuntimeSetup.inventory()
            if report.ios?.plan == nil { return report }
        } catch {
            report.iosIssue = error.localizedDescription
        }
        if let firstLaunch = try? await Shell.run("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"], timeout: 12),
           !firstLaunch.ok {
            report.xcodeNeedsSetup = true
            report.iosIssue = "The selected Xcode needs its first-launch components before it can install an iOS Runtime."
        }
        return report
    }

    static func missingAndroidPackages(paths: ToolPaths) -> [Package] {
        packages.filter { !hasPackage($0, paths: paths) }
    }

    static func hasPackage(_ package: Package, paths: ToolPaths) -> Bool {
        let fm = FileManager.default
        switch package.id {
        case "platform-tools": return fm.isExecutableFile(atPath: paths.adb)
        case "emulator": return fm.isExecutableFile(atPath: paths.emulator)
        default:
            return AndroidRepository.listImages(paths: paths).contains { $0.abi == "arm64-v8a" } ||
                AndroidRepository.hasUsableARM64Device(paths: paths)
        }
    }

    static func defaultAndroidImage(from images: [SystemImage]) -> SystemImage? {
        images.first { $0 == AndroidSlimClient.defaultImage } ?? images.first { $0.abi == "arm64-v8a" }
    }

    static func download(_ package: Package, to root: URL,
                         progress: @escaping @Sendable (Int64, String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let parts = try await fetch(package, staging: staging) { bytes in
            progress(bytes, "Downloading \(package.name)")
        }
        progress(package.bytes, "Verifying \(package.name)")
        let file = try verifiedArchive(parts: parts, staging: staging, package: package)
        try Task.checkCancellation()
        progress(package.bytes, "Extracting \(package.name)")
        let expanded = staging.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: expanded, withIntermediateDirectories: false)
        // The Google API 36 archive contains ZIP64 entries.
        let result = try await Shell.run("/usr/bin/tar", ["-xf", file.path, "-C", expanded.path], timeout: 240)
        guard result.ok else { throw SetupError(result.combined) }
        let source = expanded.appendingPathComponent(package.archiveDirectory, isDirectory: true)
        let installSource: URL
        if package.id == "platform-tools" {
            installSource = staging.appendingPathComponent("minimal-tools", isDirectory: true)
            try fm.createDirectory(at: installSource, withIntermediateDirectories: false)
            for name in ["adb", "NOTICE.txt"] where fm.fileExists(atPath: source.appendingPathComponent(name).path) {
                try fm.moveItem(at: source.appendingPathComponent(name), to: installSource.appendingPathComponent(name))
            }
        } else {
            installSource = source
        }
        let installed = root.appendingPathComponent(package.id, isDirectory: true)
        let sentinel = package.id == "platform-tools" ? "adb" : package.id == "emulator" ? "emulator" : "system.img"
        guard fm.fileExists(atPath: installSource.appendingPathComponent(sentinel).path) else {
            throw SetupError("The \(package.name) archive is missing \(sentinel).")
        }
        try Task.checkCancellation()
        try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: installed.path) {
            _ = try fm.replaceItemAt(installed, withItemAt: installSource)
        } else {
            try fm.moveItem(at: installSource, to: installed)
        }
    }

    /// Google serves these archives with `Content-Encoding: gzip` when the client
    /// accepts it. A byte range of that gzip stream is not a valid gzip member, so
    /// URLSession fails with "cannot decode raw data". Ask for the raw archive.
    static func archiveRequest(for package: Package, bytes begin: Int64? = nil, end: Int64? = nil) -> URLRequest {
        var request = URLRequest(url: package.archive)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 90
        if let begin, let end {
            request.setValue("bytes=\(begin)-\(end)", forHTTPHeaderField: "Range")
        }
        return request
    }

    private static func fetch(_ package: Package, staging: URL,
                              progress: @escaping @Sendable (Int64) -> Void) async throws -> [URL] {
        let archive = staging.appendingPathComponent("package.zip")
        if package.bytes < 512_000_000 {
            let response = try await transfer(archiveRequest(for: package), to: archive, progress: progress)
            try validate(response, package: package, file: archive)
            return [archive]
        }

        let partCount = 4
        let counter = ByteCounter(progress)
        let partSize = (package.bytes + Int64(partCount) - 1) / Int64(partCount)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<partCount {
                group.addTask {
                    let begin = Int64(index) * partSize
                    let end = min(package.bytes - 1, begin + partSize - 1)
                    let part = staging.appendingPathComponent("part-\(index)")
                    let request = archiveRequest(for: package, bytes: begin, end: end)
                    for attempt in 1...3 {
                        do {
                            let response = try await transfer(request, to: part) { bytes in
                                counter.update(index, bytes: bytes)
                            }
                            try validate(response, package: package, file: part, range: (begin, end))
                            break
                        } catch let error as URLError where attempt < 3 && error.code != .cancelled {
                            try? FileManager.default.removeItem(at: part)
                            try await Task.sleep(for: .seconds(attempt))
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        return (0..<partCount).map { staging.appendingPathComponent("part-\($0)") }
    }

    private static func validate(_ response: HTTPURLResponse, package: Package, file: URL,
                                 range: (begin: Int64, end: Int64)? = nil) throws {
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
           encoding.caseInsensitiveCompare("identity") != .orderedSame {
            throw SetupError("Google compressed \(package.name) instead of sending the archive.")
        }
        let count = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
        if let range {
            guard response.statusCode == 206,
                  response.value(forHTTPHeaderField: "Content-Range") == "bytes \(range.begin)-\(range.end)/\(package.bytes)",
                  count == range.end - range.begin + 1 else {
                throw SetupError("Google returned an invalid byte range for \(package.name).")
            }
        } else {
            guard response.statusCode == 200, count == package.bytes else {
                throw SetupError("Google could not provide \(package.name).")
            }
        }
    }

    private static func transfer(_ request: URLRequest, to destination: URL,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
        let download = FileDownload(destination: destination, progress: progress)
        return try await download.start(request)
    }

    private final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [Int: Int64] = [:]
        private let report: @Sendable (Int64) -> Void

        init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }

        func update(_ index: Int, bytes: Int64) {
            let total = lock.withLock {
                parts[index] = bytes
                return parts.values.reduce(0, +)
            }
            report(total)
        }
    }

    /// Hash in download order while assembling the image. Single-file downloads are verified in place.
    static func verifiedArchive(parts: [URL], staging: URL, package: Package) throws -> URL {
        guard let first = parts.first else { throw SetupError("Missing archive for \(package.name).") }
        let archive = parts.count == 1 ? first : staging.appendingPathComponent("package.zip")
        var output: FileHandle?
        if parts.count > 1 {
            try Data().write(to: archive, options: .withoutOverwriting)
            output = try FileHandle(forWritingTo: archive)
        }
        defer { try? output?.close() }
        var hash = Insecure.SHA1()
        var count: Int64 = 0
        for part in parts {
            let file = try FileHandle(forReadingFrom: part)
            defer { try? file.close() }
            while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                count += Int64(bytes.count)
                hash.update(data: bytes)
                try output?.write(contentsOf: bytes)
            }
            if output != nil { try FileManager.default.removeItem(at: part) }
        }
        try output?.close()
        output = nil
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == package.bytes && digest == package.sha1 else {
            throw SetupError("Integrity check failed for \(package.name).")
        }
        return archive
    }

    /// The async `URLSession.download(for:delegate:)` API does not deliver
    /// `didWriteData` callbacks, so the setup sheet stayed at 0%.
    private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let progress: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
        private var response: HTTPURLResponse?
        private var moveError: Error?
        private var session: URLSession!

        init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
            self.destination = destination
            self.progress = progress
            super.init()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 30 * 60
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }

        func start(_ request: URLRequest) async throws -> HTTPURLResponse {
            let task = session.downloadTask(with: request)
            progress(0)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    self.continuation = continuation
                    lock.unlock()
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: location, to: destination)
                response = downloadTask.response as? HTTPURLResponse
            } catch {
                moveError = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: Result<HTTPURLResponse, Error>
            if let error {
                result = .failure(error)
            } else if let moveError {
                result = .failure(moveError)
            } else if let response {
                result = .success(response)
            } else {
                result = .failure(SetupError("The download finished without a response."))
            }
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            session.finishTasksAndInvalidate()
        }
    }
}

struct SetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
