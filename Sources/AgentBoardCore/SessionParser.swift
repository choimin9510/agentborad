import Foundation

public enum SessionSignal: Equatable, Sendable {
    case sessionMeta(SessionHeader)
    case taskStarted(turnId: String?)
    case userMessage(text: String, turnId: String?)
    case taskComplete(turnId: String?)
    case turnAborted(reason: String, turnId: String?)
    case turnContext(turnId: String?, model: String?)
    case toolCall(callId: String, eligibleForReport: Bool, toolName: String)
    case toolOutput(callId: String, text: String)
    case agentActivity
    case activity
}

public struct ParsedRecord: Equatable, Sendable {
    public let timestamp: Date
    public let signal: SessionSignal

    public init(timestamp: Date, signal: SessionSignal) {
        self.timestamp = timestamp
        self.signal = signal
    }
}

public enum SessionLineParser {
    public static let maximumLineBytes = 1_048_576
    public static let maximumToolOutputCharacters = 262_144
    public static let reportMarker = "AGENTBOARD_EVENT_V1 "

    public static func parse(
        _ data: Data,
        fallbackDate: Date = Date(),
        trustPolicy: ReportTrustPolicy = .default
    ) -> ParsedRecord? {
        guard data.count <= maximumLineBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return nil
        }
        let timestamp = AgentBoardDate.parse(root["timestamp"] as? String) ?? fallbackDate
        guard let type = root["type"] as? String,
              let payload = root["payload"] as? [String: Any] else {
            return nil
        }

        switch type {
        case "session_meta":
            guard let idString = payload["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let source = payload["source"] as? String else {
                return nil
            }
            let header = SessionHeader(
                id: id,
                source: source,
                cwd: payload["cwd"] as? String,
                modelProvider: payload["model_provider"] as? String,
                originator: payload["originator"] as? String,
                threadSource: payload["thread_source"] as? String,
                cliVersion: payload["cli_version"] as? String,
                historyMode: payload["history_mode"] as? String
            )
            return ParsedRecord(timestamp: timestamp, signal: .sessionMeta(header))

        case "turn_context":
            return ParsedRecord(
                timestamp: timestamp,
                signal: .turnContext(
                    turnId: payload["turn_id"] as? String,
                    model: payload["model"] as? String
                )
            )

        case "event_msg":
            return parseEventMessage(payload, timestamp: timestamp)

        case "response_item":
            return parseResponseItem(
                payload,
                timestamp: timestamp,
                trustPolicy: trustPolicy
            )

        default:
            return nil
        }
    }

    public static func reportCommandsAreValid(
        _ command: String,
        trustPolicy: ReportTrustPolicy = .default
    ) -> Bool {
        let normalized = command.replacingOccurrences(of: "\\\n", with: " ")
        guard !containsUnquotedShellControl(normalized) else { return false }
        let tokens = shellTokens(normalized)
        guard tokens.count >= 4,
              trustPolicy.accepts(tokens[0]),
              tokens[1] == "report",
              tokens[2] == "--json" else {
            return false
        }
        return true
    }

    public static func extractReports(fromToolOutput text: String) -> [ReportEnvelope] {
        var reports: [ReportEnvelope] = []
        for line in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.hasPrefix(reportMarker) else { continue }
            let remainder = String(trimmed.dropFirst(reportMarker.count))
            guard remainder.hasPrefix("{") else { continue }
            guard let candidate = firstBalancedObject(in: remainder) else { continue }
            let trailing = remainder.dropFirst(candidate.count)
            guard trailing.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) else {
                continue
            }
            if let data = candidate.data(using: .utf8),
               let envelope = try? ReportValidator.decodeEnvelope(data) {
                reports.append(envelope)
                if reports.count == 8 { break }
            }
        }
        return reports
    }

    public static func flattenToolOutput(
        _ value: Any,
        limit: Int = maximumToolOutputCharacters
    ) -> String {
        var fragments: [String] = []
        var remaining = limit
        flattenOutput(value, depth: 0, remaining: &remaining, fragments: &fragments)
        return fragments.joined(separator: "\n")
    }

    private static func parseEventMessage(
        _ payload: [String: Any],
        timestamp: Date
    ) -> ParsedRecord? {
        guard let kind = payload["type"] as? String else { return nil }
        switch kind {
        case "task_started":
            return ParsedRecord(
                timestamp: timestamp,
                signal: .taskStarted(turnId: payload["turn_id"] as? String)
            )
        case "task_complete":
            return ParsedRecord(
                timestamp: timestamp,
                signal: .taskComplete(turnId: payload["turn_id"] as? String)
            )
        case "turn_aborted":
            return ParsedRecord(
                timestamp: timestamp,
                signal: .turnAborted(
                    reason: payload["reason"] as? String ?? "interrupted",
                    turnId: payload["turn_id"] as? String
                )
            )
        case "user_message":
            let text = payload["message"] as? String ?? ""
            return ParsedRecord(
                timestamp: timestamp,
                signal: .userMessage(
                    text: text,
                    turnId: payload["turn_id"] as? String
                )
            )
        case "agent_message":
            return ParsedRecord(timestamp: timestamp, signal: .agentActivity)
        case "item_completed":
            return parseCompletedItem(payload, timestamp: timestamp)
        default:
            return ParsedRecord(timestamp: timestamp, signal: .activity)
        }
    }

    private static func parseCompletedItem(
        _ payload: [String: Any],
        timestamp: Date
    ) -> ParsedRecord {
        let item = payload["item"] as? [String: Any]
        let itemType = item?["type"] as? String
        let turnId = payload["turn_id"] as? String
        if itemType == "UserMessage" {
            return ParsedRecord(
                timestamp: timestamp,
                signal: .userMessage(
                    text: contentText(item?["content"]),
                    turnId: turnId
                )
            )
        }
        if itemType == "AgentMessage" {
            return ParsedRecord(timestamp: timestamp, signal: .agentActivity)
        }
        return ParsedRecord(timestamp: timestamp, signal: .activity)
    }

    private static func parseResponseItem(
        _ payload: [String: Any],
        timestamp: Date,
        trustPolicy: ReportTrustPolicy
    ) -> ParsedRecord? {
        guard let type = payload["type"] as? String else { return nil }
        switch type {
        case "message":
            if (payload["role"] as? String) == "user" {
                return ParsedRecord(
                    timestamp: timestamp,
                    signal: .userMessage(
                        text: contentText(payload["content"]),
                        turnId: nil
                    )
                )
            }
            return ParsedRecord(timestamp: timestamp, signal: .agentActivity)

        case "function_call":
            guard let callId = payload["call_id"] as? String else { return nil }
            let toolName = payload["name"] as? String ?? ""
            let command = commandFromArguments(payload["arguments"])
            return ParsedRecord(
                timestamp: timestamp,
                signal: .toolCall(
                    callId: callId,
                    eligibleForReport: supportsCommandExecution(toolName)
                        && (command.map {
                            reportCommandsAreValid($0, trustPolicy: trustPolicy)
                        } ?? false),
                    toolName: toolName
                )
            )

        case "custom_tool_call":
            guard let callId = payload["call_id"] as? String else { return nil }
            let toolName = payload["name"] as? String ?? ""
            let command = commandFromCustomToolInput(payload["input"])
            return ParsedRecord(
                timestamp: timestamp,
                signal: .toolCall(
                    callId: callId,
                    eligibleForReport: supportsCommandExecution(toolName)
                        && (command.map {
                            reportCommandsAreValid($0, trustPolicy: trustPolicy)
                        } ?? false),
                    toolName: toolName
                )
            )

        case "function_call_output", "custom_tool_call_output":
            guard let callId = payload["call_id"] as? String else { return nil }
            let output = flattenToolOutput(payload["output"] as Any)
            return ParsedRecord(
                timestamp: timestamp,
                signal: .toolOutput(callId: callId, text: output)
            )

        case "reasoning":
            return ParsedRecord(timestamp: timestamp, signal: .activity)

        default:
            return nil
        }
    }

    private static func commandFromArguments(_ raw: Any?) -> String? {
        if let dictionary = raw as? [String: Any] {
            return (dictionary["cmd"] as? String) ?? (dictionary["command"] as? String)
        }
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (dictionary["cmd"] as? String) ?? (dictionary["command"] as? String)
    }

    private static func commandFromCustomToolInput(_ raw: Any?) -> String? {
        let text = raw as? String ?? ""
        let toolPattern = #"(?s)(?:tools\.)?(?:exec_command|exec)\s*\("# 
        guard let toolRegex = try? NSRegularExpression(pattern: toolPattern),
              !text.isEmpty else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let utf16 = Array(text.utf16)
        let toolMatches = toolRegex.matches(in: text, range: fullRange).filter {
            !isInsideStringLiteral(utf16, at: $0.range.location)
                && !isInLineComment(utf16, at: $0.range.location)
        }
        guard toolMatches.count == 1 else { return nil }

        let pattern = #"(?s)(?:tools\.)?(?:exec_command|exec)\s*\(.{0,4000}?(?:cmd|command)\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              !text.isEmpty else {
            return nil
        }
        for match in regex.matches(in: text, range: fullRange) {
            guard !isInsideStringLiteral(utf16, at: match.range.location),
                  !isInLineComment(utf16, at: match.range.location),
                  let captureRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let escaped = String(text[captureRange])
            if let quoteData = ("\"\(escaped)\"").data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(
               with: quoteData,
               options: [.fragmentsAllowed]
           ) as? String {
                return decoded
            }
            return escaped
        }
        return nil
    }

    private static func contentText(_ raw: Any?) -> String {
        guard let blocks = raw as? [[String: Any]] else {
            return raw as? String ?? ""
        }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func supportsCommandExecution(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return [
            "exec",
            "exec_command",
            "functions.exec",
            "functions.exec_command"
        ].contains(normalized)
    }

    private static func containsUnquotedShellControl(_ command: String) -> Bool {
        var quote: Character?
        var escaped = false
        let characters = Array(command)
        for index in characters.indices {
            let character = characters[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == ";"
                || character == "&"
                || character == "|"
                || character == ">"
                || character == "<"
                || character == "\n"
                || character == "\r"
                || character == "#"
                || character == "`" {
                return true
            } else if character == "$",
                      characters.indices.contains(index + 1),
                      characters[index + 1] == "(" || characters[index + 1] == "{" {
                return true
            }
        }
        return false
    }

    private static func isInsideStringLiteral(
        _ utf16: [UInt16],
        at location: Int
    ) -> Bool {
        guard location > 0 else { return false }
        var quote: UInt16?
        var escaped = false
        for index in 0..<min(location, utf16.count) {
            let unit = utf16[index]
            if escaped {
                escaped = false
            } else if unit == 0x5C {
                escaped = true
            } else if let activeQuote = quote {
                if unit == activeQuote {
                    quote = nil
                }
            } else if unit == 0x22 || unit == 0x27 || unit == 0x60 {
                quote = unit
            }
        }
        return quote != nil
    }

    private static func isInLineComment(
        _ utf16: [UInt16],
        at location: Int
    ) -> Bool {
        guard location > 0 else { return false }
        var quote: UInt16?
        var escaped = false
        var inComment = false
        for index in 0..<min(location, utf16.count) {
            let unit = utf16[index]
            if inComment {
                if unit == 0x0A {
                    inComment = false
                }
                continue
            }
            if escaped {
                escaped = false
            } else if unit == 0x5C {
                escaped = true
            } else if let activeQuote = quote {
                if unit == activeQuote {
                    quote = nil
                }
            } else if unit == 0x22 || unit == 0x27 || unit == 0x60 {
                quote = unit
            } else if unit == 0x2F,
                      index + 1 < utf16.count,
                      utf16[index + 1] == 0x2F {
                inComment = true
            }
        }
        return inComment
    }

    private static func shellTokens(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in segment {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func flattenOutput(
        _ value: Any,
        depth: Int,
        remaining: inout Int,
        fragments: inout [String]
    ) {
        guard depth <= 8, remaining > 0, fragments.count < 128 else { return }
        if let string = value as? String {
            if let decoded = decodeSerializedOutput(string) {
                flattenOutput(
                    decoded,
                    depth: depth + 1,
                    remaining: &remaining,
                    fragments: &fragments
                )
            } else {
                let part = String(string.prefix(remaining))
                if !part.isEmpty {
                    fragments.append(part)
                    remaining -= part.count
                }
            }
        } else if let array = value as? [Any] {
            for item in array.prefix(128) where remaining > 0 {
                flattenOutput(
                    item,
                    depth: depth + 1,
                    remaining: &remaining,
                    fragments: &fragments
                )
            }
        } else if let dictionary = value as? [String: Any] {
            let outputKeys = [
                "output", "text", "content", "stdout", "stderr",
                "result", "body", "message", "data", "items"
            ]
            for key in outputKeys {
                guard remaining > 0, let nested = dictionary[key] else { continue }
                flattenOutput(
                    nested,
                    depth: depth + 1,
                    remaining: &remaining,
                    fragments: &fragments
                )
            }
        }
    }

    private static func decodeSerializedOutput(_ string: String) -> Any? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if decoded is [String: Any] || decoded is [Any] {
            return decoded
        }
        return nil
    }

    private static func firstBalancedObject(in string: String) -> String? {
        guard let start = string.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < string.endIndex {
            let character = string[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(string[start...index])
                }
            }
            index = string.index(after: index)
        }
        return nil
    }
}

public enum TitleSanitizer {
    public struct TaskIdentity: Equatable, Sendable {
        public let title: String
        public let description: String

        public init(title: String, description: String) {
            self.title = title
            self.description = description
        }
    }

    public struct LegacyInjectionContamination: Equatable, Sendable {
        public let title: String
        public let description: String

        public init(title: String, description: String) {
            self.title = title
            self.description = description
        }
    }

    public static func taskIdentity(
        _ raw: String?,
        fallback: String = ""
    ) -> TaskIdentity? {
        guard let text = cleanedTaskText(raw) else { return nil }
        let title = safeTitle(text, fallback: fallback)
        guard !title.isEmpty, title != fallback else { return nil }
        var description = text
        if description.count > 1_200 {
            description = String(description.prefix(1_199))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return TaskIdentity(title: title, description: description)
    }

    public static func cleanedTaskText(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        text = removingAgentInstructionBlocks(from: text)
        for tag in ["environment_context", "user_instructions", "developer_instructions"] {
            text = removingBlock(tag: tag, from: text)
        }
        let lines = text.split(
            whereSeparator: \.isNewline
        ).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let lower = trimmed.lowercased()
            return !lower.hasPrefix("# agents.md instructions for ")
                && !lower.hasPrefix("these agents.md instructions replace")
                && !(trimmed.hasPrefix("<") && trimmed.hasSuffix(">"))
        }
        text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return text
    }

    public static func safeTitle(_ raw: String?, fallback: String = "새 Codex 작업") -> String {
        guard let text = cleanedTaskText(raw) else { return fallback }
        guard !text.isEmpty, !text.hasPrefix("<") else { return fallback }

        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        var title = firstLine
            .replacingOccurrences(of: #"^[#>*\-\d.\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = fallback
        }
        if title.count > 80 {
            title = String(title.prefix(79)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }

    public static func isUsefulTaskTitle(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count >= 2 else {
            return false
        }
        let generic = [
            "test", "testing", "task", "작업", "검증", "검증 작업",
            "새 codex 작업", "new codex task"
        ]
        return !generic.contains(value.lowercased())
    }

    public static func mergedTaskTitle(
        initialTitle: String,
        existingTitle: String,
        hasExplicitReport: Bool
    ) -> String {
        if hasExplicitReport, isUsefulTaskTitle(existingTitle) {
            return existingTitle
        }
        return initialTitle
    }

    public static func legacyInjectionContaminations(
        in raw: String
    ) -> [LegacyInjectionContamination] {
        let blocks = injectionBlocks(in: raw)
        var results: [LegacyInjectionContamination] = []
        for block in blocks {
            let lines = block.split(
                whereSeparator: \.isNewline
            ).filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                return !lower.contains("agents.md instructions")
                    && !(trimmed.hasPrefix("<") && trimmed.hasSuffix(">"))
            }
            let legacyText = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !legacyText.isEmpty, !legacyText.hasPrefix("<") else {
                continue
            }
            let firstLine = legacyText.split(
                whereSeparator: \.isNewline
            ).first.map(String.init) ?? legacyText
            var title = firstLine
                .replacingOccurrences(
                    of: #"^[#>*\-\d.\s]+"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count > 80 {
                title = String(title.prefix(79))
                    .trimmingCharacters(in: .whitespaces) + "…"
            }
            var description = legacyText
            if description.count > 1_200 {
                description = String(description.prefix(1_199))
                    .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            }
            let contamination = LegacyInjectionContamination(
                title: title,
                description: description
            )
            if !results.contains(contamination) {
                results.append(contamination)
            }
        }
        return results
    }

    private static func removingBlock(tag: String, from text: String) -> String {
        let pattern = "(?s)<\(tag)(?:\\s[^>]*)?>.*?</\(tag)>"
        return text.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }

    private static func removingAgentInstructionBlocks(from text: String) -> String {
        let patterns = [
            #"(?ims)^[ \t]*#[ \t]*AGENTS\.md instructions[^\n]*\n(?:[ \t]*\n)*[ \t]*<INSTRUCTIONS>.*?</INSTRUCTIONS>[ \t]*\n?"#,
            #"(?ims)^[ \t]*#[ \t]*AGENTS\.md instructions[^\n]*\n(?:[ \t]*\n)*[ \t]*<INSTRUCTIONS>.*$"#,
            #"(?ims)^[ \t]*<INSTRUCTIONS>.*?</INSTRUCTIONS>[ \t]*\n?"#,
            #"(?ims)^[ \t]*<INSTRUCTIONS>.*$"#
        ]
        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return result
    }

    private static func injectionBlocks(in text: String) -> [String] {
        let patterns = [
            #"(?ims)^[ \t]*#[ \t]*AGENTS\.md instructions[^\n]*\n(?:[ \t]*\n)*[ \t]*<INSTRUCTIONS>.*?</INSTRUCTIONS>[ \t]*\n?"#,
            #"(?ims)^[ \t]*#[ \t]*AGENTS\.md instructions[^\n]*\n(?:[ \t]*\n)*[ \t]*<INSTRUCTIONS>.*$"#,
            #"(?ims)^[ \t]*<INSTRUCTIONS>.*?</INSTRUCTIONS>[ \t]*\n?"#,
            #"(?ims)^[ \t]*<INSTRUCTIONS>.*$"#
        ]
        var blocks: [String] = []
        var remaining = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(remaining.startIndex..<remaining.endIndex, in: remaining)
            let matches = regex.matches(in: remaining, range: range)
            var ranges: [Range<String.Index>] = []
            for match in matches {
                guard let matchRange = Range(match.range, in: remaining) else {
                    continue
                }
                blocks.append(String(remaining[matchRange]))
                ranges.append(matchRange)
            }
            for matchRange in ranges.reversed() {
                remaining.removeSubrange(matchRange)
            }
        }
        return blocks
    }
}
