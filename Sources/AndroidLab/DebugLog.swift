import Foundation

enum DebugLog {
    private static let queue = DispatchQueue(label: "com.androidlab.log")
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AndroidLab")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    static func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
