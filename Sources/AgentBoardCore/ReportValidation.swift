import CoreFoundation
import Foundation

public enum ReportValidationError: Error, LocalizedError, Equatable {
    case invalidJSON(String)
    case expectedObject
    case unknownField(String)
    case missingField(String)
    case invalidField(String)
    case tooLong(String)
    case tooManySteps
    case duplicateStepID
    case completedWithUnfinishedSteps
    case completedWithoutSummary
    case unsupportedState(String)
    case invalidThreadId
    case invalidVersion(Int)
    case invalidEventId

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let message): return "JSON 형식이 올바르지 않습니다: \(message)"
        case .expectedObject: return "보고서는 JSON 객체여야 합니다."
        case .unknownField(let field): return "허용되지 않은 필드입니다: \(field)"
        case .missingField(let field): return "필수 필드가 없습니다: \(field)"
        case .invalidField(let field): return "필드 형식이 올바르지 않습니다: \(field)"
        case .tooLong(let field): return "\(field) 길이 제한을 초과했습니다."
        case .tooManySteps: return "단계는 최대 30개까지 허용됩니다."
        case .duplicateStepID: return "단계 id가 중복되었습니다."
        case .completedWithUnfinishedSteps:
            return "완료 상태에는 미완료 단계가 있을 수 없습니다."
        case .completedWithoutSummary:
            return "완료 보고서에는 요약이 필요합니다."
        case .unsupportedState(let state):
            return "지원하지 않는 상태입니다: \(state)"
        case .invalidThreadId: return "thread ID가 올바른 UUID가 아닙니다."
        case .invalidVersion(let version): return "지원하지 않는 envelope 버전입니다: \(version)"
        case .invalidEventId: return "eventId가 올바른 UUID가 아닙니다."
        }
    }
}

public enum ReportValidator {
    public static let maximumJSONBytes = 64 * 1024
    public static let maximumTitleLength = 120
    public static let maximumSummaryLength = 2_000
    public static let maximumDescriptionLength = 1_000
    public static let maximumStepIDLength = 64
    public static let maximumStepTitleLength = 120
    public static let maximumSteps = 30

    public static func decodePayload(_ data: Data) throws -> ReportPayload {
        guard data.count <= maximumJSONBytes else {
            throw ReportValidationError.tooLong("report")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ReportValidationError.invalidJSON(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw ReportValidationError.expectedObject
        }
        try rejectUnknown(
            dictionary,
            allowed: ["title", "state", "steps", "summary", "description"],
            name: "payload"
        )

        let stateString = try requiredString(dictionary, "state", maximum: 32)
        let state: TaskState
        switch stateString {
        case "running": state = .running
        case "waiting": state = .waiting
        case "completed": state = .completed
        case "interrupted": state = .interrupted
        case "error": state = .error
        default: throw ReportValidationError.unsupportedState(stateString)
        }

        guard dictionary["title"] != nil else {
            throw ReportValidationError.missingField("title")
        }
        guard dictionary["summary"] != nil else {
            throw ReportValidationError.missingField("summary")
        }
        let title = try optionalString(
            dictionary,
            "title",
            maximum: maximumTitleLength,
            allowEmpty: false
        )
        let summary = try optionalString(
            dictionary,
            "summary",
            maximum: maximumSummaryLength,
            allowEmpty: state != .completed
        )
        let description = try optionalString(
            dictionary,
            "description",
            maximum: maximumDescriptionLength,
            allowEmpty: true
        )

        var steps: [ReportStep] = []
        guard let rawSteps = dictionary["steps"] else {
            throw ReportValidationError.missingField("steps")
        }
        guard let stepObjects = rawSteps as? [[String: Any]] else {
            throw ReportValidationError.invalidField("steps")
        }
        guard stepObjects.count <= maximumSteps else {
            throw ReportValidationError.tooManySteps
        }
        var ids = Set<String>()
        for rawStep in stepObjects {
            try rejectUnknown(rawStep, allowed: ["id", "title", "status"], name: "step")
            let id = try requiredString(
                rawStep,
                "id",
                maximum: maximumStepIDLength
            )
            guard ids.insert(id).inserted else {
                throw ReportValidationError.duplicateStepID
            }
            let stepTitle = try requiredString(
                rawStep,
                "title",
                maximum: maximumStepTitleLength
            )
            let statusString = try requiredString(rawStep, "status", maximum: 32)
            let status: StepStatus
            switch statusString {
            case "pending": status = .pending
            case "inProgress": status = .inProgress
            case "completed": status = .completed
            default: throw ReportValidationError.invalidField("steps.status")
            }
            steps.append(ReportStep(id: id, title: stepTitle, status: status))
        }

        if state == .completed {
            guard !steps.contains(where: { $0.status != .completed }) else {
                throw ReportValidationError.completedWithUnfinishedSteps
            }
            guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReportValidationError.completedWithoutSummary
            }
        }

        return ReportPayload(
            title: title,
            state: state,
            steps: steps,
            summary: summary,
            description: description
        )
    }

    public static func decodeEnvelope(_ data: Data) throws -> ReportEnvelope {
        guard data.count <= maximumJSONBytes else {
            throw ReportValidationError.tooLong("envelope")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ReportValidationError.invalidJSON(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw ReportValidationError.expectedObject
        }
        try rejectUnknown(
            dictionary,
            allowed: [
                "version", "eventId", "threadId", "timestamp",
                "payload", "origin"
            ],
            name: "envelope"
        )
        guard let versionNumber = dictionary["version"] as? NSNumber,
              CFGetTypeID(versionNumber) != CFBooleanGetTypeID(),
              versionNumber.intValue == 1,
              versionNumber.doubleValue == 1 else {
            throw ReportValidationError.invalidVersion(
                (dictionary["version"] as? NSNumber)?.intValue ?? 0
            )
        }
        guard let eventString = dictionary["eventId"] as? String,
              let eventId = UUID(uuidString: eventString) else {
            throw ReportValidationError.invalidEventId
        }
        guard let threadString = dictionary["threadId"] as? String,
              let threadId = UUID(uuidString: threadString) else {
            throw ReportValidationError.invalidThreadId
        }
        guard let timestampString = dictionary["timestamp"] as? String,
              let timestamp = AgentBoardDate.parse(timestampString) else {
            throw ReportValidationError.invalidField("timestamp")
        }
        guard let payloadObject = dictionary["payload"] as? [String: Any] else {
            throw ReportValidationError.missingField("payload")
        }
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject)
        let payload = try decodePayload(payloadData)
        let origin: SessionOrigin?
        if let rawOrigin = dictionary["origin"] {
            guard let originObject = rawOrigin as? [String: Any] else {
                throw ReportValidationError.invalidField("origin")
            }
            try rejectUnknown(
                originObject,
                allowed: [
                    "kind", "windowId", "workspaceId", "surfaceId", "tabId",
                    "paneId", "sessionName", "socketPath", "cliPath"
                ],
                name: "origin"
            )
            guard let kindString = originObject["kind"] as? String,
                  let kind = SessionOriginKind(rawValue: kindString) else {
                throw ReportValidationError.invalidField("origin.kind")
            }
            func optional(_ key: String) throws -> String? {
                guard let value = originObject[key] else { return nil }
                guard let string = value as? String else {
                    throw ReportValidationError.invalidField("origin.\(key)")
                }
                return string
            }
            let window = try optional("windowId")
                .flatMap(SessionOrigin.safeIdentifier)
            let workspace = try optional("workspaceId")
                .flatMap(SessionOrigin.safeIdentifier)
            let surface = try optional("surfaceId")
                .flatMap(SessionOrigin.safeIdentifier)
            let tab = try optional("tabId")
                .flatMap(SessionOrigin.safeIdentifier)
            let pane = try optional("paneId")
                .flatMap(SessionOrigin.safeIdentifier)
            let sessionName = try optional("sessionName")
                .flatMap(SessionOrigin.safeIdentifier)
            let socket = try optional("socketPath")
                .flatMap(SessionOrigin.safeAbsolutePath)
            let cli = try optional("cliPath").flatMap {
                kind == .cmux
                    ? SessionOrigin.safeCMUXExecutable($0)
                    : nil
            }
            switch kind {
            case .cmux:
                guard workspace != nil, surface != nil, sessionName == nil else {
                    throw ReportValidationError.invalidField(
                        "origin.cmux identifiers"
                    )
                }
            case .herdr:
                guard workspace != nil, pane != nil else {
                    throw ReportValidationError.invalidField(
                        "origin.herdr identifiers"
                    )
                }
            }
            origin = SessionOrigin(
                kind: kind,
                windowId: window,
                workspaceId: workspace,
                surfaceId: surface,
                tabId: tab,
                paneId: pane,
                sessionName: sessionName,
                socketPath: socket,
                cliPath: cli
            )
        } else {
            origin = nil
        }
        return ReportEnvelope(
            version: 1,
            eventId: eventId,
            threadId: threadId,
            timestamp: timestamp,
            payload: payload,
            origin: origin
        )
    }

    public static func encodeEnvelope(_ envelope: ReportEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(AgentBoardDate.string(date))
        }
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(envelope)
    }

    private static func rejectUnknown(
        _ dictionary: [String: Any],
        allowed: Set<String>,
        name: String
    ) throws {
        if let unknown = dictionary.keys.first(where: { !allowed.contains($0) }) {
            throw ReportValidationError.unknownField("\(name).\(unknown)")
        }
    }

    private static func requiredString(
        _ dictionary: [String: Any],
        _ key: String,
        maximum: Int
    ) throws -> String {
        guard let value = dictionary[key] as? String else {
            if dictionary[key] == nil {
                throw ReportValidationError.missingField(key)
            }
            throw ReportValidationError.invalidField(key)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ReportValidationError.invalidField(key)
        }
        guard value.count <= maximum else {
            throw ReportValidationError.tooLong(key)
        }
        return trimmed
    }

    private static func optionalString(
        _ dictionary: [String: Any],
        _ key: String,
        maximum: Int,
        allowEmpty: Bool
    ) throws -> String? {
        guard let raw = dictionary[key] else { return nil }
        guard let value = raw as? String else {
            throw ReportValidationError.invalidField(key)
        }
        guard value.count <= maximum else {
            throw ReportValidationError.tooLong(key)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowEmpty && trimmed.isEmpty {
            throw ReportValidationError.invalidField(key)
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}
