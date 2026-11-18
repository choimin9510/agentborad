import Foundation

public enum AgentsIntegrationError: Error, LocalizedError {
    case invalidUTF8
    case malformedDelimiters(begin: Int, end: Int)
    case missingBlock
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "AGENTS 파일이 UTF-8이 아닙니다."
        case .malformedDelimiters(let begin, let end):
            return "AgentBoard 블록 구분자가 올바르지 않습니다 (시작 \(begin), 끝 \(end))."
        case .missingBlock:
            return "AgentBoard 블록을 찾을 수 없습니다."
        case .writeFailed(let message):
            return "AGENTS 파일을 저장할 수 없습니다: \(message)"
        }
    }
}

public struct AgentsEditResult: Equatable, Sendable {
    public let data: Data
    public let usedLeadingSeparator: Bool

    public init(data: Data, usedLeadingSeparator: Bool) {
        self.data = data
        self.usedLeadingSeparator = usedLeadingSeparator
    }
}

public enum AgentsIntegration {
    public static let beginMarker = "<!-- AGENTBOARD:BEGIN v1 -->"
    public static let endMarker = "<!-- AGENTBOARD:END v1 -->"

    public static func install(
        existing: Data,
        block: Data
    ) throws -> AgentsEditResult {
        let existingText = try text(existing)
        var managed = try text(block)
        if !managed.hasSuffix("\n") {
            managed += "\n"
        }
        let boundaries = delimiterOccurrences(existingText)
        if boundaries.begin == 0 && boundaries.end == 0 {
            if existingText.isEmpty {
                return AgentsEditResult(
                    data: Data(managed.utf8),
                    usedLeadingSeparator: false
                )
            }
            let separator = existingText.hasSuffix("\n") ? "" : "\n"
            return AgentsEditResult(
                data: Data((existingText + separator + managed).utf8),
                usedLeadingSeparator: !separator.isEmpty
            )
        }
        guard boundaries.begin == 1, boundaries.end == 1 else {
            throw AgentsIntegrationError.malformedDelimiters(
                begin: boundaries.begin,
                end: boundaries.end
            )
        }
        guard let existingRange = managedRange(in: existingText) else {
            throw AgentsIntegrationError.malformedDelimiters(
                begin: boundaries.begin,
                end: boundaries.end
            )
        }
        var range = existingRange
        if range.upperBound < existingText.endIndex,
           existingText[range.upperBound] == "\n" {
            range = range.lowerBound..<existingText.index(after: range.upperBound)
        }
        var replacement = existingText
        replacement.replaceSubrange(range, with: managed)
        return AgentsEditResult(
            data: Data(replacement.utf8),
            usedLeadingSeparator: false
        )
    }

    public static func remove(
        existing: Data,
        removeLeadingSeparator: Bool
    ) throws -> Data {
        let existingText = try text(existing)
        let boundaries = delimiterOccurrences(existingText)
        if boundaries.begin == 0 && boundaries.end == 0 {
            return existing
        }
        guard boundaries.begin == 1, boundaries.end == 1,
              let managed = managedRange(in: existingText) else {
            throw AgentsIntegrationError.malformedDelimiters(
                begin: boundaries.begin,
                end: boundaries.end
            )
        }
        var removalStart = managed.lowerBound
        var removalEnd = managed.upperBound
        if removalEnd < existingText.endIndex,
           existingText[removalEnd] == "\n" {
            removalEnd = existingText.index(after: removalEnd)
        }
        let hasFollowingContent = removalEnd < existingText.endIndex
        if removeLeadingSeparator,
           !hasFollowingContent,
           removalStart > existingText.startIndex {
            let previous = existingText.index(before: removalStart)
            if existingText[previous] == "\n" {
                removalStart = previous
            }
        }
        var result = existingText
        result.removeSubrange(removalStart..<removalEnd)
        return Data(result.utf8)
    }

    public static func validate(_ data: Data) throws {
        let value = try text(data)
        let counts = delimiterOccurrences(value)
        if counts.begin != counts.end
            || (counts.begin == 1 && managedRange(in: value) == nil)
            || counts.begin > 1 {
            throw AgentsIntegrationError.malformedDelimiters(
                begin: counts.begin,
                end: counts.end
            )
        }
    }

    public static func writeFile(
        _ data: Data,
        to url: URL,
        createPermissions: NSNumber = NSNumber(value: 0o600)
    ) throws {
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions]
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: permissions ?? createPermissions],
                ofItemAtPath: url.path
            )
        } catch {
            throw AgentsIntegrationError.writeFailed(error.localizedDescription)
        }
    }

    private static func text(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw AgentsIntegrationError.invalidUTF8
        }
        return value
    }

    private static func delimiterOccurrences(_ text: String) -> (begin: Int, end: Int) {
        (
            text.components(separatedBy: beginMarker).count - 1,
            text.components(separatedBy: endMarker).count - 1
        )
    }

    private static func managedRange(in text: String) -> Range<String.Index>? {
        guard let begin = text.range(of: beginMarker),
              let end = text.range(of: endMarker),
              begin.upperBound <= end.lowerBound else {
            return nil
        }
        return begin.lowerBound..<end.upperBound
    }
}
