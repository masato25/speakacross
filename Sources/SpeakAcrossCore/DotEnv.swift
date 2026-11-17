import Foundation

public enum DotEnv {
    public static func value(
        for key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let direct = cleaned(environment[key]) {
            return direct
        }

        for url in candidateFiles(environment: environment) {
            if let value = parseFile(url)[key], let cleaned = cleaned(value) {
                return cleaned
            }
        }

        return nil
    }

    public static func candidateFiles(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var candidates: [URL] = []

        if let explicit = cleaned(environment["SPEAKACROSS_ENV_FILE"]) {
            candidates.append(URL(fileURLWithPath: explicit))
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(".env"))

        var executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent()

        for _ in 0..<6 {
            candidates.append(executableDirectory.appendingPathComponent(".env"))
            let parent = executableDirectory.deletingLastPathComponent()
            if parent.path == executableDirectory.path { break }
            executableDirectory = parent
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
            }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)

            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"") ||
                value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }

            if !key.isEmpty {
                values[key] = value
            }
        }

        return values
    }

    private static func parseFile(_ url: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        return parse(contents)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
