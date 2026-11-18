import Foundation

enum Ini {
    static func write(_ url: URL, values: [String: String]) throws {
        let text = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func read(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }

    static func remove(_ url: URL, keys: Set<String>) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { return true }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            return !keys.contains(key)
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func patch(_ url: URL, values: [String: String]) {
        var lines: [String] = []
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            lines = text.components(separatedBy: "\n")
        }
        var remaining = values
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            if let newValue = remaining.removeValue(forKey: key) {
                lines[index] = "\(key)=\(newValue)"
            }
        }
        for key in remaining.keys.sorted() {
            lines.append("\(key)=\(remaining[key]!)")
        }
        let output = lines.joined(separator: "\n")
        try? output.write(to: url, atomically: true, encoding: .utf8)
    }
}
