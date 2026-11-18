import CoreServices
import Darwin
import Foundation

public struct CollectorUpdate: Equatable, Sendable {
    public let message: String
    public let isError: Bool

    public init(message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
    }
}

public struct IngestSummary: Equatable, Sendable {
    public var filesScanned: Int
    public var recordsIngested: Int
    public var catchUpFiles: Int
    public var errors: [String]

    public init(
        filesScanned: Int = 0,
        recordsIngested: Int = 0,
        catchUpFiles: Int = 0,
        errors: [String] = []
    ) {
        self.filesScanned = filesScanned
        self.recordsIngested = recordsIngested
        self.catchUpFiles = catchUpFiles
        self.errors = errors
    }
}

public final class SessionCollector {
    private enum SessionDirectoryState {
        case missing
        case directory(URL)
        case failure(String)
    }

    public static let maximumIdentityRepairBytes: Int64 = 16 * 1_024 * 1_024

    public let codexHomes: [URL]
    public let store: StateStore
    public let trustPolicy: ReportTrustPolicy
    public var onUpdate: ((CollectorUpdate) -> Void)?

    private let queue = DispatchQueue(label: "app.agentboard.collector", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var reconciliationTimer: DispatchSourceTimer?
    private var lastPruneAt: Date?
    private var started = false
    private var scanPending = false

    public convenience init(
        codexHome: URL,
        store: StateStore,
        trustPolicy: ReportTrustPolicy = .default
    ) {
        self.init(
            codexHomes: [codexHome],
            store: store,
            trustPolicy: trustPolicy
        )
    }

    public init(
        codexHomes: [URL],
        store: StateStore,
        trustPolicy: ReportTrustPolicy = .default
    ) {
        self.codexHomes = Self.normalizedHomes(codexHomes)
        self.store = store
        self.trustPolicy = trustPolicy
    }

    deinit {
        stop()
    }

    public var codexHome: URL { codexHomes[0] }

    public var sessionsDirectories: [URL] {
        codexHomes.map {
            $0.appendingPathComponent("sessions", isDirectory: true)
        }
    }

    public var sessionsDirectory: URL { sessionsDirectories[0] }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.installFSEvents()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(400))
            timer.setEventHandler { [weak self] in
                self?.scheduleScan()
            }
            self.reconciliationTimer = timer
            timer.resume()
            self.scheduleScan(immediate: true)
        }
    }

    public func stop() {
        queue.sync {
            started = false
            reconciliationTimer?.cancel()
            reconciliationTimer = nil
            if let eventStream {
                FSEventStreamStop(eventStream)
                FSEventStreamInvalidate(eventStream)
                FSEventStreamRelease(eventStream)
                self.eventStream = nil
            }
        }
    }

    @discardableResult
    public func scanOnceSync(now: Date = Date()) -> IngestSummary {
        queue.sync {
            scan(now: now)
        }
    }

    private func installFSEvents() {
        var paths: [String] = []
        var seenDirectories = Set<String>()
        for sessions in sessionsDirectories {
            switch sessionDirectoryState(sessions) {
            case .directory(let resolved):
                if seenDirectories.insert(resolved.path).inserted {
                    paths.append(resolved.path)
                }
            case .missing:
                continue
            case .failure(let message):
                emit(message, isError: true)
            }
        }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let collector = Unmanaged<SessionCollector>
                .fromOpaque(info)
                .takeUnretainedValue()
            collector.scheduleScan()
        }
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )
        guard let stream else {
            emit("파일 변경 감시를 시작하지 못했습니다.", isError: true)
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            emit("파일 변경 감시를 시작하지 못했습니다.", isError: true)
            return
        }
        eventStream = stream
    }

    private func scheduleScan(immediate: Bool = false) {
        guard !scanPending else { return }
        scanPending = true
        let delay = immediate ? 0 : 0.15
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scanPending = false
            guard self.started else { return }
            let summary = self.scan(now: Date())
            if summary.errors.isEmpty {
                let suffix = summary.catchUpFiles > 0
                    ? " · 과거 기록 따라잡는 중 \(summary.catchUpFiles)"
                    : ""
                self.emit(
                    "모니터링 중 · \(summary.recordsIngested)개 새 기록 확인\(suffix)",
                    isError: false
                )
                if summary.catchUpFiles > 0 {
                    self.scheduleScan(immediate: true)
                }
            }
        }
    }

    private func scan(now: Date) -> IngestSummary {
        var summary = IngestSummary()
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        var files: [(
            url: URL,
            realPath: String,
            modified: Date,
            inode: Int64,
            size: Int64
        )] = []
        var seenDirectories = Set<String>()
        for sessionDirectory in sessionsDirectories {
            let sessions: URL
            switch sessionDirectoryState(sessionDirectory) {
            case .missing:
                continue
            case .failure(let message):
                summary.errors.append(message)
                emit(message, isError: true)
                continue
            case .directory(let resolved):
                guard seenDirectories.insert(resolved.path).inserted else {
                    continue
                }
                sessions = resolved
            }
            guard let enumerator = FileManager.default.enumerator(
                at: sessions,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    let message =
                        "\(url.path): \(error.localizedDescription)"
                    summary.errors.append(message)
                    self.emit(message, isError: true)
                    return true
                }
            ) else {
                let message = "세션 폴더를 읽을 수 없습니다: \(sessions.path)"
                summary.errors.append(message)
                emit(message, isError: true)
                continue
            }
            while let enumeratedFile = enumerator.nextObject() as? URL {
                guard enumeratedFile.pathExtension == "jsonl" else { continue }
                do {
                    let file = enumeratedFile
                    let realPath = file.resolvingSymlinksInPath().path
                    let values = try file.resourceValues(forKeys: Set(keys))
                    guard values.isRegularFile == true else { continue }
                    let attributes = try FileManager.default.attributesOfItem(
                        atPath: file.path
                    )
                    guard let inodeNumber = attributes[.systemFileNumber] as? NSNumber,
                          let sizeNumber = attributes[.size] as? NSNumber else {
                        throw AgentBoardDatabaseError.invalidData(
                            "file metadata missing: \(file.lastPathComponent)"
                        )
                    }
                    files.append((
                        file,
                        realPath,
                        values.contentModificationDate ?? now,
                        inodeNumber.int64Value,
                        sizeNumber.int64Value
                    ))
                } catch {
                    let message =
                        "\(enumeratedFile.path): \(error.localizedDescription)"
                    summary.errors.append(message)
                    emit(message, isError: true)
                }
            }
        }
        var seenPaths = Set<String>()
        files = files.filter {
            seenPaths.insert($0.realPath).inserted
        }
        files.sort {
            if $0.modified != $1.modified {
                return $0.modified > $1.modified
            }
            return $0.url.path < $1.url.path
        }
        for file in files {
            do {
                summary.filesScanned += 1
                let cursor = try store.cursor(path: file.url.path)
                let resetCursor = cursor == nil
                    || cursor!.inode != file.inode
                    || cursor!.offset > file.size
                    || cursor!.context.header == nil
                var effectiveHeader = cursor?.context.header
                if !resetCursor,
                   let oldHeader = cursor?.context.header,
                   oldHeader.provider == nil,
                   oldHeader.originator == nil,
                   oldHeader.threadSource == nil,
                   let refreshed = try readSessionHeader(
                       file: file.url,
                       expectedID: oldHeader.id
                   ) {
                    try store.updateCursorHeader(
                        path: file.url.path,
                        expectedCardId: oldHeader.id,
                        header: refreshed,
                        now: now
                    )
                    effectiveHeader = refreshed
                }
                if !resetCursor,
                   let effectiveHeader,
                   effectiveHeader.provider == nil {
                    continue
                }
                if !resetCursor, let header = effectiveHeader {
                    do {
                        try repairIdentityIfNeeded(
                            file: file.url,
                            cardId: header.id,
                            fileSize: file.size
                        )
                        try repairResponseStateIfNeeded(
                            file: file.url,
                            cardId: header.id,
                            fileSize: file.size,
                            modifiedAt: file.modified
                        )
                    } catch {
                        let message = "\(file.url.lastPathComponent) 정체성 repair 실패: \(error.localizedDescription)"
                        summary.errors.append(message)
                        emit(message, isError: true)
                    }
                }
                let start: Int64
                if let cursor, !resetCursor {
                    start = cursor.offset
                } else {
                    start = 0
                }
                let discard = resetCursor ? false : (cursor?.discardUntilNewline ?? false)
                let batch = try IncrementalLineReader.readCompleteLines(
                    path: file.url.path,
                    from: start,
                    discardUntilNewline: discard,
                    maximumBytes: resetCursor
                        ? 64 * 1_024
                        : 2 * 1_024 * 1_024
                )
                guard batch.nextOffset != start
                    || !batch.lines.isEmpty
                    || batch.discardUntilNewline != discard else {
                    continue
                }
                var records: [ParsedRecord] = []
                records.reserveCapacity(batch.lines.count)
                for line in batch.lines {
                    if let record = SessionLineParser.parse(
                        line,
                        fallbackDate: file.modified,
                        trustPolicy: trustPolicy
                    ) {
                        records.append(record)
                    }
                }
                try store.ingest(
                    records: records,
                    path: file.url.path,
                    inode: file.inode,
                    endOffset: batch.nextOffset,
                    discardUntilNewline: batch.discardUntilNewline,
                    now: now
                )
                summary.recordsIngested += batch.lines.count
                if batch.reachedReadLimit
                    && (batch.nextOffset > start || batch.discardUntilNewline) {
                    summary.catchUpFiles += 1
                }
            } catch {
                let message = "\(file.url.lastPathComponent): \(error.localizedDescription)"
                summary.errors.append(message)
                emit(message, isError: true)
            }
        }

        if lastPruneAt == nil || now.timeIntervalSince(lastPruneAt!) > 60 * 60 {
            do {
                _ = try store.pruneCompleted(
                    olderThan: now.addingTimeInterval(-30 * 24 * 60 * 60)
                )
                lastPruneAt = now
            } catch {
                let message = "완료 기록 정리 실패: \(error.localizedDescription)"
                summary.errors.append(message)
                emit(message, isError: true)
            }
        }

        if !summary.errors.isEmpty {
            emit(
                "\(summary.errors.count)개 파일 처리 실패 · 재시도합니다",
                isError: true
            )
        }
        return summary
    }

    private func readSessionHeader(
        file: URL,
        expectedID: UUID
    ) throws -> SessionHeader? {
        let batch = try IncrementalLineReader.readCompleteLines(
            path: file.path,
            from: 0,
            maximumBytes: 1_024 * 1_024
        )
        for line in batch.lines {
            guard let record = SessionLineParser.parse(
                line,
                trustPolicy: trustPolicy
            ) else {
                continue
            }
            if case .sessionMeta(let header) = record.signal,
               header.id == expectedID {
                return header
            }
        }
        return nil
    }

    private func sessionDirectoryState(
        _ sessions: URL
    ) -> SessionDirectoryState {
        let canonicalPath = sessions.withUnsafeFileSystemRepresentation {
            path -> UnsafeMutablePointer<CChar>? in
            guard let path else {
                errno = ENOENT
                return nil
            }
            return realpath(path, nil)
        }
        guard let canonicalPath else {
            let errorCode = errno
            if errorCode == ENOENT {
                return .missing
            }
            let description = String(
                cString: strerror(errorCode)
            )
            return .failure(
                "세션 폴더를 읽을 수 없습니다: \(sessions.path) (\(description))"
            )
        }
        defer { free(canonicalPath) }
        var fileStatus = stat()
        guard lstat(canonicalPath, &fileStatus) == 0 else {
            let errorCode = errno
            let description = String(cString: strerror(errorCode))
            return .failure(
                "세션 폴더를 읽을 수 없습니다: \(sessions.path) (\(description))"
            )
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(
                "세션 경로가 폴더가 아닙니다: \(sessions.path)"
            )
        }
        return .directory(
            URL(
                fileURLWithPath: String(cString: canonicalPath),
                isDirectory: true
            )
        )
    }

    private static func normalizedHomes(_ homes: [URL]) -> [URL] {
        let candidates = homes.isEmpty
            ? [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex", isDirectory: true)
            ]
            : homes
        var seen = Set<String>()
        let normalized = candidates.compactMap { home -> URL? in
            let standardized = home.standardizedFileURL
            let value = FileManager.default.fileExists(atPath: standardized.path)
                ? standardized.resolvingSymlinksInPath()
                : standardized
            return seen.insert(value.path).inserted ? value : nil
        }
        return normalized.isEmpty
            ? [FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)]
            : normalized
    }

    private func emit(_ message: String, isError: Bool) {
        onUpdate?(CollectorUpdate(message: message, isError: isError))
    }

    private func repairIdentityIfNeeded(
        file: URL,
        cardId: UUID,
        fileSize: Int64
    ) throws {
        let progress = try store.identityRepairProgress(
            path: file.path,
            cardId: cardId
        )
        guard !progress.isComplete else {
            return
        }
        guard fileSize > 0 else { return }
        guard progress.searchedBytes < fileSize,
              progress.searchedBytes < Self.maximumIdentityRepairBytes else {
            return
        }
        let minimumScan: Int64 = 1_024 * 1_024
        let prefixLimit: Int64
        if progress.searchedBytes <= 0 {
            prefixLimit = min(fileSize, minimumScan)
        } else {
            let doubled = progress.searchedBytes > Int64.max / 2
                ? Int64.max
                : progress.searchedBytes * 2
            prefixLimit = min(
                fileSize,
                Self.maximumIdentityRepairBytes,
                max(minimumScan, doubled)
            )
        }
        let prefix = try IncrementalLineReader.readCompleteLines(
            path: file.path,
            from: 0,
            maximumBytes: Int(prefixLimit),
            maximumLineBytes: SessionLineParser.maximumLineBytes
        )
        var identity: TitleSanitizer.TaskIdentity?
        var contaminations: [TitleSanitizer.LegacyInjectionContamination] = []
        for line in prefix.lines {
            guard let record = SessionLineParser.parse(
                line,
                trustPolicy: trustPolicy
            ) else {
                continue
            }
            if case .userMessage(let text, _) = record.signal {
                for contamination in TitleSanitizer
                    .legacyInjectionContaminations(in: text) {
                    if !contaminations.contains(contamination) {
                        contaminations.append(contamination)
                    }
                }
                if identity == nil,
                   let candidate = TitleSanitizer.taskIdentity(text) {
                    identity = candidate
                }
            }
        }
        let complete = identity != nil
        try store.repairTaskIdentity(
            cardId: cardId,
            path: file.path,
            identity: identity,
            contaminations: contaminations,
            searchedBytes: prefixLimit,
            complete: complete
        )
    }

    private func repairResponseStateIfNeeded(
        file: URL,
        cardId: UUID,
        fileSize: Int64,
        modifiedAt: Date
    ) throws {
        guard let card = try store.card(cardId: cardId),
              card.responseLifecycle == nil,
              let turnId = card.currentTurnId,
              try !store.responseStateRepairCompleted(
                  path: file.path,
                  cardId: cardId,
                  turnId: turnId
              ),
              try !store.responseStateScanIsCurrent(
                  path: file.path,
                  cardId: cardId,
                  turnId: turnId,
                  fileSize: fileSize,
                  modifiedAt: modifiedAt
              ) else {
            return
        }
        let lines = try IncrementalLineReader.readTailCompleteLines(
            path: file.path
        )
        var evidence: ResponseLifecycleEvidence?
        var activeTurnId: String?
        for line in lines {
            guard let record = SessionLineParser.parse(
                line,
                trustPolicy: trustPolicy
            ) else {
                continue
            }
            switch record.signal {
            case .taskStarted(let recordTurn):
                activeTurnId = recordTurn
                if recordTurn == turnId, evidence == nil {
                    evidence = .running(record.timestamp)
                }
            case .taskComplete(let recordTurn):
                let belongsToCurrentTurn = recordTurn == turnId
                    || (recordTurn == nil && activeTurnId == turnId)
                if belongsToCurrentTurn {
                    if evidence == nil || isRunningEvidence(evidence) {
                        evidence = .completed(record.timestamp)
                    }
                }
            case .turnAborted(let reason, let recordTurn):
                let belongsToCurrentTurn = recordTurn == turnId
                    || (recordTurn == nil && activeTurnId == turnId)
                if belongsToCurrentTurn {
                    if evidence == nil || isRunningEvidence(evidence) {
                        let lower = reason.lowercased()
                        evidence = lower.contains("error")
                            || lower.contains("fail")
                            ? .error(record.timestamp)
                            : .interrupted(record.timestamp)
                    }
                }
            case .turnContext(let recordTurn, _):
                if let recordTurn {
                    activeTurnId = recordTurn
                    if recordTurn == turnId, evidence == nil {
                        evidence = .running(record.timestamp)
                    }
                }
            default:
                break
            }
        }
        if let evidence {
            try store.repairResponseLifecycle(
                cardId: cardId,
                path: file.path,
                turnId: turnId,
                evidence: evidence
            )
        } else {
            try store.recordResponseStateScan(
                path: file.path,
                cardId: cardId,
                turnId: turnId,
                fileSize: fileSize,
                modifiedAt: modifiedAt
            )
        }
    }

    private func isRunningEvidence(
        _ evidence: ResponseLifecycleEvidence?
    ) -> Bool {
        if let evidence, case .running = evidence { return true }
        return false
    }
}
