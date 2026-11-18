import Foundation

public struct PendingReportCall: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let turnId: String?

    public init(createdAt: Date, turnId: String?) {
        self.createdAt = createdAt
        self.turnId = turnId
    }
}

public struct CursorContext: Codable, Equatable, Sendable {
    public var header: SessionHeader?
    public var pendingCalls: [String: PendingReportCall]

    public init(
        header: SessionHeader? = nil,
        pendingCalls: [String: PendingReportCall] = [:]
    ) {
        self.header = header
        self.pendingCalls = pendingCalls
    }
}

public struct ReduceResult: Equatable, Sendable {
    public var card: AgentCard?
    public var cursor: CursorContext
    public var reportEvents: [ReportEventRecord]

    public init(
        card: AgentCard?,
        cursor: CursorContext,
        reportEvents: [ReportEventRecord]
    ) {
        self.card = card
        self.cursor = cursor
        self.reportEvents = reportEvents
    }
}

public enum SessionReducer {
    public static func reduce(
        records: [ParsedRecord],
        card initialCard: AgentCard?,
        cursor initialCursor: CursorContext,
        seenEventIds: Set<UUID>,
        unreadBaseline: Date? = nil,
        now: Date = Date()
    ) -> ReduceResult {
        var card = initialCard
        var cursor = initialCursor
        var reports: [ReportEventRecord] = []
        var appliedEventIds = seenEventIds
        if card == nil,
           let header = cursor.header,
           records.contains(where: {
               if case .taskStarted = $0.signal { return true }
               if case .userMessage = $0.signal { return true }
               return false
           }),
           let reconstructed = makeCard(
               for: header,
               at: records.first?.timestamp ?? now
           ) {
            card = reconstructed
        }

        for record in records {
            if case .sessionMeta(let header) = record.signal {
                if let existing = card, existing.id != header.id {
                    cursor = CursorContext(header: header)
                    card = SessionReducer.makeCard(for: header, at: record.timestamp)
                } else {
                    cursor.header = header
                }
                if card == nil, header.provider != nil {
                    card = makeCard(for: header, at: record.timestamp)
                }
                continue
            }

            guard let header = cursor.header,
                  header.provider != nil,
                  var workingCard = card,
                  workingCard.id == header.id else {
                continue
            }

            let timestamp = record.timestamp
            let previousLastEventAt = workingCard.lastEventAt
            let isHistoricalReplay = timestamp < previousLastEventAt
            if !isHistoricalReplay {
                workingCard.lastEventAt = max(workingCard.lastEventAt, timestamp)
            }

            switch record.signal {
            case .sessionMeta:
                break

            case .taskStarted(let turnId):
                guard !isHistoricalReplay else { break }
                let exactReplayTimestamp = timestamp == previousLastEventAt
                let startsNewTurn: Bool
                if let turnId {
                    startsNewTurn = turnId != workingCard.currentTurnId
                } else {
                    startsNewTurn = !(exactReplayTimestamp
                        && (workingCard.isTerminal || workingCard.archived))
                }
                if startsNewTurn {
                    unhideIfFresh(&workingCard, at: timestamp)
                    cursor.pendingCalls.removeAll()
                    clearForNewTurn(&workingCard, at: timestamp)
                    workingCard.currentTurnId = turnId
                    workingCard.state = .running
                    workingCard.responseLifecycle = .running
                }

            case .userMessage(let text, let turnId):
                guard !isHistoricalReplay else { break }
                guard let identity = TitleSanitizer.taskIdentity(text) else {
                    break
                }
                let exactReplayTimestamp = timestamp == previousLastEventAt
                let startsNewTurn: Bool
                if let turnId {
                    startsNewTurn = turnId != workingCard.currentTurnId
                } else {
                    startsNewTurn = !exactReplayTimestamp
                        && (workingCard.currentTurnId == nil
                            || workingCard.isTerminal
                            || workingCard.archived)
                }
                if startsNewTurn {
                    unhideIfFresh(&workingCard, at: timestamp)
                    cursor.pendingCalls.removeAll()
                    clearForNewTurn(&workingCard, at: timestamp)
                    workingCard.currentTurnId = turnId
                    workingCard.state = .running
                    workingCard.responseLifecycle = .running
                }
                if workingCard.taskIdentityCaptured != true {
                    workingCard.title = identity.title
                    workingCard.description = identity.description
                    workingCard.taskIdentityCaptured = true
                }
                workingCard.currentRequest = String(
                    identity.description.prefix(240)
                )

            case .taskComplete(let turnId):
                guard !isHistoricalReplay else { break }
                if let turnId, turnId != workingCard.currentTurnId {
                    break
                }
                if workingCard.responseLifecycle == .completed {
                    break
                }
                if workingCard.responseLifecycle != .interrupted,
                   workingCard.responseLifecycle != .error {
                    workingCard.state = .responseEnded
                    workingCard.responseLifecycle = .completed
                    workingCard.completedAt = timestamp
                    if unreadBaseline.map({ timestamp >= $0 }) ?? true {
                        if workingCard.completionUnread != true {
                            workingCard.completionUnread = true
                            workingCard.completionRevision =
                                (workingCard.completionRevision ?? 0) + 1
                        }
                    }
                }

            case .turnAborted(let reason, let turnId):
                guard !isHistoricalReplay else { break }
                if let turnId, turnId != workingCard.currentTurnId {
                    break
                }
                if workingCard.responseLifecycle == .completed {
                    break
                }
                let lower = reason.lowercased()
                let abortedState: TaskState =
                    lower.contains("error") || lower.contains("fail")
                        ? .error
                        : .interrupted
                workingCard.state = abortedState
                workingCard.responseLifecycle =
                    abortedState == .error ? .error : .interrupted
                workingCard.completionUnread = false
                workingCard.completedAt = nil

            case .turnContext(_, let model):
                if let model, !model.isEmpty {
                    workingCard.model = model
                }

            case .toolCall(let callId, let eligible, _):
                if eligible, !isHistoricalReplay {
                    if cursor.pendingCalls.count >= 128 {
                        let oldest = cursor.pendingCalls.min {
                            $0.value.createdAt < $1.value.createdAt
                        }?.key
                        if let oldest {
                            cursor.pendingCalls.removeValue(forKey: oldest)
                        }
                    }
                    cursor.pendingCalls[callId] = PendingReportCall(
                        createdAt: timestamp,
                        turnId: workingCard.currentTurnId
                    )
                }

            case .toolOutput(let callId, let text):
                let pending = cursor.pendingCalls.removeValue(forKey: callId)
                guard let pending,
                      pending.turnId == workingCard.currentTurnId,
                      !isHistoricalReplay else {
                    break
                }
                let envelopes = SessionLineParser.extractReports(fromToolOutput: text)
                for envelope in envelopes {
                    guard envelope.threadId == header.id else {
                        continue
                    }
                    guard !appliedEventIds.contains(envelope.eventId) else {
                        continue
                    }
                    if let lastReportAt = workingCard.lastReportAt,
                       envelope.timestamp < lastReportAt {
                        continue
                    }
                    applyReport(
                        envelope,
                        to: &workingCard,
                        isHistoricalReplay: isHistoricalReplay,
                        shouldMarkCompletionUnread: unreadBaseline.map {
                            envelope.timestamp >= $0
                        } ?? true
                    )
                    appliedEventIds.insert(envelope.eventId)
                    reports.append(ReportEventRecord(envelope: envelope))
                }

            case .agentActivity, .activity:
                break
            }

            card = workingCard
        }

        return ReduceResult(card: card, cursor: cursor, reportEvents: reports)
    }

    public static func makeCard(for header: SessionHeader, at date: Date) -> AgentCard? {
        guard let provider = header.provider else { return nil }
        let fallback = header.cwd
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "새 Codex 작업"
        return AgentCard(
            id: header.id,
            provider: provider,
            title: fallback,
            cwd: header.cwd,
            responseLifecycle: .running,
            startedAt: date,
            lastEventAt: date
        )
    }

    public static func applyReport(
        _ envelope: ReportEnvelope,
        to card: inout AgentCard,
        isHistoricalReplay: Bool = false,
        shouldMarkCompletionUnread: Bool = true
    ) {
        let payload = envelope.payload
        if !isHistoricalReplay, payload.state == .running {
            unhideIfFresh(&card, at: envelope.timestamp)
        }
        if let title = payload.title {
            let useful = TitleSanitizer.safeTitle(title, fallback: "")
            if !useful.isEmpty {
                card.title = useful
            }
        }
        if let description = payload.description, !description.isEmpty {
            card.description = String(description.prefix(1_200))
            card.taskIdentityCaptured = true
        }
        if let origin = envelope.origin {
            card.origin = origin
        }
        card.reportedState = payload.state
        card.steps = payload.steps
        card.summary = payload.summary
        card.hasExplicitReport = true
        card.lastEventAt = max(card.lastEventAt, envelope.timestamp)
        card.lastReportAt = envelope.timestamp
    }

    public static func ordered(_ cards: [AgentCard], now: Date = Date()) -> [AgentCard] {
        cards.sorted {
            let lhsRank = $0.isStaleRunning(now: now) ? 0 : $0.state.sortGroup
            let rhsRank = $1.isStaleRunning(now: now) ? 0 : $1.state.sortGroup
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if $0.lastEventAt != $1.lastEventAt {
                return $0.lastEventAt > $1.lastEventAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func clearForNewTurn(_ card: inout AgentCard, at date: Date) {
        card.steps = []
        card.summary = nil
        card.lastReportAt = nil
        card.completedAt = nil
        card.hasExplicitReport = false
        card.reportedState = nil
        card.completionUnread = false
        card.responseLifecycle = .running
        card.currentRequest = nil
        card.state = .running
        card.lastEventAt = max(card.lastEventAt, date)
        card.currentTurnId = nil
    }

    private static func unhideIfFresh(_ card: inout AgentCard, at date: Date) {
        guard card.archived else { return }
        if let archivedAt = card.archivedAt,
           date <= archivedAt.addingTimeInterval(0.001) {
            return
        }
        card.archived = false
        card.archivedAt = nil
    }
}
