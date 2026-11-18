import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case openai
    case deepseek

    public var displayName: String {
        switch self {
        case .openai: return "GPT"
        case .deepseek: return "DeepSeek"
        }
    }
}

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case waiting
    case running
    case interrupted
    case error
    case responseEnded
    case completed

    public var displayName: String {
        switch self {
        case .waiting: return "확인 필요"
        case .running: return "진행 중"
        case .interrupted: return "중단됨"
        case .error: return "오류"
        case .responseEnded: return "완료"
        case .completed: return "완료"
        }
    }

    public var sortGroup: Int {
        switch self {
        case .waiting, .interrupted, .error: return 0
        case .running: return 1
        case .responseEnded: return 3
        case .completed: return 3
        }
    }
}

public enum ResponseLifecycle: String, Codable, CaseIterable, Sendable {
    case running
    case completed
    case interrupted
    case error
}

public enum ResponseLifecycleEvidence: Equatable, Sendable {
    case running(Date)
    case completed(Date)
    case interrupted(Date)
    case error(Date)

    public var timestamp: Date {
        switch self {
        case .running(let date), .completed(let date),
             .interrupted(let date), .error(let date):
            return date
        }
    }
}

public enum StepStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case inProgress
    case completed

    public var displayName: String {
        switch self {
        case .pending: return "대기"
        case .inProgress: return "진행 중"
        case .completed: return "완료"
        }
    }
}

public struct ReportStep: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public var status: StepStatus

    public init(id: String, title: String, status: StepStatus) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct ReportPayload: Codable, Equatable, Sendable {
    public let title: String?
    public let state: TaskState
    public let steps: [ReportStep]
    public let summary: String?
    public let description: String?

    public init(
        title: String?,
        state: TaskState,
        steps: [ReportStep],
        summary: String?,
        description: String? = nil
    ) {
        self.title = title
        self.state = state
        self.steps = steps
        self.summary = summary
        self.description = description
    }
}

public struct ReportEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let eventId: UUID
    public let threadId: UUID
    public let timestamp: Date
    public let payload: ReportPayload
    public let origin: SessionOrigin?

    public init(
        version: Int = 1,
        eventId: UUID = UUID(),
        threadId: UUID,
        timestamp: Date = Date(),
        payload: ReportPayload,
        origin: SessionOrigin? = nil
    ) {
        self.version = version
        self.eventId = eventId
        self.threadId = threadId
        self.timestamp = timestamp
        self.payload = payload
        self.origin = origin
    }
}

public enum SessionOriginKind: String, Codable, Sendable {
    case cmux
    case herdr
}

public struct SessionOrigin: Codable, Equatable, Sendable {
    public let kind: SessionOriginKind
    public let windowId: String?
    public let workspaceId: String?
    public let surfaceId: String?
    public let tabId: String?
    public let paneId: String?
    public let sessionName: String?
    public let socketPath: String?
    public let cliPath: String?

    public init(
        kind: SessionOriginKind,
        windowId: String? = nil,
        workspaceId: String? = nil,
        surfaceId: String? = nil,
        tabId: String? = nil,
        paneId: String? = nil,
        sessionName: String? = nil,
        socketPath: String? = nil,
        cliPath: String? = nil
    ) {
        self.kind = kind
        self.windowId = windowId
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.tabId = tabId
        self.paneId = paneId
        self.sessionName = sessionName
        self.socketPath = socketPath
        self.cliPath = cliPath
    }
}

public struct SessionHeader: Codable, Equatable, Sendable {
    public let id: UUID
    public let source: String
    public let cwd: String?
    public let modelProvider: String?
    public let originator: String?
    public let threadSource: String?
    public let cliVersion: String?
    public let historyMode: String?

    public init(
        id: UUID,
        source: String,
        cwd: String?,
        modelProvider: String?,
        originator: String? = nil,
        threadSource: String? = nil,
        cliVersion: String?,
        historyMode: String?
    ) {
        self.id = id
        self.source = source
        self.cwd = cwd
        self.modelProvider = modelProvider
        self.originator = originator
        self.threadSource = threadSource
        self.cliVersion = cliVersion
        self.historyMode = historyMode
    }

    public var provider: Provider? {
        guard Self.isUserConversation(
            source: source,
            originator: originator,
            threadSource: threadSource
        ) else {
            return nil
        }
        switch modelProvider?.lowercased() {
        case "openai": return .openai
        case "deepseek": return .deepseek
        default: return nil
        }
    }

    private static func isUserConversation(
        source: String,
        originator: String?,
        threadSource: String?
    ) -> Bool {
        let normalizedSource = source.lowercased()
        let normalizedOrigin = originator?.lowercased()
        let normalizedThreadSource = threadSource?.lowercased()
        if let normalizedThreadSource,
           normalizedThreadSource != "user" {
            return false
        }
        if let normalizedOrigin,
           normalizedOrigin.contains("subagent")
            || normalizedOrigin.contains("system") {
            return false
        }
        switch normalizedSource {
        case "cli":
            return true
        case "vscode":
            guard let normalizedThreadSource else {
                return normalizedOrigin == "codex-tui"
                    || normalizedOrigin == "codex desktop"
            }
            return normalizedThreadSource == "user"
                && (normalizedOrigin == "codex-tui"
                    || normalizedOrigin == "codex desktop")
        default:
            return false
        }
    }
}

public struct AgentCard: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let provider: Provider
    public var title: String
    public var customTitle: String?
    public var cwd: String?
    public var model: String?
    public var state: TaskState
    public var responseLifecycle: ResponseLifecycle?
    public var reportedState: TaskState?
    public var origin: SessionOrigin?
    public var steps: [ReportStep]
    public var summary: String?
    public var description: String?
    public var currentRequest: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var lastReportAt: Date?
    public var completedAt: Date?
    public var currentTurnId: String?
    public var archived: Bool
    public var archivedAt: Date?
    public var hasExplicitReport: Bool
    public var taskIdentityCaptured: Bool?
    public var completionUnread: Bool?
    public var completionRevision: Int?

    public init(
        id: UUID,
        provider: Provider,
        title: String,
        customTitle: String? = nil,
        cwd: String?,
        model: String? = nil,
        state: TaskState = .running,
        responseLifecycle: ResponseLifecycle? = nil,
        reportedState: TaskState? = nil,
        origin: SessionOrigin? = nil,
        steps: [ReportStep] = [],
        summary: String? = nil,
        description: String? = nil,
        currentRequest: String? = nil,
        startedAt: Date = Date(),
        lastEventAt: Date = Date(),
        lastReportAt: Date? = nil,
        completedAt: Date? = nil,
        currentTurnId: String? = nil,
        archived: Bool = false,
        archivedAt: Date? = nil,
        hasExplicitReport: Bool = false,
        taskIdentityCaptured: Bool? = false,
        completionUnread: Bool? = false,
        completionRevision: Int? = 0
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.customTitle = customTitle
        self.cwd = cwd
        self.model = model
        self.state = state
        self.responseLifecycle = responseLifecycle
        self.reportedState = reportedState
        self.origin = origin
        self.steps = steps
        self.summary = summary
        self.description = description
        self.currentRequest = currentRequest
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.lastReportAt = lastReportAt
        self.completedAt = completedAt
        self.currentTurnId = currentTurnId
        self.archived = archived
        self.archivedAt = archivedAt
        self.hasExplicitReport = hasExplicitReport
        self.taskIdentityCaptured = taskIdentityCaptured
        self.completionUnread = completionUnread
        self.completionRevision = completionRevision
    }

    public var currentStep: ReportStep? {
        steps.first(where: { $0.status == .inProgress })
            ?? steps.first(where: { $0.status == .pending })
    }

    public func isStaleRunning(now: Date = Date(), threshold: TimeInterval = 90) -> Bool {
        state == .running && now.timeIntervalSince(lastEventAt) > threshold
    }

    public func displayState(now: Date = Date()) -> String {
        if isStaleRunning(now: now) {
            return "현재 상태 확인 필요"
        }
        return state.displayName
    }

    public var isUnfinished: Bool {
        state != .completed
    }

    public var isTerminal: Bool {
        state == .completed || state == .responseEnded
    }

    public var isCompletionUnread: Bool {
        completionUnread == true
    }

    public var displayTitle: String {
        customTitle ?? title
    }
}

public enum AgentTitleOverride {
    public static let maximumLength = 80

    public enum ValidationError: Error, LocalizedError, Equatable {
        case empty
        case tooLong

        public var errorDescription: String? {
            switch self {
            case .empty: return "제목을 입력해 주세요."
            case .tooLong: return "제목은 80자 이하여야 합니다."
            }
        }
    }

    public static func normalized(_ raw: String) throws -> String {
        let value = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ValidationError.empty
        }
        guard value.count <= maximumLength else {
            throw ValidationError.tooLong
        }
        return value
    }
}

public struct CompletionAcknowledgement: Equatable, Sendable {
    public let cardId: UUID
    public let revision: Int?

    public init(cardId: UUID, revision: Int?) {
        self.cardId = cardId
        self.revision = revision
    }
}

public struct ReportEventRecord: Codable, Equatable, Sendable {
    public let eventId: UUID
    public let threadId: UUID
    public let timestamp: Date
    public let payload: ReportPayload
    public let origin: SessionOrigin?

    public init(envelope: ReportEnvelope) {
        eventId = envelope.eventId
        threadId = envelope.threadId
        timestamp = envelope.timestamp
        payload = envelope.payload
        origin = envelope.origin
    }
}
