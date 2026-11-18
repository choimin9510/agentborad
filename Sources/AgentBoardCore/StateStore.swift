import Foundation
import SQLite3

private let agentBoardSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

public enum AgentBoardDatabaseError: Error, LocalizedError {
    case open(String)
    case sqlite(String)
    case encode(String)
    case decode(String)
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "데이터베이스를 열 수 없습니다: \(message)"
        case .sqlite(let message): return "데이터베이스 오류: \(message)"
        case .encode(let message): return "저장 데이터를 만들 수 없습니다: \(message)"
        case .decode(let message): return "저장 데이터를 읽을 수 없습니다: \(message)"
        case .invalidData(let message): return "저장 데이터가 올바르지 않습니다: \(message)"
        }
    }
}

public struct FileCursor: Equatable, Sendable {
    public let path: String
    public let inode: Int64
    public let offset: Int64
    public let discardUntilNewline: Bool
    public let context: CursorContext

    public init(
        path: String,
        inode: Int64,
        offset: Int64,
        discardUntilNewline: Bool = false,
        context: CursorContext
    ) {
        self.path = path
        self.inode = inode
        self.offset = offset
        self.discardUntilNewline = discardUntilNewline
        self.context = context
    }
}

private struct ArchivedPreference {
    let archived: Bool
    let archivedAt: Date?
}

public struct IdentityRepairProgress: Equatable, Sendable {
    public let searchedBytes: Int64
    public let isComplete: Bool

    public init(searchedBytes: Int64, isComplete: Bool) {
        self.searchedBytes = searchedBytes
        self.isComplete = isComplete
    }
}

public final class StateStore {
    private let database: OpaquePointer
    private let lock = NSLock()

    public static func applicationSupportDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("AgentBoard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("agentboard.sqlite3")
    }

    public init(path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite open failed (\(result))"
            if let handle { sqlite3_close(handle) }
            throw AgentBoardDatabaseError.open(message)
        }
        database = handle
        sqlite3_busy_timeout(database, 3_000)
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try migrate()
            try ensureUnreadBaseline()
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    public func ingest(
        records: [ParsedRecord],
        path: String,
        inode: Int64,
        endOffset: Int64,
        discardUntilNewline: Bool = false,
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let existing = try readCursor(path: path)
            var context: CursorContext
            if let existing, existing.inode == inode {
                context = existing.context
            } else {
                context = CursorContext()
            }

            let incomingHeader = records.reversed().compactMap { record -> SessionHeader? in
                if case .sessionMeta(let header) = record.signal {
                    return header
                }
                return nil
            }.first
            let selectedHeader = incomingHeader ?? context.header
            let archivedPreference = try selectedHeader.flatMap {
                try readArchivedPreference(cardId: $0.id)
            }
            var existingCard = try selectedHeader.flatMap { try readCard(id: $0.id) }
            if existingCard == nil,
               let selectedHeader,
               records.contains(where: {
                   if case .taskStarted = $0.signal { return true }
                   if case .userMessage = $0.signal { return true }
                   return false
               }),
               let provisional = SessionReducer.makeCard(
                   for: selectedHeader,
                   at: records.first?.timestamp ?? now
               ) {
                existingCard = provisional
            }
            if let preference = archivedPreference {
                existingCard?.archived = preference.archived
                existingCard?.archivedAt = preference.archivedAt
            }
            let threadId = selectedHeader?.id.uuidString ?? ""
            let seen = try readReportEventIds(threadId: threadId)
            let unreadBaseline = try readUnreadBaseline()
            let result = SessionReducer.reduce(
                records: records,
                card: existingCard,
                cursor: context,
                seenEventIds: seen,
                unreadBaseline: unreadBaseline,
                now: now
            )

            if let card = result.card {
                try writeCard(card)
                try writeArchivedPreference(
                    cardId: card.id,
                    archived: card.archived,
                    archivedAt: card.archivedAt
                )
            }
            for report in result.reportEvents {
                try insertReportEvent(report, receivedAt: now)
            }
            try writeCursor(
                path: path,
                inode: inode,
                offset: endOffset,
                discardUntilNewline: discardUntilNewline,
                context: result.cursor,
                now: now
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func loadCards(includeArchived: Bool = false) throws -> [AgentCard] {
        lock.lock()
        defer { lock.unlock() }
        let sql = includeArchived
            ? "SELECT payload FROM cards ORDER BY last_event_at DESC"
            : "SELECT payload FROM cards WHERE archived = 0 ORDER BY last_event_at DESC"
        let statement = try prepare(sql)
        var cards: [AgentCard] = []
        while try statement.step() {
            let data = try statement.data(at: 0)
            var card = try decodeCard(data)
            if let preference = try readArchivedPreference(cardId: card.id) {
                card.archived = preference.archived
                card.archivedAt = preference.archivedAt
            }
            cards.append(card)
        }
        return cards
    }

    public func cursor(path: String) throws -> FileCursor? {
        lock.lock()
        defer { lock.unlock() }
        return try readCursor(path: path)
    }

    public func updateCursorHeader(
        path: String,
        expectedCardId: UUID,
        header: SessionHeader,
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            guard let cursor = try readCursor(path: path),
                  cursor.context.header?.id == expectedCardId else {
                throw AgentBoardDatabaseError.invalidData(
                    "cursor header target not found"
                )
            }
            var context = cursor.context
            context.header = header
            try writeCursor(
                path: path,
                inode: cursor.inode,
                offset: cursor.offset,
                discardUntilNewline: cursor.discardUntilNewline,
                context: context,
                now: now
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func card(cardId: UUID) throws -> AgentCard? {
        lock.lock()
        defer { lock.unlock() }
        guard var card = try readCard(id: cardId) else { return nil }
        if let preference = try readArchivedPreference(cardId: card.id) {
            card.archived = preference.archived
            card.archivedAt = preference.archivedAt
        }
        return card
    }

    public func responseStateRepairCompleted(
        path: String,
        cardId: UUID,
        turnId: String
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            SELECT 1 FROM response_state_repair
            WHERE path = ? AND card_id = ? AND turn_id = ?
            """
        )
        try statement.bind(.text(path), at: 1)
        try statement.bind(.text(cardId.uuidString), at: 2)
        try statement.bind(.text(turnId), at: 3)
        return try statement.step()
    }

    public func responseStateScanIsCurrent(
        path: String,
        cardId: UUID,
        turnId: String,
        fileSize: Int64,
        modifiedAt: Date
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            SELECT file_size, modified_at
            FROM response_state_scan
            WHERE path = ? AND card_id = ? AND turn_id = ?
            """
        )
        try statement.bind(.text(path), at: 1)
        try statement.bind(.text(cardId.uuidString), at: 2)
        try statement.bind(.text(turnId), at: 3)
        guard try statement.step() else { return false }
        return statement.int64(at: 0) == fileSize
            && abs(
                statement.double(at: 1)
                    - modifiedAt.timeIntervalSince1970
            ) < 0.001
    }

    public func recordResponseStateScan(
        path: String,
        cardId: UUID,
        turnId: String,
        fileSize: Int64,
        modifiedAt: Date,
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            INSERT INTO response_state_scan(
                path, card_id, turn_id, file_size, modified_at, scanned_at
            )
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(path, card_id, turn_id) DO UPDATE SET
                file_size = excluded.file_size,
                modified_at = excluded.modified_at,
                scanned_at = excluded.scanned_at
            """
        )
        try statement.bind(.text(path), at: 1)
        try statement.bind(.text(cardId.uuidString), at: 2)
        try statement.bind(.text(turnId), at: 3)
        try statement.bind(.int64(fileSize), at: 4)
        try statement.bind(
            .double(modifiedAt.timeIntervalSince1970),
            at: 5
        )
        try statement.bind(.double(now.timeIntervalSince1970), at: 6)
        _ = try statement.step()
    }

    public func repairResponseCompletion(
        cardId: UUID,
        path: String,
        turnId: String,
        completedAt: Date,
        now: Date = Date()
    ) throws {
        try repairResponseLifecycle(
            cardId: cardId,
            path: path,
            turnId: turnId,
            evidence: .completed(completedAt),
            now: now
        )
    }

    public func repairResponseLifecycle(
        cardId: UUID,
        path: String,
        turnId: String,
        evidence: ResponseLifecycleEvidence,
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            if var card = try readCard(id: cardId),
               card.currentTurnId == turnId {
                if card.reportedState == nil,
                   card.state == .error
                    || card.state == .waiting
                    || card.state == .completed {
                    card.reportedState = card.state
                }
                switch evidence {
                case .running:
                    card.state = .running
                    card.responseLifecycle = .running
                    card.completedAt = nil
                    card.completionUnread = false
                case .completed(let date):
                    card.state = .responseEnded
                    card.responseLifecycle = .completed
                    card.completedAt = date
                case .interrupted:
                    card.state = .interrupted
                    card.responseLifecycle = .interrupted
                    card.completedAt = nil
                    card.completionUnread = false
                case .error:
                    card.state = .error
                    card.responseLifecycle = .error
                    card.completedAt = nil
                    card.completionUnread = false
                }
                try writeCard(card)
            }
            let marker = try prepare(
                """
                INSERT INTO response_state_repair(
                    path, card_id, turn_id, completed_at, repaired_at
                )
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(path, card_id, turn_id) DO UPDATE SET
                    completed_at = excluded.completed_at,
                    repaired_at = excluded.repaired_at
                """
            )
            try marker.bind(.text(path), at: 1)
            try marker.bind(.text(cardId.uuidString), at: 2)
            try marker.bind(.text(turnId), at: 3)
            try marker.bind(
                .double(evidence.timestamp.timeIntervalSince1970),
                at: 4
            )
            try marker.bind(.double(now.timeIntervalSince1970), at: 5)
            _ = try marker.step()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func setArchived(cardId: UUID, archived: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            guard var card = try readCard(id: cardId) else {
                throw AgentBoardDatabaseError.invalidData("card \(cardId) not found")
            }
            card.archived = archived
            card.archivedAt = archived ? Date() : nil
            try writeCard(card)
            try writeArchivedPreference(
                cardId: cardId,
                archived: archived,
                archivedAt: card.archivedAt
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func setCustomTitle(cardId: UUID, title: String?) throws {
        let normalized: String?
        if let title {
            normalized = try AgentTitleOverride.normalized(title)
        } else {
            normalized = nil
        }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            guard var card = try readCard(id: cardId) else {
                throw AgentBoardDatabaseError.invalidData("card \(cardId) not found")
            }
            card.customTitle = normalized
            try writeCard(card)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func markCompletionRead(cardId: UUID) throws {
        try markCompletionsRead(cardIds: [cardId])
    }

    public func markCompletionsRead(cardIds: [UUID]) throws {
        guard !cardIds.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            for cardId in Set(cardIds) {
                if var card = try readCard(id: cardId),
                   card.isTerminal {
                    card.completionUnread = false
                    try writeCard(card)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func acknowledgeCompletions(
        _ acknowledgements: [CompletionAcknowledgement]
    ) throws {
        guard !acknowledgements.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            for acknowledgement in acknowledgements {
                if var card = try readCard(id: acknowledgement.cardId),
                   card.isTerminal,
                   (card.completionRevision ?? 0)
                    == (acknowledgement.revision ?? 0) {
                    card.completionUnread = false
                    try writeCard(card)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func cardNeedsIdentityBackfill(cardId: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let card = try readCard(id: cardId) else { return false }
        return card.taskIdentityCaptured != true
    }

    public func identityBackfillAttempted(path: String, cardId: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            "SELECT 1 FROM identity_backfill WHERE path = ? AND card_id = ?"
        )
        try statement.bind(.text(path), at: 1)
        try statement.bind(.text(cardId.uuidString), at: 2)
        return try statement.step()
    }

    public func identityRepairAttempted(path: String, cardId: UUID) throws -> Bool {
        try identityRepairProgress(path: path, cardId: cardId).isComplete
    }

    public func identityRepairProgress(
        path: String,
        cardId: UUID
    ) throws -> IdentityRepairProgress {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            SELECT searched_bytes, complete
            FROM identity_repair WHERE path = ? AND card_id = ?
            """
        )
        try statement.bind(.text(path), at: 1)
        try statement.bind(.text(cardId.uuidString), at: 2)
        guard try statement.step() else {
            return IdentityRepairProgress(searchedBytes: 0, isComplete: false)
        }
        return IdentityRepairProgress(
            searchedBytes: statement.int64(at: 0),
            isComplete: statement.int64(at: 1) != 0
        )
    }

    public func repairTaskIdentity(
        cardId: UUID,
        path: String,
        identity: TitleSanitizer.TaskIdentity?,
        contaminations: [TitleSanitizer.LegacyInjectionContamination] = [],
        searchedBytes: Int64 = 0,
        complete: Bool = true,
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let marker = try prepare(
                """
                SELECT complete FROM identity_repair
                WHERE path = ? AND card_id = ?
                """
            )
            try marker.bind(.text(path), at: 1)
            try marker.bind(.text(cardId.uuidString), at: 2)
            if try marker.step(), marker.int64(at: 0) != 0 {
                try execute("COMMIT")
                return
            }

            if var card = try readCard(id: cardId),
               let identity {
                let storedTitles = try usefulStoredReportTitles(cardId: card.id)
                let storedDescription = try latestUsefulReportDescription(
                    cardId: card.id
                )
                let recoveredTitle = storedTitles.first ?? identity.title
                let recoveredDescription = storedDescription
                    ?? identity.description
                if card.taskIdentityCaptured == true {
                    if contaminations.contains(where: {
                        $0.title == card.title
                    }) {
                        card.title = recoveredTitle
                    }
                    if contaminations.contains(where: {
                        $0.description == card.description
                    }) {
                        card.description = recoveredDescription
                    }
                } else {
                    card.title = recoveredTitle
                    card.description = recoveredDescription
                    card.taskIdentityCaptured = true
                }
                try writeCard(card)
            }

            let insert = try prepare(
                """
                INSERT INTO identity_repair(
                    path, card_id, searched_bytes, complete, completed_at
                )
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    card_id = excluded.card_id,
                    searched_bytes = excluded.searched_bytes,
                    complete = excluded.complete,
                    completed_at = excluded.completed_at
                """
            )
            try insert.bind(.text(path), at: 1)
            try insert.bind(.text(cardId.uuidString), at: 2)
            try insert.bind(.int64(searchedBytes), at: 3)
            try insert.bind(.int64(complete ? 1 : 0), at: 4)
            try insert.bind(.double(now.timeIntervalSince1970), at: 5)
            _ = try insert.step()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func backfillTaskIdentity(
        cardId: UUID,
        path: String,
        identity: TitleSanitizer.TaskIdentity?,
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            if var card = try readCard(id: cardId),
               card.taskIdentityCaptured != true,
               let identity {
                let previousTitle = card.title
                let storedReportTitles = try usefulStoredReportTitles(cardId: card.id)
                let reportTitle: String?
                if storedReportTitles.contains(previousTitle) {
                    reportTitle = previousTitle
                } else if let stored = storedReportTitles.first {
                    reportTitle = stored
                } else if card.hasExplicitReport,
                          TitleSanitizer.isUsefulTaskTitle(previousTitle) {
                    reportTitle = previousTitle
                } else {
                    reportTitle = nil
                }
                card.title = TitleSanitizer.mergedTaskTitle(
                    initialTitle: identity.title,
                    existingTitle: reportTitle ?? previousTitle,
                    hasExplicitReport: card.hasExplicitReport
                        || !storedReportTitles.isEmpty
                )
                if previousTitle != card.title,
                   !previousTitle.isEmpty {
                    card.currentRequest = String(previousTitle.prefix(240))
                }
                card.description = identity.description
                card.taskIdentityCaptured = true
                try writeCard(card)
            }
            let statement = try prepare(
                """
                INSERT INTO identity_backfill(path, card_id, completed_at)
                VALUES(?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    card_id = excluded.card_id,
                    completed_at = excluded.completed_at
                """
            )
            try statement.bind(.text(path), at: 1)
            try statement.bind(.text(cardId.uuidString), at: 2)
            try statement.bind(.double(now.timeIntervalSince1970), at: 3)
            _ = try statement.step()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    public func pruneCompleted(olderThan cutoff: Date) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let expired = try queryIds(
                "SELECT id FROM cards WHERE state IN ('completed', 'responseEnded') AND COALESCE(completed_at, last_event_at) < ?",
                binding: .double(cutoff.timeIntervalSince1970)
            )
            for id in expired {
                try execute(
                    "DELETE FROM report_events WHERE thread_id = ?",
                    bindings: [.text(id)]
                )
                try execute("DELETE FROM cards WHERE id = ?", bindings: [.text(id)])
            }
            try execute("COMMIT")
            return expired.count
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func reportEventCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT COUNT(*) FROM report_events")
        guard try statement.step() else { return 0 }
        return Int(statement.int64(at: 0))
    }

    private func migrate() throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS cards (
                id TEXT PRIMARY KEY NOT NULL,
                provider TEXT NOT NULL,
                state TEXT NOT NULL,
                last_event_at REAL NOT NULL,
                completed_at REAL,
                archived INTEGER NOT NULL DEFAULT 0,
                payload BLOB NOT NULL
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS cards_state_activity
                ON cards(state, last_event_at DESC)
            """,
            """
            CREATE INDEX IF NOT EXISTS cards_completed
                ON cards(state, completed_at)
            """,
            """
            CREATE TABLE IF NOT EXISTS cursors (
                path TEXT PRIMARY KEY NOT NULL,
                inode INTEGER NOT NULL,
                offset INTEGER NOT NULL,
                discard_until_newline INTEGER NOT NULL DEFAULT 0,
                header_json BLOB,
                pending_calls_json BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS report_events (
                event_id TEXT PRIMARY KEY NOT NULL,
                thread_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                payload BLOB NOT NULL,
                origin_json BLOB,
                received_at REAL NOT NULL
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS report_events_thread
                ON report_events(thread_id, timestamp)
            """,
            """
            CREATE TABLE IF NOT EXISTS card_preferences (
                card_id TEXT PRIMARY KEY NOT NULL,
                archived INTEGER NOT NULL,
                archived_at REAL,
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS identity_backfill (
                path TEXT PRIMARY KEY NOT NULL,
                card_id TEXT NOT NULL,
                completed_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS identity_repair (
                path TEXT PRIMARY KEY NOT NULL,
                card_id TEXT NOT NULL,
                searched_bytes INTEGER NOT NULL DEFAULT 0,
                complete INTEGER NOT NULL DEFAULT 1,
                completed_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS response_state_repair (
                path TEXT NOT NULL,
                card_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                completed_at REAL NOT NULL,
                repaired_at REAL NOT NULL,
                PRIMARY KEY(path, card_id, turn_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS response_state_scan (
                path TEXT NOT NULL,
                card_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                modified_at REAL NOT NULL,
                scanned_at REAL NOT NULL,
                PRIMARY KEY(path, card_id, turn_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS app_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        ]
        for statement in statements {
            try execute(statement)
        }
        if try !columnExists(table: "cursors", column: "discard_until_newline") {
            try execute(
                "ALTER TABLE cursors ADD COLUMN discard_until_newline INTEGER NOT NULL DEFAULT 0"
            )
        }
        if try !columnExists(table: "card_preferences", column: "archived_at") {
            try execute(
                "ALTER TABLE card_preferences ADD COLUMN archived_at REAL"
            )
        }
        if try !columnExists(table: "identity_repair", column: "searched_bytes") {
            try execute(
                "ALTER TABLE identity_repair ADD COLUMN searched_bytes INTEGER NOT NULL DEFAULT 0"
            )
        }
        if try !columnExists(table: "identity_repair", column: "complete") {
            try execute(
                "ALTER TABLE identity_repair ADD COLUMN complete INTEGER NOT NULL DEFAULT 1"
            )
        }
        if try !columnExists(table: "report_events", column: "origin_json") {
            try execute(
                "ALTER TABLE report_events ADD COLUMN origin_json BLOB"
            )
        }
        try execute(
            """
            UPDATE card_preferences
            SET archived_at = updated_at
            WHERE archived = 1 AND archived_at IS NULL
            """
        )
    }

    private func readCursor(path: String) throws -> FileCursor? {
        let statement = try prepare(
            """
            SELECT path, inode, offset, discard_until_newline,
                   header_json, pending_calls_json
            FROM cursors WHERE path = ?
            """
        )
        try statement.bind(.text(path), at: 1)
        guard try statement.step() else { return nil }
        let storedPath = try statement.string(at: 0)
        let headerData = try statement.optionalData(at: 4)
        let pendingData = try statement.data(at: 5)
        let decoder = JSONDecoder()
        let header: SessionHeader?
        if let headerData {
            header = try decoder.decode(SessionHeader.self, from: headerData)
        } else {
            header = nil
        }
        let pending = try decoder.decode(
            [String: PendingReportCall].self,
            from: pendingData
        )
        return FileCursor(
            path: storedPath,
            inode: statement.int64(at: 1),
            offset: statement.int64(at: 2),
            discardUntilNewline: statement.int64(at: 3) != 0,
            context: CursorContext(header: header, pendingCalls: pending)
        )
    }

    private func writeCursor(
        path: String,
        inode: Int64,
        offset: Int64,
        discardUntilNewline: Bool,
        context: CursorContext,
        now: Date
    ) throws {
        let encoder = JSONEncoder()
        let headerData = try context.header.map {
            try encoder.encode($0)
        }
        let pendingData = try encoder.encode(context.pendingCalls)
        let statement = try prepare(
            """
            INSERT INTO cursors(
                path, inode, offset, discard_until_newline,
                header_json, pending_calls_json, updated_at
            )
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                inode = excluded.inode,
                offset = excluded.offset,
                discard_until_newline = excluded.discard_until_newline,
                header_json = excluded.header_json,
                pending_calls_json = excluded.pending_calls_json,
                updated_at = excluded.updated_at
            """
        )
        try statement.bind(.text(path), at: 1)
        try statement.bind(.int64(inode), at: 2)
        try statement.bind(.int64(offset), at: 3)
        try statement.bind(.int64(discardUntilNewline ? 1 : 0), at: 4)
        if let headerData {
            try statement.bind(.blob(headerData), at: 5)
        } else {
            sqlite3_bind_null(statement.raw, 5)
        }
        try statement.bind(.blob(pendingData), at: 6)
        try statement.bind(.double(now.timeIntervalSince1970), at: 7)
        _ = try statement.step()
    }

    private func readCard(id: UUID) throws -> AgentCard? {
        let statement = try prepare("SELECT payload FROM cards WHERE id = ?")
        try statement.bind(.text(id.uuidString), at: 1)
        guard try statement.step() else { return nil }
        return try decodeCard(statement.data(at: 0))
    }

    private func readArchivedPreference(cardId: UUID) throws -> ArchivedPreference? {
        let statement = try prepare(
            "SELECT archived, archived_at, updated_at FROM card_preferences WHERE card_id = ?"
        )
        try statement.bind(.text(cardId.uuidString), at: 1)
        guard try statement.step() else { return nil }
        let archived = statement.int64(at: 0) != 0
        let archivedAt: Date?
        if sqlite3_column_type(statement.raw, 1) == SQLITE_NULL {
            archivedAt = archived
                ? Date(timeIntervalSince1970: sqlite3_column_double(statement.raw, 2))
                : nil
        } else {
            archivedAt = Date(
                timeIntervalSince1970: sqlite3_column_double(statement.raw, 1)
            )
        }
        return ArchivedPreference(
            archived: archived,
            archivedAt: archivedAt
        )
    }

    private func writeArchivedPreference(
        cardId: UUID,
        archived: Bool,
        archivedAt: Date?
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO card_preferences(card_id, archived, archived_at, updated_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(card_id) DO UPDATE SET
                archived = excluded.archived,
                archived_at = excluded.archived_at,
                updated_at = excluded.updated_at
            """
        )
        try statement.bind(.text(cardId.uuidString), at: 1)
        try statement.bind(.int64(archived ? 1 : 0), at: 2)
        if let archivedAt {
            try statement.bind(.double(archivedAt.timeIntervalSince1970), at: 3)
        } else {
            sqlite3_bind_null(statement.raw, 3)
        }
        try statement.bind(.double(Date().timeIntervalSince1970), at: 4)
        _ = try statement.step()
    }

    private func usefulStoredReportTitles(cardId: UUID) throws -> [String] {
        let statement = try prepare(
            """
            SELECT payload FROM report_events
            WHERE thread_id = ?
            ORDER BY timestamp DESC
            LIMIT 32
            """
        )
        try statement.bind(.text(cardId.uuidString), at: 1)
        var titles: [String] = []
        while try statement.step() {
            guard let payload = try? JSONDecoder().decode(
                ReportPayload.self,
                from: statement.data(at: 0)
            ), let title = payload.title,
               TitleSanitizer.isUsefulTaskTitle(title) else {
                continue
            }
            titles.append(TitleSanitizer.safeTitle(title, fallback: ""))
        }
        return titles
    }

    private func latestUsefulReportDescription(cardId: UUID) throws -> String? {
        let statement = try prepare(
            """
            SELECT payload FROM report_events
            WHERE thread_id = ?
            ORDER BY timestamp DESC
            LIMIT 32
            """
        )
        try statement.bind(.text(cardId.uuidString), at: 1)
        while try statement.step() {
            guard let payload = try? JSONDecoder().decode(
                ReportPayload.self,
                from: statement.data(at: 0)
            ), let description = payload.description?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !description.isEmpty else {
                continue
            }
            return String(description.prefix(1_200))
        }
        return nil
    }

    private func ensureUnreadBaseline() throws {
        let statement = try prepare(
            "INSERT OR IGNORE INTO app_metadata(key, value) VALUES('unreadBaselineAt', ?)"
        )
        try statement.bind(
            .text(String(Date().timeIntervalSince1970)),
            at: 1
        )
        _ = try statement.step()
    }

    private func readUnreadBaseline() throws -> Date? {
        let statement = try prepare(
            "SELECT value FROM app_metadata WHERE key = 'unreadBaselineAt'"
        )
        guard try statement.step() else { return nil }
        return Double(try statement.string(at: 0))
            .map(Date.init(timeIntervalSince1970:))
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(table))")
        while try statement.step() {
            if try statement.string(at: 1) == column {
                return true
            }
        }
        return false
    }

    private func writeCard(_ card: AgentCard) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(card)
        } catch {
            throw AgentBoardDatabaseError.encode(error.localizedDescription)
        }
        let statement = try prepare(
            """
            INSERT INTO cards(id, provider, state, last_event_at, completed_at, archived, payload)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                provider = excluded.provider,
                state = excluded.state,
                last_event_at = excluded.last_event_at,
                completed_at = excluded.completed_at,
                archived = excluded.archived,
                payload = excluded.payload
            """
        )
        try statement.bind(.text(card.id.uuidString), at: 1)
        try statement.bind(.text(card.provider.rawValue), at: 2)
        try statement.bind(.text(card.state.rawValue), at: 3)
        try statement.bind(.double(card.lastEventAt.timeIntervalSince1970), at: 4)
        if let completedAt = card.completedAt {
            try statement.bind(.double(completedAt.timeIntervalSince1970), at: 5)
        } else {
            sqlite3_bind_null(statement.raw, 5)
        }
        try statement.bind(.int64(card.archived ? 1 : 0), at: 6)
        try statement.bind(.blob(data), at: 7)
        _ = try statement.step()
    }

    private func decodeCard(_ data: Data) throws -> AgentCard {
        do {
            return try JSONDecoder().decode(AgentCard.self, from: data)
        } catch {
            throw AgentBoardDatabaseError.decode(error.localizedDescription)
        }
    }

    private func readReportEventIds(threadId: String) throws -> Set<UUID> {
        guard !threadId.isEmpty else { return [] }
        let statement = try prepare("SELECT event_id FROM report_events WHERE thread_id = ?")
        try statement.bind(.text(threadId), at: 1)
        var ids = Set<UUID>()
        while try statement.step() {
            if let id = UUID(uuidString: try statement.string(at: 0)) {
                ids.insert(id)
            }
        }
        return ids
    }

    private func insertReportEvent(_ event: ReportEventRecord, receivedAt: Date) throws {
        let data: Data
        let originData: Data?
        do {
            data = try JSONEncoder().encode(event.payload)
            originData = try event.origin.map {
                try JSONEncoder().encode($0)
            }
        } catch {
            throw AgentBoardDatabaseError.encode(error.localizedDescription)
        }
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO report_events(
                event_id, thread_id, timestamp, payload, origin_json, received_at
            )
            VALUES(?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind(.text(event.eventId.uuidString), at: 1)
        try statement.bind(.text(event.threadId.uuidString), at: 2)
        try statement.bind(.double(event.timestamp.timeIntervalSince1970), at: 3)
        try statement.bind(.blob(data), at: 4)
        if let originData {
            try statement.bind(.blob(originData), at: 5)
        } else {
            sqlite3_bind_null(statement.raw, 5)
        }
        try statement.bind(.double(receivedAt.timeIntervalSince1970), at: 6)
        _ = try statement.step()
    }

    private func queryIds(_ sql: String, binding: SQLiteValue) throws -> [String] {
        let statement = try prepare(sql)
        try statement.bind(binding, at: 1)
        var ids: [String] = []
        while try statement.step() {
            ids.append(try statement.string(at: 0))
        }
        return ids
    }

    private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        for (offset, value) in bindings.enumerated() {
            try statement.bind(value, at: Int32(offset + 1))
        }
        _ = try statement.step()
    }

    private func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(database: database, sql: sql)
    }
}

private enum SQLiteValue {
    case text(String)
    case int64(Int64)
    case double(Double)
    case blob(Data)
}

private final class SQLiteStatement {
    let raw: OpaquePointer
    private let database: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw AgentBoardDatabaseError.sqlite(
                "\(String(cString: sqlite3_errmsg(database))) [\(result)]"
            )
        }
        raw = statement
    }

    deinit {
        sqlite3_finalize(raw)
    }

    func bind(_ value: SQLiteValue, at index: Int32) throws {
        let result: Int32
        switch value {
        case .text(let string):
            result = sqlite3_bind_text(raw, index, string, -1, agentBoardSQLiteTransient)
        case .int64(let integer):
            result = sqlite3_bind_int64(raw, index, integer)
        case .double(let double):
            result = sqlite3_bind_double(raw, index, double)
        case .blob(let data):
            result = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    raw,
                    index,
                    bytes.baseAddress,
                    Int32(data.count),
                    agentBoardSQLiteTransient
                )
            }
        }
        guard result == SQLITE_OK else {
            throw AgentBoardDatabaseError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
    }

    func step() throws -> Bool {
        let result = sqlite3_step(raw)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw AgentBoardDatabaseError.sqlite(
            "\(String(cString: sqlite3_errmsg(database))) [\(result)]"
        )
    }

    func string(at index: Int32) throws -> String {
        guard let pointer = sqlite3_column_text(raw, index) else { return "" }
        return String(cString: pointer)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(raw, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(raw, index)
    }

    func data(at index: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(raw, index) else {
            return Data()
        }
        let count = Int(sqlite3_column_bytes(raw, index))
        return Data(bytes: bytes, count: count)
    }

    func optionalData(at index: Int32) throws -> Data? {
        guard sqlite3_column_type(raw, index) != SQLITE_NULL else { return nil }
        return try data(at: index)
    }
}
