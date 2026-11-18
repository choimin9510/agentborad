import Foundation

public struct ReportTrustPolicy: Equatable, Sendable {
    public let helperPaths: Set<String>

    public init(helperPaths: Set<String>) {
        self.helperPaths = helperPaths
    }

    public init(additionalHelperPaths: [String] = []) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: Set<String> = [
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".local/bin/agentboard")
                .path,
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Applications/AgentBoard.app/Contents/MacOS/agentboard")
                .path
        ]
        for path in additionalHelperPaths where !path.isEmpty {
            paths.insert(Self.expand(path, home: home))
        }
        self.helperPaths = paths
    }

    public static var `default`: ReportTrustPolicy {
        ReportTrustPolicy()
    }

    public func accepts(_ executable: String) -> Bool {
        helperPaths.contains(Self.expand(executable))
    }

    private static func expand(_ path: String, home: String? = nil) -> String {
        let resolvedHome = home ?? FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~/.local/bin/agentboard" {
            return resolvedHome + "/.local/bin/agentboard"
        }
        if path == "$HOME/.local/bin/agentboard" {
            return resolvedHome + "/.local/bin/agentboard"
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
