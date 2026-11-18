import Foundation

public struct TaskPurposePresentation: Equatable, Sendable {
    public let previewLines: [String]
    public let allLines: [String]
    public let isTruncated: Bool

    public init(
        previewLines: [String],
        allLines: [String],
        isTruncated: Bool
    ) {
        self.previewLines = previewLines
        self.allLines = allLines
        self.isTruncated = isTruncated
    }

    public var isEmpty: Bool {
        allLines.isEmpty
    }
}

public enum TaskDescriptionFormatter {
    public static func presentation(
        title: String,
        description: String?,
        previewLimit: Int = 3,
        maximumLineLength: Int = 48
    ) -> TaskPurposePresentation {
        guard let raw = TitleSanitizer.cleanedTaskText(description) else {
            return TaskPurposePresentation(
                previewLines: [],
                allLines: [],
                isTruncated: false
            )
        }
        let normalizedTitle = normalize(title)
        let normalizedRaw = normalize(raw)
        guard normalizedTitle != normalizedRaw else {
            return TaskPurposePresentation(
                previewLines: [],
                allLines: [],
                isTruncated: false
            )
        }

        let filteredLines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                var value = String(line)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(
                        of: #"^[#>*\-\u2022\s]+"#,
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                value = removingRoleBoilerplate(from: value)
                let lower = value.lowercased()
                guard !value.isEmpty,
                      normalize(value) != normalizedTitle,
                      !lower.contains("agents.md instructions"),
                      !lower.hasPrefix("you are an ai"),
                      !lower.hasPrefix("you are codex"),
                      !lower.hasPrefix("system instructions"),
                      !lower.hasPrefix("developer instructions"),
                      !(value.hasPrefix("<") && value.hasSuffix(">")),
                      !isPathOnly(value) else {
                    return nil
                }
                value = value.replacingOccurrences(
                    of: #"([.!?。！？])\s+"#,
                    with: "$1\n",
                    options: .regularExpression
                )
                return value
            }

        var allLines: [String] = []
        for paragraph in filteredLines {
            for sentence in paragraph.split(whereSeparator: \.isNewline) {
                let value = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                if allLines.last != value {
                    allLines.append(value)
                }
            }
        }
        let limit = max(1, previewLimit)
        var previewLostContent = allLines.count > limit
        let previewLines = allLines.prefix(limit).map { value -> String in
            let shortened = shortenedPreview(
                value,
                maximumLength: maximumLineLength
            )
            previewLostContent = previewLostContent || shortened.1
            return shortened.0
        }
        return TaskPurposePresentation(
            previewLines: previewLines,
            allLines: allLines,
            isTruncated: previewLostContent
        )
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
                    .union(.punctuationCharacters)
            )
            .lowercased()
    }

    private static func isPathOnly(_ value: String) -> Bool {
        let tokens = value.split(whereSeparator: \.isWhitespace)
        guard tokens.count == 1 else { return false }
        let token = String(tokens[0]).trimmingCharacters(
            in: CharacterSet(charactersIn: "`'\"()[]<>")
        )
        return token.hasPrefix("/")
            || token.hasPrefix("~/")
            || token.hasPrefix("$HOME/")
    }

    private static func removingRoleBoilerplate(from value: String) -> String {
        let prefixes = [
            "구현 담당입니다",
            "구현 담당자입니다",
            "구현을 담당합니다",
            "저는 구현 담당",
            "저는 개발 담당",
            "i am the implementation",
            "i'm the implementation",
            "implementation owner",
            "development owner",
            "this agent is responsible for implementation"
        ]
        var result = value
        var changed = true
        while changed {
            changed = false
            let lower = result.lowercased()
            for prefix in prefixes where lower.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                    .trimmingCharacters(
                        in: CharacterSet.whitespacesAndNewlines
                            .union(CharacterSet(charactersIn: ".:：-"))
                    )
                changed = true
                break
            }
        }
        return result
    }

    private static func shortenedPreview(
        _ value: String,
        maximumLength: Int
    ) -> (String, Bool) {
        guard value.count > maximumLength else { return (value, false) }
        var prefix = String(value.prefix(max(1, maximumLength - 1)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let boundary = prefix.lastIndex(where: \.isWhitespace),
           boundary > prefix.startIndex {
            prefix = String(prefix[..<boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        prefix = prefix.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ".,;:!?。！？"))
        )
        return (prefix + "…", true)
    }
}
