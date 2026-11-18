import AgentBoardCore
import Foundation

struct LaunchOptions {
    let codexHomes: [URL]
    let dataDirectory: URL?
    let reportHelperPath: String?
    let demo: Bool
    let ingestOnce: Bool

    var codexHome: URL { codexHomes[0] }

    static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> LaunchOptions {
        var explicitCodexHomes: [URL] = []
        var dataDirectory: URL?
        var reportHelperPath: String?
        var demo = false
        var ingestOnce = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--demo":
                demo = true
            case "--ingest-once":
                ingestOnce = true
            case "--codex-home", "--data-dir", "--report-helper":
                let flag = arguments[index]
                guard index + 1 < arguments.count else {
                    throw LaunchOptionError.missingValue(flag)
                }
                let value = URL(
                    fileURLWithPath: arguments[index + 1],
                    isDirectory: true
                )
                if flag == "--codex-home" {
                    explicitCodexHomes.append(value)
                } else if flag == "--report-helper" {
                    reportHelperPath = value.path
                } else {
                    dataDirectory = value
                }
                index += 1
            default:
                if arguments[index].hasPrefix("--codex-home=") {
                    let value = String(arguments[index].dropFirst("--codex-home=".count))
                    explicitCodexHomes.append(
                        URL(fileURLWithPath: value, isDirectory: true)
                    )
                } else if arguments[index].hasPrefix("--data-dir=") {
                    let value = String(arguments[index].dropFirst("--data-dir=".count))
                    dataDirectory = URL(fileURLWithPath: value, isDirectory: true)
                } else if arguments[index].hasPrefix("--report-helper=") {
                    reportHelperPath = String(
                        arguments[index].dropFirst("--report-helper=".count)
                    )
                } else {
                    throw LaunchOptionError.unknown(arguments[index])
                }
            }
            index += 1
        }
        var candidates = explicitCodexHomes
        if explicitCodexHomes.isEmpty {
            candidates = [
                homeDirectory.appendingPathComponent(
                    ".codex",
                    isDirectory: true
                ),
                homeDirectory.appendingPathComponent(
                    ".codex-ds",
                    isDirectory: true
                )
            ]
            if let environmentHome = environment["CODEX_HOME"],
               !environmentHome.isEmpty {
                candidates.append(
                    URL(
                        fileURLWithPath: environmentHome,
                        isDirectory: true
                    )
                )
            }
        }
        var seen = Set<String>()
        let codexHomes = candidates.compactMap { candidate -> URL? in
            let standardized = candidate.standardizedFileURL
            let normalized = FileManager.default.fileExists(
                atPath: standardized.path
            )
                ? standardized.resolvingSymlinksInPath()
                : standardized
            return seen.insert(normalized.path).inserted
                ? normalized
                : nil
        }
        precondition(!codexHomes.isEmpty)
        return LaunchOptions(
            codexHomes: codexHomes,
            dataDirectory: dataDirectory,
            reportHelperPath: reportHelperPath,
            demo: demo,
            ingestOnce: ingestOnce
        )
    }

    func databaseURL() throws -> URL {
        if let dataDirectory {
            try FileManager.default.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: true
            )
            return dataDirectory.appendingPathComponent("agentboard.sqlite3")
        }
        return try StateStore.applicationSupportDatabaseURL()
    }
}

private enum LaunchOptionError: Error, LocalizedError {
    case missingValue(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag): return "\(flag) 값이 필요합니다."
        case .unknown(let argument): return "알 수 없는 인자입니다: \(argument)"
        }
    }
}
