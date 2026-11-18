import AgentBoardCore
import Darwin
import Foundation
import SQLite3

private var totalChecks = 0
private var failures: [String] = []
private let testTrustPolicy = ReportTrustPolicy(
    additionalHelperPaths: ["/Users/me/.local/bin/agentboard"]
)

private func check(
    _ condition: @autoclosure () throws -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    totalChecks += 1
    if try !condition() {
        failures.append("\(file):\(line): \(message)")
    }
}

private func checkThrows<T>(
    _ body: () throws -> T,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalChecks += 1
    do {
        _ = try body()
        failures.append("\(file):\(line): \(message)")
    } catch {
        // Expected.
    }
}

private func run(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("ok - \(name)")
        fflush(stdout)
    } catch {
        failures.append("\(name): \(error)")
        print("FAIL - \(name): \(error)")
        fflush(stdout)
    }
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func jsonLine(_ object: [String: Any]) throws -> Data {
    try jsonData(object)
}

private func sessionMeta(
    id: String,
    source: String = "cli",
    provider: String = "openai",
    originator: String? = nil,
    threadSource: String? = nil,
    cwd: String = "/tmp/project",
    timestamp: String
) throws -> Data {
    var payload: [String: Any] = [
        "id": id,
        "source": source,
        "cwd": cwd,
        "model_provider": provider,
        "cli_version": "0.167.1",
        "history_mode": "paginated"
    ]
    if let originator {
        payload["originator"] = originator
    }
    if let threadSource {
        payload["thread_source"] = threadSource
    }
    return try jsonLine([
        "timestamp": timestamp,
        "type": "session_meta",
        "payload": payload
    ])
}

private func event(
    _ type: String,
    timestamp: String,
    extra: [String: Any] = [:]
) throws -> Data {
    var payload = extra
    payload["type"] = type
    return try jsonLine([
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": payload
    ])
}

private func response(
    _ type: String,
    timestamp: String,
    payload: [String: Any]
) throws -> Data {
    var body = payload
    body["type"] = type
    return try jsonLine([
        "timestamp": timestamp,
        "type": "response_item",
        "payload": body
    ])
}

private func reportEnvelope(
    threadId: UUID,
    eventId: UUID,
    timestamp: Date,
    state: TaskState,
    title: String = "검증 작업",
    steps: [ReportStep] = [],
    summary: String? = "상태를 보고합니다."
) throws -> ReportEnvelope {
    ReportEnvelope(
        eventId: eventId,
        threadId: threadId,
        timestamp: timestamp,
        payload: ReportPayload(
            title: title,
            state: state,
            steps: steps,
            summary: summary
        )
    )
}

private func reportMarker(_ envelope: ReportEnvelope) throws -> String {
    let data = try ReportValidator.encodeEnvelope(envelope)
    return SessionLineParser.reportMarker + (String(data: data, encoding: .utf8) ?? "")
}

private func callLine(
    callId: String,
    command: String,
    timestamp: String,
    custom: Bool = false,
    toolName: String? = nil
) throws -> Data {
    if custom {
        return try response(
            "custom_tool_call",
            timestamp: timestamp,
            payload: [
                "call_id": callId,
                "name": toolName ?? "exec",
                "input": #"const r = await tools.exec_command({cmd:""# + command + #""});"#
            ]
        )
    }
    let arguments = try jsonData(["cmd": command])
    return try response(
        "function_call",
        timestamp: timestamp,
        payload: [
            "call_id": callId,
            "name": toolName ?? "exec_command",
            "arguments": String(data: arguments, encoding: .utf8)!
        ]
    )
}

private func outputLine(
    callId: String,
    output: Any,
    timestamp: String,
    custom: Bool = false
) throws -> Data {
    try response(
        custom ? "custom_tool_call_output" : "function_call_output",
        timestamp: timestamp,
        payload: [
            "call_id": callId,
            "output": output
        ]
    )
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentBoardTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func append(_ data: Data, to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    } else {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}

private func schemaObjects(path: String) throws -> Set<String> {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw AgentBoardDatabaseError.open("test schema query")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT name FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%'",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw AgentBoardDatabaseError.sqlite("test schema prepare")
    }
    defer { sqlite3_finalize(statement) }
    var names = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
        if let value = sqlite3_column_text(statement, 0) {
            names.insert(String(cString: value))
        }
    }
    return names
}

private func cursorDiscardStates(path: String) throws -> [Bool] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw AgentBoardDatabaseError.open("test cursor query")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT discard_until_newline FROM cursors",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw AgentBoardDatabaseError.sqlite("test cursor prepare")
    }
    defer { sqlite3_finalize(statement) }
    var values: [Bool] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        values.append(sqlite3_column_int(statement, 0) != 0)
    }
    return values
}

private func cursorOffsets(path: String) throws -> [Int64] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw AgentBoardDatabaseError.open("test cursor offset query")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT offset FROM cursors ORDER BY path",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw AgentBoardDatabaseError.sqlite("test cursor offset prepare")
    }
    defer { sqlite3_finalize(statement) }
    var offsets: [Int64] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        offsets.append(sqlite3_column_int64(statement, 0))
    }
    return offsets
}

private func executeSQL(path: String, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let database else {
        throw AgentBoardDatabaseError.open("test sqlite update")
    }
    defer { sqlite3_close(database) }
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
        throw AgentBoardDatabaseError.sqlite(
            String(cString: sqlite3_errmsg(database))
        )
    }
}

private func reportTitles(path: String, threadId: UUID) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw AgentBoardDatabaseError.open("test report query")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT payload FROM report_events WHERE thread_id = ? ORDER BY timestamp DESC",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw AgentBoardDatabaseError.sqlite("test report prepare")
    }
    defer { sqlite3_finalize(statement) }
    let id = threadId.uuidString
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = id.withCString {
        sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    var titles: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        let count = Int(sqlite3_column_bytes(statement, 0))
        if let bytes = sqlite3_column_blob(statement, 0),
           let payload = try? JSONDecoder().decode(
               ReportPayload.self,
               from: Data(bytes: bytes, count: count)
           ) {
            if let title = payload.title {
                titles.append(title)
            }
        }
    }
    return titles
}

private func ingest(
    _ lines: [Data],
    store: StateStore,
    path: String = "/tmp/session.jsonl",
    inode: Int64 = 1,
    now: Date = Date()
) throws {
    var offset: Int64 = 0
    if let cursor = try store.cursor(path: path) {
        offset = cursor.offset
    }
    var records: [ParsedRecord] = []
    for line in lines {
        if let record = SessionLineParser.parse(
            line,
            fallbackDate: now,
            trustPolicy: testTrustPolicy
        ) {
            records.append(record)
        }
    }
    try store.ingest(
        records: records,
        path: path,
        inode: inode,
        endOffset: offset + Int64(lines.reduce(0) { $0 + $1.count + 1 }),
        now: now
    )
}

private func ingestRecords(
    _ records: [ParsedRecord],
    store: StateStore,
    path: String,
    inode: Int64,
    now: Date = Date()
) throws {
    let offset = try store.cursor(path: path)?.offset ?? 0
    try store.ingest(
        records: records,
        path: path,
        inode: inode,
        endOffset: offset + Int64(records.count * 128),
        now: now
    )
}

run("report payload validation is strict") {
    check(
        AgentBoardDate.parse("2026-11-11T01:02:03.456Z") != nil,
        "fractional ISO8601 timestamps should parse"
    )
    check(
        AgentBoardDate.parse("2026-11-11T01:02:03Z") != nil,
        "plain ISO8601 timestamps should parse"
    )
    let validMap: [String: Any] = [
        "title": "작업",
        "state": "running",
        "steps": [
            ["id": "one", "title": "첫 단계", "status": "inProgress"],
            ["id": "two", "title": "둘째 단계", "status": "pending"]
        ],
        "summary": "진행 중"
        ,
        "description": "전체 작업 목적"
    ]
    let valid = try jsonData(validMap)
    let payload = try ReportValidator.decodePayload(valid)
    check(payload.steps.count == 2, "steps should decode")
    check(payload.description == "전체 작업 목적", "optional description should decode")

    let invalidCompletedMap: [String: Any] = [
        "title": "작업",
        "state": "completed",
        "steps": [
            ["id": "one", "title": "미완료", "status": "pending"]
        ],
        "summary": "끝"
    ]
    let invalidCompleted = try jsonData(invalidCompletedMap)
    checkThrows(
        { try ReportValidator.decodePayload(invalidCompleted) },
        "completed with pending steps must fail"
    )

    let unknownMap: [String: Any] = [
        "state": "running",
        "steps": [] as [Any],
        "unexpected": true
    ]
    let unknown = try jsonData(unknownMap)
    checkThrows(
        { try ReportValidator.decodePayload(unknown) },
        "unknown payload fields must fail"
    )

    let missingSteps = try jsonData([
        "state": "running"
    ] as [String: Any])
    checkThrows(
        { try ReportValidator.decodePayload(missingSteps) },
        "full snapshots must include a steps array"
    )
}

run("origin metadata is optional, strict, and separate from payload") {
    let thread = UUID(uuidString: "ABABABAB-ABAB-4BAB-8BAB-ABABABABABAB")!
    let windowId = "10000000-0000-4000-8000-000000000001"
    let workspaceId = "20000000-0000-4000-8000-000000000002"
    let surfaceId = "30000000-0000-4000-8000-000000000003"
    let cmuxOrigin = SessionOrigin.fromEnvironment([
        "CMUX_WINDOW_ID": windowId,
        "CMUX_WORKSPACE_ID": workspaceId,
        "CMUX_SURFACE_ID": surfaceId,
        "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
        "CMUX_BUNDLED_CLI_PATH": "/Applications/cmux.app/Contents/Resources/bin/cmux"
    ])
    check(cmuxOrigin?.windowId == windowId
            && cmuxOrigin?.workspaceId == workspaceId
            && cmuxOrigin?.surfaceId == surfaceId,
          "cmux environment should produce explicit window/workspace/surface IDs")
    let herdrOrigin = SessionOrigin.fromEnvironment([
        "HERDR_ENV": "1",
        "HERDR_WORKSPACE_ID": "w1",
        "HERDR_TAB_ID": "w1:t1",
        "HERDR_PANE_ID": "w1:p1",
        "HERDR_SESSION": "agentboard-test",
        "HERDR_SOCKET_PATH": "/tmp/herdr.sock"
    ])
    check(herdrOrigin?.kind == .herdr
            && herdrOrigin?.paneId == "w1:p1"
            && herdrOrigin?.sessionName == "agentboard-test"
            && herdrOrigin?.socketPath == "/tmp/herdr.sock",
          "Herdr environment should preserve pane, session, and socket")
    check(
        SessionOrigin.fromEnvironment([
            "CMUX_WORKSPACE_ID": "bad id; command",
            "CMUX_SURFACE_ID": "surface"
        ]) == nil,
        "unsafe origin identifier should be rejected"
    )

    let envelope = ReportEnvelope(
        threadId: thread,
        timestamp: AgentBoardDate.parse("2026-11-13T13:00:02.000Z")!,
        payload: ReportPayload(
            title: "origin report",
            state: .running,
            steps: [],
            summary: "running"
        ),
        origin: cmuxOrigin
    )
    let encoded = try ReportValidator.encodeEnvelope(envelope)
    let decoded = try ReportValidator.decodeEnvelope(encoded)
    check(decoded.origin == cmuxOrigin,
          "optional origin metadata should round-trip")
    var card = AgentCard(
        id: thread,
        provider: .openai,
        title: "origin card",
        cwd: "/tmp/origin",
        state: .running,
        responseLifecycle: .running
    )
    SessionReducer.applyReport(decoded, to: &card)
    check(card.origin == cmuxOrigin,
          "report origin should attach to its matching card")

    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("origin.sqlite3").path)
    try ingest(
        try [
            sessionMeta(
                id: thread.uuidString,
                timestamp: "2026-11-13T13:00:00.000Z"
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T13:00:01.000Z",
                extra: ["turn_id": "origin"]
            ),
            callLine(
                callId: "origin-report",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-13T13:00:01.500Z"
            ),
            outputLine(
                callId: "origin-report",
                output: try reportMarker(decoded),
                timestamp: "2026-11-13T13:00:02.000Z"
            )
        ],
        store: store,
        path: "/tmp/origin-capture.jsonl"
    )
    let storedCard = try store.loadCards().first
    check(storedCard?.provider == .openai
            && storedCard?.origin == cmuxOrigin,
          "provider/thread card should persist validated origin location")

    let executablePayloadMap: [String: Any] = [
        "title": "bad",
        "state": "running",
        "steps": [] as [Any],
        "summary": "bad"
    ]
    let executablePayload = try jsonData(executablePayloadMap)
    checkThrows(
        {
            let object = try JSONSerialization.jsonObject(
                with: executablePayload
            ) as! [String: Any]
            let envelopeObject: [String: Any] = [
                "version": 1,
                "eventId": UUID().uuidString,
                "threadId": thread.uuidString,
                "timestamp": AgentBoardDate.string(Date()),
                "payload": object,
                "origin": ["kind": "cmux", "command": "rm -rf /"]
            ]
            let data = try JSONSerialization.data(withJSONObject: envelopeObject)
            _ = try ReportValidator.decodeEnvelope(data)
        },
        "payload and origin must reject arbitrary executable commands"
    )
}

run("CLI-style command recognition rejects quoted documentation") {
    check(
        SessionLineParser.reportCommandsAreValid(
            "/Users/me/.local/bin/agentboard report --json '{}'",
            trustPolicy: testTrustPolicy
        ),
        "absolute helper invocation should be accepted"
    )
    check(
        !SessionLineParser.reportCommandsAreValid("cat README.md"),
        "cat should be rejected"
    )
    check(
        !SessionLineParser.reportCommandsAreValid("echo 'agentboard report --json'"),
        "echo should be rejected"
    )
    check(
        !SessionLineParser.reportCommandsAreValid("echo \"quoted; agentboard report --json ''\""),
        "semicolon inside quoted documentation must not become a command"
    )
    check(
        !SessionLineParser.reportCommandsAreValid("printf 'agentboard report'"),
        "printf should be rejected"
    )
    check(
        !SessionLineParser.reportCommandsAreValid("agentboard report --json '{}'"),
        "bare executable name should be rejected"
    )
    check(
        !SessionLineParser.reportCommandsAreValid("~/.local/bin/agentboard report --json '{}' | sed -n 1p"),
        "piped compound command must be rejected"
    )
    check(
        !SessionLineParser.reportCommandsAreValid(
            "/tmp/agentboard report --json '{}'",
            trustPolicy: testTrustPolicy
        ),
        "untrusted absolute helper paths must be rejected"
    )
    check(
        !SessionLineParser.reportCommandsAreValid(
            "/anything/.local/bin/agentboard report --json '{}'",
            trustPolicy: testTrustPolicy
        ),
        "lookalike local-bin path must be rejected"
    )
    let actualDefault = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/agentboard").path
    check(
        SessionLineParser.reportCommandsAreValid(
            "\(actualDefault) report --json '{}'"
        ),
        "actual default installed helper path should be trusted"
    )
    check(
        !SessionLineParser.reportCommandsAreValid(
            "false && /Users/me/.local/bin/agentboard report --json '{}'",
            trustPolicy: testTrustPolicy
        ),
        "compound shell command must be rejected"
    )
    check(
        !SessionLineParser.reportCommandsAreValid(
            "/Users/me/.local/bin/agentboard report --json '{}'; printf fake",
            trustPolicy: testTrustPolicy
        ),
        "trailing shell command must be rejected"
    )
}

run("custom exec input uses the actual tool command, not quoted context") {
    let spoof = try jsonLine([
        "timestamp": "2026-11-11T01:30:00.000Z",
        "type": "response_item",
        "payload": [
            "type": "custom_tool_call",
            "call_id": "spoof-custom",
            "name": "exec",
            "input": #"text("Example: tools.exec_command({cmd:\"agentboard report --json '{}'\"})"); await tools.exec_command({cmd:"cat README.md"});"#
        ]
    ])
    let parsed = SessionLineParser.parse(spoof)
    if case .toolCall(_, let eligible, _)? = parsed?.signal {
        check(!eligible, "quoted example must not authorize the cat command")
    } else {
        check(false, "custom tool call should parse")
    }

    let multiple = try jsonLine([
        "timestamp": "2026-11-11T01:31:00.000Z",
        "type": "response_item",
        "payload": [
            "type": "custom_tool_call",
            "call_id": "multiple-custom",
            "name": "exec",
            "input": #"await tools.exec_command({cmd:"/Users/me/.local/bin/agentboard report --json '{}'"}); await tools.exec_command({cmd:"printf fake"});"#
        ]
    ])
    if case .toolCall(_, let eligible, _)? = SessionLineParser.parse(
        multiple,
        trustPolicy: testTrustPolicy
    )?.signal {
        check(!eligible, "multiple exec_command wrappers must be rejected")
    } else {
        check(false, "multiple custom call should parse as ineligible")
    }

    let commented = try jsonLine([
        "timestamp": "2026-11-11T01:32:00.000Z",
        "type": "response_item",
        "payload": [
            "type": "custom_tool_call",
            "call_id": "commented-custom",
            "name": "exec",
            "input": #"// tools.exec_command({cmd:"/Users/me/.local/bin/agentboard report --json '{}'"});\nawait tools.exec_command({cmd:"printf fake"});"#
        ]
    ])
    if case .toolCall(_, let eligible, _)? = SessionLineParser.parse(
        commented,
        trustPolicy: testTrustPolicy
    )?.signal {
        check(!eligible, "commented report wrapper must be rejected")
    } else {
        check(false, "commented custom call should parse as ineligible")
    }

    let quotedThread = UUID(uuidString: "AB12AB12-AB12-4B12-8B12-AB12AB12AB12")!
    let quotedCall = try jsonLine([
        "timestamp": "2026-11-11T01:33:00.000Z",
        "type": "response_item",
        "payload": [
            "type": "custom_tool_call",
            "call_id": "quoted-helper",
            "name": "exec",
            "input": #"text(await tools.exec_command({cmd:"\"/Users/me/.local/bin/agentboard\" report --json '{}'", "max_output_tokens":300}));"#
        ]
    ])
    let quotedRecord = SessionLineParser.parse(
        quotedCall,
        trustPolicy: testTrustPolicy
    )
    if case .toolCall(_, let eligible, _)? = quotedRecord?.signal {
        check(eligible, "quoted absolute helper path should decode as eligible")
    } else {
        check(false, "quoted helper custom call should parse")
    }
    let quotedReport = try reportEnvelope(
        threadId: quotedThread,
        eventId: UUID(uuidString: "AB34AB34-AB34-4B34-8B34-AB34AB34AB34")!,
        timestamp: AgentBoardDate.parse("2026-11-11T01:33:02.000Z")!,
        state: .waiting,
        summary: "quoted helper report"
    )
    let quotedRecords = try [
        SessionLineParser.parse(
            sessionMeta(
                id: quotedThread.uuidString,
                timestamp: "2026-11-11T01:32:58.000Z"
            ),
            trustPolicy: testTrustPolicy
        ),
        SessionLineParser.parse(
            event(
                "task_started",
                timestamp: "2026-11-11T01:32:59.000Z",
                extra: ["turn_id": "quoted"]
            ),
            trustPolicy: testTrustPolicy
        ),
        quotedRecord,
        SessionLineParser.parse(
            outputLine(
                callId: "quoted-helper",
                output: try reportMarker(quotedReport),
                timestamp: "2026-11-11T01:33:02.000Z"
            ),
            trustPolicy: testTrustPolicy
        )
    ].compactMap { $0 }
    let quotedResult = SessionReducer.reduce(
        records: quotedRecords,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    check(quotedResult.reportEvents.count == 1,
          "quoted standalone helper output should yield one report")
    check(quotedResult.card?.state == .running,
          "report waiting must not override active response lifecycle")
    check(quotedResult.card?.reportedState == .waiting,
          "quoted standalone helper report should preserve reported state")
}

run("source and provider filters create separate provider cards") {
    let gpt = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    let ds = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    let editor = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
    let desktop = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCD")!
    let subagent = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCE")!
    let unknownSource = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCF")!
    let unknownProvider = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCD0")!
    let now = Date()
    let gptRecords = try [
        sessionMeta(id: gpt.uuidString, provider: "openai", timestamp: "2026-11-11T01:00:00.000Z"),
        event("task_started", timestamp: "2026-11-11T01:00:01.000Z", extra: ["turn_id": "turn-1"]),
        event("user_message", timestamp: "2026-11-11T01:00:02.000Z", extra: ["message": "같은 작업 GPT"])
    ].compactMap {
        SessionLineParser.parse($0, fallbackDate: now, trustPolicy: testTrustPolicy)
    }
    let dsRecords = try [
        sessionMeta(id: ds.uuidString, provider: "deepseek", timestamp: "2026-11-11T01:01:00.000Z"),
        event("task_started", timestamp: "2026-11-11T01:01:01.000Z", extra: ["turn_id": "turn-2"]),
        event("user_message", timestamp: "2026-11-11T01:01:02.000Z", extra: ["message": "같은 작업 DeepSeek"])
    ].compactMap {
        SessionLineParser.parse($0, fallbackDate: now, trustPolicy: testTrustPolicy)
    }
    let editorRecords = try [
        sessionMeta(
            id: editor.uuidString,
            source: "vscode",
            provider: "openai",
            originator: "codex-tui",
            threadSource: "user",
            timestamp: "2026-11-11T01:02:00.000Z"
        )
    ].compactMap {
        SessionLineParser.parse($0, fallbackDate: now, trustPolicy: testTrustPolicy)
    }
    let desktopRecords = try [
        sessionMeta(
            id: desktop.uuidString,
            source: "vscode",
            provider: "openai",
            originator: "Codex Desktop",
            threadSource: "user",
            timestamp: "2026-11-11T01:02:10.000Z"
        )
    ].compactMap {
        SessionLineParser.parse($0, fallbackDate: now, trustPolicy: testTrustPolicy)
    }
    let excludedRecords = try [
        sessionMeta(
            id: subagent.uuidString,
            source: "vscode",
            provider: "openai",
            originator: "codex-tui",
            threadSource: "subagent",
            timestamp: "2026-11-11T01:02:20.000Z"
        ),
        sessionMeta(
            id: unknownSource.uuidString,
            source: "system",
            provider: "openai",
            threadSource: "user",
            timestamp: "2026-11-11T01:02:30.000Z"
        ),
        sessionMeta(
            id: unknownProvider.uuidString,
            source: "cli",
            provider: "other",
            timestamp: "2026-11-11T01:02:40.000Z"
        )
    ].compactMap {
        SessionLineParser.parse($0, fallbackDate: now, trustPolicy: testTrustPolicy)
    }

    let gptResult = SessionReducer.reduce(
        records: gptRecords,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    let dsResult = SessionReducer.reduce(
        records: dsRecords,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    let editorResult = SessionReducer.reduce(
        records: editorRecords,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    let desktopResult = SessionReducer.reduce(
        records: desktopRecords,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    let excludedResult = SessionReducer.reduce(
        records: excludedRecords,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    check(gptResult.card?.provider == .openai, "GPT provider should be labeled")
    check(dsResult.card?.provider == .deepseek, "DeepSeek provider should be labeled")
    check(gptResult.card?.id != dsResult.card?.id, "same task must still use separate UUID cards")
    check(editorResult.card?.provider == .openai,
          "vscode codex-tui user conversation should be collected")
    check(desktopResult.card?.provider == .openai,
          "vscode Codex Desktop user conversation should be collected")
    check(excludedResult.card == nil,
          "subagent, system, and unknown provider sources must be ignored")
}

run("excluded vscode cursor rehydrates and ingests appended completion") {
    let directory = try temporaryDirectory()
    let codexHome = directory.appendingPathComponent("vscode-resume", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/10/27", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sessions,
        withIntermediateDirectories: true
    )
    let thread = UUID(
        uuidString: "01A17B28-893E-7582-9EDB-C92B4E90CDCC"
    )!
    let fileURL = sessions.appendingPathComponent("rollout-resumed.jsonl")
    let initialLines = try [
        sessionMeta(
            id: thread.uuidString,
            source: "vscode",
            provider: "openai",
            originator: "codex-tui",
            threadSource: "user",
            cwd: "/Users/me/msa",
            timestamp: "2026-10-27T11:20:00.000Z"
        )
    ]
    try initialLines.reduce(Data()) {
        $0 + $1 + Data("\n".utf8)
    }.write(to: fileURL)
    let enumerator = FileManager.default.enumerator(
        at: codexHome,
        includingPropertiesForKeys: nil
    )
    var file: URL?
    while let candidate = enumerator?.nextObject() as? URL {
        if candidate.lastPathComponent == fileURL.lastPathComponent {
            file = candidate
            break
        }
    }
    guard let resolvedFile = file else {
        check(false, "vscode fixture should be enumerable")
        return
    }
    let initialSize = (try FileManager.default.attributesOfItem(
        atPath: resolvedFile.path
    )[.size] as! NSNumber).int64Value
    let store = try StateStore(
        path: directory.appendingPathComponent("vscode-resume.sqlite3").path
    )
    let legacyHeader = SessionHeader(
        id: thread,
        source: "vscode",
        cwd: "/Users/me/msa",
        modelProvider: "openai",
        cliVersion: "0.167.1",
        historyMode: "paginated"
    )
    try store.ingest(
        records: [
            ParsedRecord(
                timestamp: AgentBoardDate.parse(
                    "2026-10-27T11:20:00.000Z"
                )!,
                signal: .sessionMeta(legacyHeader)
            )
        ],
        path: resolvedFile.path,
        inode: (try FileManager.default.attributesOfItem(
            atPath: resolvedFile.path
        )[.systemFileNumber] as! NSNumber).int64Value,
        endOffset: initialSize
    )
    let appended = try [
        event(
            "task_started",
            timestamp: "2026-10-27T11:22:00.000Z",
            extra: ["turn_id": "resumed-turn"]
        ),
        event(
            "user_message",
            timestamp: "2026-10-27T11:22:01.000Z",
            extra: [
                "turn_id": "resumed-turn",
                "message": "MSA 최신 대화가 보드에 나타나야 합니다"
            ]
        ),
        event(
            "task_complete",
            timestamp: "2026-10-27T11:22:02.000Z",
            extra: ["turn_id": "resumed-turn"]
        )
    ]
    try append(
        appended.reduce(Data()) { $0 + $1 + Data("\n".utf8) },
        to: resolvedFile
    )

    let collector = SessionCollector(
        codexHome: codexHome,
        store: store
    )
    let summary = collector.scanOnceSync()
    check(summary.errors.isEmpty,
          "vscode cursor hydration should scan without errors: \(summary.errors)")
    let card = try store.loadCards().first
    check(card?.id == thread && card?.provider == .openai,
          "vscode codex-tui cursor should resume into an OpenAI card")
    check(card?.state == .responseEnded
            && card?.responseLifecycle == .completed,
          "appended current-turn task_complete should reach completed state")
    check(card?.title == "MSA 최신 대화가 보드에 나타나야 합니다",
          "appended user message should provide the card identity")
    let cursor = try store.cursor(path: resolvedFile.path)
    check(cursor?.context.header?.originator == "codex-tui"
            && cursor?.context.header?.threadSource == "user",
          "legacy cursor header should be rehydrated without offset reset")
    try check(cursor?.offset == (FileManager.default.attributesOfItem(
        atPath: resolvedFile.path
    )[.size] as! NSNumber).int64Value,
          "cursor should advance through the appended completion")
    _ = collector.scanOnceSync()
    try check(try store.loadCards().count == 1,
              "resumed vscode conversation should not duplicate the card")
}

run("collector merges multiple Codex homes without loss or duplicate regression") {
    let directory = try temporaryDirectory()
    let gptHome = directory.appendingPathComponent("gpt home", isDirectory: true)
    let dsHome = directory.appendingPathComponent("ds home", isDirectory: true)
    let gptSessions = gptHome.appendingPathComponent("sessions/2026/11/14", isDirectory: true)
    let dsSessions = dsHome.appendingPathComponent("sessions/2026/11/14", isDirectory: true)
    try FileManager.default.createDirectory(at: gptSessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dsSessions, withIntermediateDirectories: true)

    let gpt = UUID(uuidString: "D1D1D1D1-D1D1-41D1-81D1-D1D1D1D1D1D1")!
    let ds = UUID(uuidString: "D2D2D2D2-D2D2-42D2-82D2-D2D2D2D2D2D2")!
    let gptLines = try [
        sessionMeta(
            id: gpt.uuidString,
            provider: "openai",
            timestamp: "2026-11-14T01:00:00.000Z"
        ),
        event(
            "task_started",
            timestamp: "2026-11-14T01:00:01.000Z",
            extra: ["turn_id": "gpt-turn"]
        ),
        event(
            "user_message",
            timestamp: "2026-11-14T01:00:02.000Z",
            extra: ["turn_id": "gpt-turn", "message": "GPT 다중홈 작업"]
        )
    ]
    let dsLines = try [
        sessionMeta(
            id: ds.uuidString,
            provider: "deepseek",
            timestamp: "2026-11-14T01:01:00.000Z"
        ),
        event(
            "task_started",
            timestamp: "2026-11-14T01:01:01.000Z",
            extra: ["turn_id": "ds-turn"]
        ),
        event(
            "user_message",
            timestamp: "2026-11-14T01:01:02.000Z",
            extra: ["turn_id": "ds-turn", "message": "DeepSeek 다중홈 작업"]
        )
    ]
    try gptLines.reduce(Data()) {
        $0 + $1 + Data("\n".utf8)
    }.write(to: gptSessions.appendingPathComponent("gpt.jsonl"))
    try dsLines.reduce(Data()) {
        $0 + $1 + Data("\n".utf8)
    }.write(to: dsSessions.appendingPathComponent("ds.jsonl"))

    let store = try StateStore(
        path: directory.appendingPathComponent("multi.sqlite3").path
    )
    let collector = SessionCollector(
        codexHomes: [gptHome, dsHome],
        store: store
    )
    let simultaneous = collector.scanOnceSync()
    check(simultaneous.errors.isEmpty,
          "two-home scan should have no missing-directory errors: \(simultaneous.errors)")
    let cards = try store.loadCards()
    check(cards.count == 2,
          "simultaneous GPT and DeepSeek homes should create two cards")
    check(Set(cards.map(\.provider)) == Set([.openai, .deepseek]),
          "multi-home cards should preserve both providers")

    let lateHome = directory.appendingPathComponent("late ds", isDirectory: true)
    let lateStore = try StateStore(
        path: directory.appendingPathComponent("late.sqlite3").path
    )
    let lateCollector = SessionCollector(
        codexHomes: [gptHome, lateHome],
        store: lateStore
    )
    let missing = lateCollector.scanOnceSync()
    check(missing.errors.isEmpty,
          "missing sessions directory should be silent")
    try check(lateStore.loadCards().count == 1,
          "existing home should still scan when another home is absent")
    let lateSessions = lateHome.appendingPathComponent("sessions/2026/11/14", isDirectory: true)
    try FileManager.default.createDirectory(
        at: lateSessions,
        withIntermediateDirectories: true
    )
    try dsLines.reduce(Data()) {
        $0 + $1 + Data("\n".utf8)
    }.write(to: lateSessions.appendingPathComponent("late.jsonl"))
    let appeared = lateCollector.scanOnceSync()
    try check(appeared.errors.isEmpty
            && lateStore.loadCards().contains(where: { $0.id == ds }),
          "sessions directory created later should be discovered on the next scan")

    let symlinkLeafHome = directory.appendingPathComponent(
        "symlink leaf home",
        isDirectory: true
    )
    let symlinkLeafSessions = symlinkLeafHome.appendingPathComponent(
        "sessions",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: symlinkLeafSessions,
        withIntermediateDirectories: true
    )
    let originalFile = gptSessions.appendingPathComponent("gpt.jsonl")
    try FileManager.default.createSymbolicLink(
        at: symlinkLeafSessions.appendingPathComponent("linked.jsonl"),
        withDestinationURL: originalFile
    )

    let symlinkSessionsHome = directory.appendingPathComponent(
        "symlink sessions home",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: symlinkSessionsHome,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: symlinkSessionsHome.appendingPathComponent(
            "sessions",
            isDirectory: true
        ),
        withDestinationURL: gptHome.appendingPathComponent(
            "sessions",
            isDirectory: true
        )
    )

    let symlinkWholeHome = directory.appendingPathComponent(
        "symlink whole home",
        isDirectory: true
    )
    try FileManager.default.createSymbolicLink(
        at: symlinkWholeHome,
        withDestinationURL: gptHome
    )

    let sessionsSymlinkStore = try StateStore(
        path: directory.appendingPathComponent(
            "sessions-symlink.sqlite3"
        ).path
    )
    let sessionsSymlinkSummary = SessionCollector(
        codexHomes: [symlinkSessionsHome],
        store: sessionsSymlinkStore
    ).scanOnceSync()
    check(
        sessionsSymlinkSummary.errors.isEmpty
            && sessionsSymlinkSummary.filesScanned == 1,
        "sessions directory symlink should be accepted and scanned directly: \(sessionsSymlinkSummary)"
    )
    try check(
        sessionsSymlinkStore.loadCards().count == 1,
        "sessions directory symlink should create the physical file's card"
    )

    let homeSymlinkStore = try StateStore(
        path: directory.appendingPathComponent(
            "home-symlink.sqlite3"
        ).path
    )
    let homeSymlinkSummary = SessionCollector(
        codexHomes: [symlinkWholeHome],
        store: homeSymlinkStore
    ).scanOnceSync()
    check(
        homeSymlinkSummary.errors.isEmpty
            && homeSymlinkSummary.filesScanned == 1,
        "a Codex home symlink should resolve to its physical sessions directory"
    )

    let symlinkStore = try StateStore(
        path: directory.appendingPathComponent("symlink.sqlite3").path
    )
    let symlinkSummary = SessionCollector(
        codexHomes: [
            gptHome,
            symlinkLeafHome,
            symlinkSessionsHome,
            symlinkWholeHome
        ],
        store: symlinkStore
    ).scanOnceSync()
    check(symlinkSummary.errors.isEmpty
            && symlinkSummary.filesScanned == 1,
          "real, leaf-symlink, sessions-symlink, and home-symlink inputs should scan the same physical session only once: \(symlinkSummary)")
    try check(symlinkStore.loadCards().count == 1,
          "directory and file symlink duplicates should not create a second card")

    let oldHome = directory.appendingPathComponent("old copy", isDirectory: true)
    let newHome = directory.appendingPathComponent("new copy", isDirectory: true)
    let oldSessions = oldHome.appendingPathComponent("sessions", isDirectory: true)
    let newSessions = newHome.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: oldSessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newSessions, withIntermediateDirectories: true)
    let copied = UUID(uuidString: "D3D3D3D3-D3D3-43D3-83D3-D3D3D3D3D3D3")!
    let oldFile = oldSessions.appendingPathComponent("old.jsonl")
    let newFile = newSessions.appendingPathComponent("new.jsonl")
    try [
        sessionMeta(
            id: copied.uuidString,
            timestamp: "2026-11-14T02:00:00.000Z"
        ),
        event(
            "task_started",
            timestamp: "2026-11-14T02:00:01.000Z",
            extra: ["turn_id": "old-turn"]
        ),
        event(
            "task_complete",
            timestamp: "2026-11-14T02:00:02.000Z",
            extra: ["turn_id": "old-turn"]
        )
    ].reduce(Data()) { $0 + $1 + Data("\n".utf8) }.write(to: oldFile)
    try [
        sessionMeta(
            id: copied.uuidString,
            timestamp: "2026-11-14T03:00:00.000Z"
        ),
        event(
            "task_started",
            timestamp: "2026-11-14T03:00:01.000Z",
            extra: ["turn_id": "new-turn"]
        )
    ].reduce(Data()) { $0 + $1 + Data("\n".utf8) }.write(to: newFile)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(10)],
        ofItemAtPath: newFile.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-10)],
        ofItemAtPath: oldFile.path
    )
    let copyStore = try StateStore(
        path: directory.appendingPathComponent("copies.sqlite3").path
    )
    _ = SessionCollector(
        codexHomes: [oldHome, newHome],
        store: copyStore
    ).scanOnceSync()
    let copiedCards = try copyStore.loadCards()
    check(copiedCards.count == 1 && copiedCards[0].id == copied,
          "same UUID copied into two homes should remain one card")
    check(copiedCards[0].state == .running
            && copiedCards[0].currentTurnId == "new-turn",
          "older completed copy must not regress the newer running card")

    let invalidHome = directory.appendingPathComponent("invalid home", isDirectory: true)
    try FileManager.default.createDirectory(
        at: invalidHome,
        withIntermediateDirectories: true
    )
    try Data("not a directory".utf8).write(
        to: invalidHome.appendingPathComponent("sessions")
    )
    var reportedUpdates: [CollectorUpdate] = []
    let invalidCollector = SessionCollector(
        codexHome: invalidHome,
        store: try StateStore(
            path: directory.appendingPathComponent("invalid.sqlite3").path
        )
    )
    invalidCollector.onUpdate = {
        reportedUpdates.append($0)
    }
    let invalidSummary = invalidCollector.scanOnceSync()
    check(!invalidSummary.errors.isEmpty,
          "existing non-directory sessions path should be reported")
    check(reportedUpdates.contains(where: \.isError),
          "actual session directory read failure should emit an onUpdate error")
}

run("report is accepted only from an associated real helper tool result") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("db.sqlite3").path)
    let thread = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
    let base = try [
        sessionMeta(id: thread.uuidString, timestamp: "2026-11-11T02:00:00.000Z"),
        event("task_started", timestamp: "2026-11-11T02:00:01.000Z", extra: ["turn_id": "turn"]),
        event("user_message", timestamp: "2026-11-11T02:00:02.000Z", extra: ["message": "보고서 연동 테스트"])
    ]
    try ingest(base, store: store)

    let eventId = UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!
    let envelope = try reportEnvelope(
        threadId: thread,
        eventId: eventId,
        timestamp: AgentBoardDate.parse("2026-11-11T02:00:03.000Z")!,
        state: .waiting,
        steps: [ReportStep(id: "a", title: "검토", status: .inProgress)],
        summary: "검토가 필요합니다."
    )
    let marker = try reportMarker(envelope)

    try ingest(
        [try outputLine(callId: "orphan", output: marker, timestamp: "2026-11-11T02:00:03.100Z")],
        store: store
    )
    try check(try store.loadCards().first?.state == .running, "orphan output must not be trusted")

    try ingest(
        [
            try callLine(callId: "cat", command: "cat README.md", timestamp: "2026-11-11T02:00:04.000Z"),
            try outputLine(callId: "cat", output: marker, timestamp: "2026-11-11T02:00:04.100Z")
        ],
        store: store
    )
    try check(try store.loadCards().first?.state == .running, "cat output must not be trusted")

    try ingest(
        [
            try response(
                "message",
                timestamp: "2026-11-11T02:00:05.000Z",
                payload: [
                    "role": "assistant",
                    "content": [["type": "output_text", "text": marker]]
                ]
            )
        ],
        store: store
    )
    try check(try store.loadCards().first?.state == .running, "assistant prose must not complete work")

    try ingest(
        [
            try callLine(
                callId: "real",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-11T02:00:06.000Z",
                custom: true
            ),
            try outputLine(
                callId: "real",
                output: [
                    ["type": "input_text", "text": "Script completed\nOutput:"],
                    [
                        "type": "input_text",
                        "text": ["nested", marker]
                    ] as [String: Any]
                ] as [Any],
                timestamp: "2026-11-11T02:00:06.100Z",
                custom: true
            )
        ],
        store: store
    )
    var card = try store.loadCards().first
    check(card?.state == .running, "waiting report must not override running lifecycle")
    check(card?.reportedState == .waiting, "reported state should retain waiting")
    check(card?.steps.first?.status == .inProgress, "reported steps should survive")

    let wrongThreadEnvelope = try reportEnvelope(
        threadId: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!,
        eventId: UUID(uuidString: "12345678-1234-4234-8234-123456789012")!,
        timestamp: AgentBoardDate.parse("2026-11-11T02:00:07.000Z")!,
        state: .completed,
        title: "잘못된 스레드",
        steps: [],
        summary: "무시되어야 합니다."
    )
    try ingest(
        [
            try callLine(
                callId: "wrong",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-11T02:00:07.000Z"
            ),
            try outputLine(
                callId: "wrong",
                output: try reportMarker(wrongThreadEnvelope),
                timestamp: "2026-11-11T02:00:07.100Z"
            )
        ],
        store: store
    )
    card = try store.loadCards().first
    check(card?.state == .running && card?.reportedState == .waiting,
          "mismatched thread report must be ignored")
}

run("report event deduplication is idempotent") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("db.sqlite3").path)
    let thread = UUID(uuidString: "10101010-1010-4010-8010-101010101010")!
    let eventId = UUID(uuidString: "20202020-2020-4020-8020-202020202020")!
    try ingest(
        try [
            sessionMeta(id: thread.uuidString, timestamp: "2026-11-11T03:00:00.000Z"),
            event("task_started", timestamp: "2026-11-11T03:00:01.000Z", extra: ["turn_id": "turn"])
        ],
        store: store
    )
    let envelope = try reportEnvelope(
        threadId: thread,
        eventId: eventId,
        timestamp: AgentBoardDate.parse("2026-11-11T03:00:02.000Z")!,
        state: .running
    )
    let marker = try reportMarker(envelope)
    for index in 0..<2 {
        try ingest(
            [
                try callLine(
                    callId: "dup-\(index)",
                    command: "/Users/me/.local/bin/agentboard report --json '{}'",
                    timestamp: "2026-11-11T03:00:03.000Z"
                ),
                try outputLine(
                    callId: "dup-\(index)",
                    output: marker,
                    timestamp: "2026-11-11T03:00:03.100Z"
                )
            ],
            store: store
        )
    }
    try check(try store.reportEventCount() == 1, "same eventId must produce one report event")
}

run("new user turn clears old plan and completed status") {
    let thread = UUID(uuidString: "30303030-3030-4030-8030-303030303030")!
    let envelope = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "40404040-4040-4040-8040-404040404040")!,
        timestamp: AgentBoardDate.parse("2026-11-11T04:00:03.100Z")!,
        state: .completed,
        steps: [ReportStep(id: "done", title: "완료 단계", status: .completed)],
        summary: "완료 보고"
    )
    let records = try [
        sessionMeta(id: thread.uuidString, timestamp: "2026-11-11T04:00:00.000Z"),
        event("task_started", timestamp: "2026-11-11T04:00:01.000Z", extra: ["turn_id": "turn-1"]),
        event("user_message", timestamp: "2026-11-11T04:00:02.000Z", extra: ["message": "첫 작업"]),
        callLine(callId: "complete", command: "/Users/me/.local/bin/agentboard report --json '{}'", timestamp: "2026-11-11T04:00:03.000Z"),
        outputLine(callId: "complete", output: try reportMarker(envelope), timestamp: "2026-11-11T04:00:03.100Z"),
        event("task_complete", timestamp: "2026-11-11T04:00:04.000Z", extra: ["turn_id": "turn-1"]),
        event("task_started", timestamp: "2026-11-11T04:01:00.000Z", extra: ["turn_id": "turn-2"]),
        event("user_message", timestamp: "2026-11-11T04:01:01.000Z", extra: ["message": "두 번째 작업"])
    ].compactMap {
        SessionLineParser.parse(
            $0,
            fallbackDate: Date(),
            trustPolicy: testTrustPolicy
        )
    }
    let result = SessionReducer.reduce(
        records: records,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    check(result.card?.state == .running, "new turn should reactivate card")
    check(result.card?.steps.isEmpty == true, "new turn should clear old plan")
    check(result.card?.summary == nil, "new turn should clear old report summary")
    check(result.card?.lastReportAt == nil,
          "current turn without a report should not retain an old lastReport")
    check(result.card?.hasExplicitReport == false, "new turn should clear report proof")
    check(result.card?.title == "검증 작업", "new turn must preserve explicit report task title")
    check(result.card?.currentRequest == "두 번째 작업", "new turn should update current request")
}

run("completed response lifecycle ignores late abort until a new turn") {
    let thread = UUID(uuidString: "50505050-5050-4050-8050-505050505050")!
    let ended = try [
        sessionMeta(id: thread.uuidString, timestamp: "2026-11-11T05:00:00.000Z"),
        event("task_started", timestamp: "2026-11-11T05:00:01.000Z", extra: ["turn_id": "turn"]),
        event("task_complete", timestamp: "2026-11-11T05:00:02.000Z", extra: ["turn_id": "turn"])
    ].compactMap {
        SessionLineParser.parse(
            $0,
            fallbackDate: Date(),
            trustPolicy: testTrustPolicy
        )
    }
    let endedResult = SessionReducer.reduce(
        records: ended,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    check(endedResult.card?.state == .responseEnded, "task_complete should mean response ended")
    check(endedResult.card?.hasExplicitReport == false, "task_complete must not claim report completion")

    let aborted = try event(
        "turn_aborted",
        timestamp: "2026-11-11T05:00:03.000Z",
        extra: ["reason": "interrupted"]
    )
    let abortRecord = SessionLineParser.parse(aborted, fallbackDate: Date())!
    let interrupted = SessionReducer.reduce(
        records: [abortRecord],
        card: endedResult.card,
        cursor: endedResult.cursor,
        seenEventIds: []
    )
    check(interrupted.card?.state == .responseEnded,
          "late abort after task_complete must keep the response completed")
    check(interrupted.card?.responseLifecycle == .completed,
          "late abort after task_complete must not change response lifecycle")

    let nextTurn = [
        ParsedRecord(
            timestamp: AgentBoardDate.parse("2026-11-11T05:01:00.000Z")!,
            signal: .taskStarted(turnId: "next-turn")
        ),
        ParsedRecord(
            timestamp: AgentBoardDate.parse("2026-11-11T05:01:01.000Z")!,
            signal: .turnAborted(reason: "interrupted", turnId: "next-turn")
        )
    ]
    let abortedNextTurn = SessionReducer.reduce(
        records: nextTurn,
        card: interrupted.card,
        cursor: interrupted.cursor,
        seenEventIds: []
    )
    check(abortedNextTurn.card?.state == .interrupted,
          "abort in a genuine new turn must stay distinguishable")
    check(abortedNextTurn.card?.responseLifecycle == .interrupted,
          "new-turn abort must own the interrupted lifecycle")

    let errorEnvelope = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "60606060-6060-4060-8060-606060606060")!,
        timestamp: Date(),
        state: .error,
        summary: "도구 실행 실패"
    )
    var errorCard = abortedNextTurn.card!
    SessionReducer.applyReport(errorEnvelope, to: &errorCard)
    check(errorCard.state == .interrupted,
          "report error must not replace actual interrupted lifecycle")
    check(errorCard.reportedState == .error,
          "explicit report error should remain in reported state")
}

run("response lifecycle owns board state and report outcome is separate") {
    let thread = UUID(uuidString: "AFAFAFAF-AFAF-4FAF-8FAF-AFAFAFAFAFAF")!
    let errorReport = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "BFBFBFBF-BFBF-4FBF-8FBF-BFBFBFBFBFBF")!,
        timestamp: AgentBoardDate.parse("2026-11-13T11:00:02.000Z")!,
        state: .error,
        steps: [
            ReportStep(id: "warn", title: "경고 단계", status: .inProgress)
        ],
        summary: "작업 결과 경고"
    )
    let lines = try [
        sessionMeta(
            id: thread.uuidString,
            timestamp: "2026-11-13T11:00:00.000Z"
        ),
        event(
            "task_started",
            timestamp: "2026-11-13T11:00:01.000Z",
            extra: ["turn_id": "current"]
        ),
        callLine(
            callId: "error-report",
            command: "/Users/me/.local/bin/agentboard report --json '{}'",
            timestamp: "2026-11-13T11:00:01.500Z"
        ),
        outputLine(
            callId: "error-report",
            output: try reportMarker(errorReport),
            timestamp: "2026-11-13T11:00:02.000Z"
        )
    ]
    let active = lines.compactMap {
        SessionLineParser.parse($0, trustPolicy: testTrustPolicy)
    }
    var result = SessionReducer.reduce(
        records: active,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    check(result.card?.state == .running,
          "report error must not end an active response")
    check(result.card?.reportedState == .error,
          "report error should remain available as outcome metadata")
    check(result.card?.summary == "작업 결과 경고",
          "report warning summary should be preserved")
    check(result.card?.steps.first?.id == "warn",
          "report warning steps should be preserved")

    let wrongTurnComplete = SessionLineParser.parse(
        try event(
            "task_complete",
            timestamp: "2026-11-13T11:00:03.000Z",
            extra: ["turn_id": "other"]
        ),
        trustPolicy: testTrustPolicy
    )!
    result = SessionReducer.reduce(
        records: [wrongTurnComplete],
        card: result.card,
        cursor: result.cursor,
        seenEventIds: []
    )
    check(result.card?.state == .running,
          "other-turn task_complete must not finish current response")

    let currentComplete = SessionLineParser.parse(
        try event(
            "task_complete",
            timestamp: "2026-11-13T11:00:04.000Z",
            extra: ["turn_id": "current"]
        ),
        trustPolicy: testTrustPolicy
    )!
    result = SessionReducer.reduce(
        records: [currentComplete],
        card: result.card,
        cursor: result.cursor,
        seenEventIds: []
    )
    check(result.card?.state == .responseEnded,
          "current-turn normal completion should finish board response")
    check(result.card?.reportedState == .error,
          "normal response completion must retain report error outcome")
    check(result.card?.summary == "작업 결과 경고",
          "normal response completion must retain report summary")

    let lateAbort = SessionLineParser.parse(
        try event(
            "turn_aborted",
            timestamp: "2026-11-13T11:00:05.000Z",
            extra: ["turn_id": "current", "reason": "interrupted"]
        ),
        trustPolicy: testTrustPolicy
    )!
    result = SessionReducer.reduce(
        records: [lateAbort],
        card: result.card,
        cursor: result.cursor,
        seenEventIds: []
    )
    check(result.card?.state == .responseEnded,
          "late same-turn abort must not overwrite completed response")
    check(result.card?.reportedState == .error,
          "late abort must not erase report outcome")

    let nextTurn = SessionLineParser.parse(
        try event(
            "task_started",
            timestamp: "2026-11-13T11:01:00.000Z",
            extra: ["turn_id": "next"]
        ),
        trustPolicy: testTrustPolicy
    )!
    let nextAbort = SessionLineParser.parse(
        try event(
            "turn_aborted",
            timestamp: "2026-11-13T11:01:01.000Z",
            extra: ["turn_id": "next", "reason": "interrupted"]
        ),
        trustPolicy: testTrustPolicy
    )!
    result = SessionReducer.reduce(
        records: [nextTurn, nextAbort],
        card: result.card,
        cursor: result.cursor,
        seenEventIds: []
    )
    check(result.card?.state == .interrupted,
          "abort in a new genuine turn should interrupt response")
}

run("missing plan, stale running, and ordering are conservative") {
    let now = Date()
    let stale = AgentCard(
        id: UUID(),
        provider: .openai,
        title: "응답 없는 작업",
        cwd: "/tmp/stale",
        state: .running,
        lastEventAt: now.addingTimeInterval(-91)
    )
    check(stale.steps.isEmpty, "plan may be absent")
    check(stale.currentStep == nil, "missing plan has no current step")
    check(stale.isStaleRunning(now: now), "running older than 90 seconds is stale")
    check(stale.displayState(now: now) == "현재 상태 확인 필요", "stale state needs Korean warning")
    check(stale.state == .running, "stale running must not be assumed complete or error")

    let waiting = AgentCard(
        id: UUID(),
        provider: .deepseek,
        title: "대기",
        cwd: nil,
        state: .waiting,
        lastEventAt: now
    )
    let running = AgentCard(
        id: UUID(),
        provider: .openai,
        title: "진행",
        cwd: nil,
        state: .running,
        lastEventAt: now.addingTimeInterval(1)
    )
    let completed = AgentCard(
        id: UUID(),
        provider: .openai,
        title: "완료",
        cwd: nil,
        state: .completed,
        lastEventAt: now.addingTimeInterval(2)
    )
    let ordered = SessionReducer.ordered([completed, running, waiting, stale], now: now)
    check(ordered[0].id == waiting.id, "needs-attention group should be newest first")
    check(ordered[1].id == stale.id, "stale running belongs in needs-attention group")
    check(ordered.last?.id == completed.id, "completed sorts last")
}

run("SQLite cursor and card state commit together and survive replay") {
    let directory = try temporaryDirectory()
    let path = directory.appendingPathComponent("db.sqlite3").path
    let thread = UUID(uuidString: "70707070-7070-4070-8070-707070707070")!
    let cursorPath = "/tmp/codex-session.jsonl"
    do {
        let store = try StateStore(path: path)
        try ingest(
            try [
                sessionMeta(id: thread.uuidString, timestamp: "2026-11-11T06:00:00.000Z"),
                event("task_started", timestamp: "2026-11-11T06:00:01.000Z", extra: ["turn_id": "turn"]),
                event("user_message", timestamp: "2026-11-11T06:00:02.000Z", extra: ["message": "영속성"])
            ],
            store: store,
            path: cursorPath,
            inode: 77
        )
        let cursor = try store.cursor(path: cursorPath)
        check(cursor?.inode == 77, "inode should persist")
        check(cursor?.context.header?.id == thread, "header should persist with cursor")
        try check(try store.loadCards().count == 1, "card should persist with cursor")
    }
    let reopened = try StateStore(path: path)
    let cursor = try reopened.cursor(path: cursorPath)
    check(cursor?.offset ?? 0 > 0, "restart should preserve offset")
    try check(try reopened.loadCards().count == 1, "restart should not duplicate cards")
}

run("completed reports expire after 30 days while unfinished states remain") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("db.sqlite3").path)
    let now = Date()
    let oldCompletedThread = UUID(uuidString: "80808080-8080-4080-8080-808080808080")!
    let oldRunningThread = UUID(uuidString: "90909090-9090-4090-8090-909090909090")!
    let oldDate = now.addingTimeInterval(-31 * 24 * 60 * 60)
    try ingest(
        try [
            sessionMeta(
                id: oldCompletedThread.uuidString,
                timestamp: AgentBoardDate.string(oldDate)
            ),
            event(
                "task_started",
                timestamp: AgentBoardDate.string(oldDate),
                extra: ["turn_id": "old-complete"]
            ),
            callLine(
                callId: "old-complete",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: AgentBoardDate.string(oldDate)
            ),
            outputLine(
                callId: "old-complete",
                output: try reportMarker(
                    reportEnvelope(
                        threadId: oldCompletedThread,
                        eventId: UUID(uuidString: "81818181-8181-4181-8181-818181818181")!,
                        timestamp: oldDate,
                        state: .completed,
                        steps: [],
                        summary: "오래된 완료"
                    )
                ),
                timestamp: AgentBoardDate.string(oldDate)
            ),
            event(
                "task_complete",
                timestamp: AgentBoardDate.string(oldDate),
                extra: ["turn_id": "old-complete"]
            )
        ],
        store: store,
        path: "/tmp/old-complete.jsonl",
        inode: 80,
        now: now
    )
    try ingest(
        try [
            sessionMeta(
                id: oldRunningThread.uuidString,
                timestamp: AgentBoardDate.string(oldDate)
            ),
            event(
                "task_started",
                timestamp: AgentBoardDate.string(oldDate),
                extra: ["turn_id": "old-running"]
            )
        ],
        store: store,
        path: "/tmp/old-running.jsonl",
        inode: 90,
        now: now
    )
    let removed = try store.pruneCompleted(
        olderThan: now.addingTimeInterval(-30 * 24 * 60 * 60)
    )
    check(removed == 1, "only old completed report should expire")
    let cards = try store.loadCards(includeArchived: true)
    check(cards.count == 1, "unfinished card must remain")
    check(cards.first?.id == oldRunningThread, "unfinished state must be retained")
}

run("responseEnded board completion follows completed retention") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("ended.sqlite3").path)
    let now = Date()
    let old = now.addingTimeInterval(-40 * 24 * 60 * 60)
    let thread = UUID(uuidString: "D1D1D1D1-D1D1-41D1-81D1-D1D1D1D1D1D1")!
    try ingest(
        try [
            sessionMeta(
                id: thread.uuidString,
                timestamp: AgentBoardDate.string(old)
            ),
            event(
                "task_started",
                timestamp: AgentBoardDate.string(old),
                extra: ["turn_id": "ended"]
            ),
            event(
                "task_complete",
                timestamp: AgentBoardDate.string(old),
                extra: ["turn_id": "ended"]
            )
        ],
        store: store,
        path: "/tmp/ended.jsonl",
        now: now
    )
    _ = try store.pruneCompleted(
        olderThan: now.addingTimeInterval(-30 * 24 * 60 * 60)
    )
    let card = try store.loadCards(includeArchived: true).first
    check(card == nil,
          "responseEnded should follow completed-history pruning")
}

run("same-inode truncation switches session header without duplicating a card") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("db.sqlite3").path)
    let first = UUID(uuidString: "D0D0D0D0-D0D0-40D0-80D0-D0D0D0D0D0D0")!
    let second = UUID(uuidString: "E0E0E0E0-E0E0-40E0-80E0-E0E0E0E0E0E0")!
    let path = "/tmp/same-inode.jsonl"
    try ingest(
        try [
            sessionMeta(id: first.uuidString, timestamp: "2026-11-11T09:10:00.000Z"),
            event("task_started", timestamp: "2026-11-11T09:10:01.000Z", extra: ["turn_id": "one"])
        ],
        store: store,
        path: path,
        inode: 500
    )
    try ingest(
        try [
            sessionMeta(
                id: second.uuidString,
                provider: "deepseek",
                timestamp: "2026-11-11T09:20:00.000Z"
            ),
            event("task_started", timestamp: "2026-11-11T09:20:01.000Z", extra: ["turn_id": "two"])
        ],
        store: store,
        path: path,
        inode: 500
    )
    let cards = try store.loadCards(includeArchived: true)
    check(cards.count == 2, "same-inode replacement should create a separate session card")
    try check(
        try store.cursor(path: path)?.context.header?.id == second,
        "cursor should adopt new header"
    )
}

run("partial and malformed JSONL lines do not block later records") {
    let directory = try temporaryDirectory()
    let path = directory.appendingPathComponent("session.jsonl").path
    let first = "{not-json}\n"
    let secondPrefix = "{\"timestamp\":\"2026-11-11T07:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\""
    try Data((first + secondPrefix).utf8).write(to: URL(fileURLWithPath: path))
    let partial = try IncrementalLineReader.readCompleteLines(path: path, from: 0)
    check(partial.lines.count == 1, "complete malformed line should be returned")
    check(partial.lines.first.flatMap { String(data: $0, encoding: .utf8) } == "{not-json}", "malformed line should be bounded")

    let suffix = #"A0A0A0A0-A0A0-40A0-80A0-A0A0A0A0A0A0","source":"cli","cwd":"/tmp/p","model_provider":"openai"}}"# + "\n"
    try append(Data(suffix.utf8), to: URL(fileURLWithPath: path))
    let complete = try IncrementalLineReader.readCompleteLines(
        path: path,
        from: partial.nextOffset
    )
    check(complete.lines.count == 1, "partial line should be parsed after newline arrives")
    check(
        SessionLineParser.parse(complete.lines[0])?.signal
            == .sessionMeta(
                SessionHeader(
                    id: UUID(uuidString: "A0A0A0A0-A0A0-40A0-80A0-A0A0A0A0A0A0")!,
                    source: "cli",
                    cwd: "/tmp/p",
                    modelProvider: "openai",
                    cliVersion: nil,
                    historyMode: nil
                )
            ),
        "received JSONL should parse"
    )

    let oversizedPath = directory.appendingPathComponent("oversized.jsonl").path
    try Data("123456789012345678901\n{\"ok\":true}\n".utf8).write(
        to: URL(fileURLWithPath: oversizedPath)
    )
    let bounded = try IncrementalLineReader.readCompleteLines(
        path: oversizedPath,
        from: 0,
        maximumLineBytes: 18
    )
    check(bounded.lines.count == 1, "oversized line should be skipped")
    check(
        bounded.lines.first == Data("{\"ok\":true}".utf8),
        "reader should continue after oversized line"
    )
}

run("collector restarts, appends, and truncation replacement stay consistent") {
    let directory = try temporaryDirectory()
    let codexHome = directory.appendingPathComponent("fixture-codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/11/11", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("rollout-test.jsonl")
    let thread = UUID(uuidString: "B0B0B0B0-B0B0-40B0-80B0-B0B0B0B0B0B0")!
    let firstLines = try [
        sessionMeta(id: thread.uuidString, timestamp: "2026-11-11T08:00:00.000Z"),
        event("task_started", timestamp: "2026-11-11T08:00:01.000Z", extra: ["turn_id": "turn"])
    ]
    try append(firstLines.reduce(Data()) { $0 + $1 + Data("\n".utf8) }, to: file)

    let dbPath = directory.appendingPathComponent("db.sqlite3").path
    do {
        let store = try StateStore(path: dbPath)
        let collector = SessionCollector(codexHome: codexHome, store: store)
        let first = collector.scanOnceSync()
        check(first.errors.isEmpty, "first scan should succeed")
        try check(try store.loadCards().count == 1, "first scan should create one card")

        let second = collector.scanOnceSync()
        check(second.recordsIngested == 0, "reconciliation should not reread consumed lines")
    }

    let newLine = try event(
        "user_message",
        timestamp: "2026-11-11T08:00:02.000Z",
        extra: ["message": "추가 기록"]
    )
    try append(newLine + Data("\n".utf8), to: file)
    do {
        let restartedStore = try StateStore(path: dbPath)
        let collector = SessionCollector(codexHome: codexHome, store: restartedStore)
        let appended = collector.scanOnceSync()
        check(appended.recordsIngested == 1, "restart should read only appended line")
        try check(try restartedStore.loadCards().first?.title == "추가 기록", "appended event should update card")
    }

    let replacementId = UUID(uuidString: "C0C0C0C0-C0C0-40C0-80C0-C0C0C0C0C0C0")!
    let replacement = try [
        sessionMeta(
            id: replacementId.uuidString,
            provider: "deepseek",
            timestamp: "2026-11-11T09:00:00.000Z"
        ),
        event("task_started", timestamp: "2026-11-11T09:00:01.000Z", extra: ["turn_id": "new"])
    ]
    try FileManager.default.removeItem(at: file)
    try append(replacement.reduce(Data()) { $0 + $1 + Data("\n".utf8) }, to: file)
    let replacedStore = try StateStore(path: dbPath)
    let collector = SessionCollector(codexHome: codexHome, store: replacedStore)
    let replaced = collector.scanOnceSync()
    check(replaced.recordsIngested == 2, "replacement should replay from zero")
    let cards = try replacedStore.loadCards(includeArchived: true)
    check(cards.contains(where: { $0.id == replacementId }), "replacement session should get a new card")
    check(cards.contains(where: { $0.id == thread }), "old retained card should not be overwritten")
}

run("collector resets persisted discard state when file identity changes") {
    let directory = try temporaryDirectory()
    let codexHome = directory.appendingPathComponent("discard-codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/11/12", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.resolvingSymlinksInPath()
        .appendingPathComponent("rollout-new.jsonl")
    let thread = UUID(uuidString: "A1A1A1A1-A1A1-41A1-81A1-A1A1A1A1A1A1")!
    let lines = try [
        sessionMeta(id: thread.uuidString, timestamp: "2026-11-12T06:00:00.000Z"),
        event(
            "task_started",
            timestamp: "2026-11-12T06:00:01.000Z",
            extra: ["turn_id": "new-file"]
        )
    ]
    try append(lines.reduce(Data()) { $0 + $1 + Data("\n".utf8) }, to: file)
    let store = try StateStore(path: directory.appendingPathComponent("discard.sqlite3").path)
    try store.ingest(
        records: [],
        path: file.path,
        inode: 1,
        endOffset: 10,
        discardUntilNewline: true
    )
    let collector = SessionCollector(
        codexHome: codexHome.resolvingSymlinksInPath(),
        store: store
    )
    let summary = collector.scanOnceSync()
    check(summary.errors.isEmpty, "new inode should scan without stale discard errors")
    try check(
        try store.loadCards().first?.id == thread,
        "new inode must ignore previous discard state and parse session_meta"
    )
    let databasePath = directory.appendingPathComponent("discard.sqlite3").path
    let discardStates = try cursorDiscardStates(path: databasePath)
    check(
        discardStates.contains(false),
        "new inode cursor should leave discard mode"
    )
}

run("fresh database creates all schema objects before ingest") {
    let directory = try temporaryDirectory()
    let path = directory.appendingPathComponent("schema.sqlite3").path
    do {
        let store = try StateStore(path: path)
        try check(try store.cursor(path: "/missing.jsonl") == nil, "fresh cursor query should work")
        let thread = UUID(uuidString: "F0F0F0F0-F0F0-40F0-80F0-F0F0F0F0F0F0")!
        try ingest(
            try [
                sessionMeta(id: thread.uuidString, timestamp: "2026-11-12T01:00:00.000Z"),
                event(
                    "task_started",
                    timestamp: "2026-11-12T01:00:01.000Z",
                    extra: ["turn_id": "schema"]
                )
            ],
            store: store,
            path: "/tmp/schema-session.jsonl",
            inode: 1
        )
        try check(try store.loadCards().count == 1, "fresh schema should accept ingest")
    }
    let names = try schemaObjects(path: path)
    for required in [
        "cards",
        "cursors",
        "report_events",
        "card_preferences",
        "identity_backfill",
        "identity_repair",
        "response_state_repair",
        "response_state_scan",
        "app_metadata",
        "cards_state_activity",
        "cards_completed",
        "report_events_thread"
    ] {
        check(names.contains(required), "schema must contain \(required)")
    }
}

run("completed replay is idempotent across inode changes and preserved archives") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("replay.sqlite3").path)
    let thread = UUID(uuidString: "0A0A0A0A-0A0A-40A0-80A0-0A0A0A0A0A0A")!
    let eventId = UUID(uuidString: "0B0B0B0B-0B0B-40B0-80B0-0B0B0B0B0B0B")!
    let timestamp = AgentBoardDate.parse("2026-11-12T02:00:05.000Z")!
    let completed = try reportEnvelope(
        threadId: thread,
        eventId: eventId,
        timestamp: timestamp,
        state: .completed,
        steps: [ReportStep(id: "done", title: "완료", status: .completed)],
        summary: "완료된 작업"
    )
    let records = try [
        sessionMeta(id: thread.uuidString, timestamp: "2026-11-12T02:00:00.000Z"),
        event("task_started", timestamp: "2026-11-12T02:00:01.000Z", extra: ["turn_id": "old"]),
        event("user_message", timestamp: "2026-11-12T02:00:02.000Z", extra: ["message": "완료 대상"]),
        callLine(
            callId: "complete",
            command: "/Users/me/.local/bin/agentboard report --json '{}'",
            timestamp: "2026-11-12T02:00:03.000Z"
        ),
        outputLine(
            callId: "complete",
            output: try reportMarker(completed),
            timestamp: "2026-11-12T02:00:05.000Z"
        ),
        event("task_complete", timestamp: "2026-11-12T02:00:06.000Z", extra: ["turn_id": "old"])
    ].compactMap {
        SessionLineParser.parse(
            $0,
            fallbackDate: timestamp,
            trustPolicy: testTrustPolicy
        )
    }
    let path = "/tmp/replay-session.jsonl"
    try ingestRecords(records, store: store, path: path, inode: 10)
    try check(try store.loadCards().first?.state == .responseEnded,
              "initial lifecycle completion should use responseEnded")
    try store.setArchived(cardId: thread, archived: true)

    try ingestRecords(records, store: store, path: path, inode: 10)
    try check(
        try store.loadCards(includeArchived: true).first?.state == .responseEnded,
        "same-inode replay should remain completed"
    )

    try ingestRecords(records, store: store, path: path, inode: 11)
    var card = try store.loadCards(includeArchived: true).first
    check(card?.state == .responseEnded, "new-inode replay should remain completed")
    check(card?.archived == true, "archive preference must survive inode change")
    try check(try store.reportEventCount() == 1, "replayed event should not duplicate report log")

    try ingestRecords(records, store: store, path: "/tmp/renamed-copy.jsonl", inode: 12)
    card = try store.loadCards(includeArchived: true).first
    check(card?.state == .responseEnded, "renamed duplicate should not regress card")
    check(card?.archived == true, "renamed duplicate must preserve hidden preference")

    let newerWaiting = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "0C0C0C0C-0C0C-40C0-80C0-0C0C0C0C0C0C")!,
        timestamp: AgentBoardDate.parse("2026-11-12T03:00:05.000Z")!,
        state: .waiting,
        summary: "새 작업 대기"
    )
    try ingestRecords(
        try [
            event(
                "task_started",
                timestamp: "2026-11-12T03:00:01.000Z",
                extra: ["turn_id": "newer"]
            ),
            callLine(
                callId: "newer",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-12T03:00:03.000Z"
            ),
            outputLine(
                callId: "newer",
                output: try reportMarker(newerWaiting),
                timestamp: "2026-11-12T03:00:05.000Z"
            )
        ].compactMap {
            SessionLineParser.parse(
                $0,
                fallbackDate: timestamp,
                trustPolicy: testTrustPolicy
            )
        },
        store: store,
        path: path,
        inode: 11
    )
    try ingestRecords(records, store: store, path: "/tmp/older-rotation.jsonl", inode: 14)
    card = try store.loadCards(includeArchived: true).first
    check(card?.state == .running, "older rotated file must not regress newer lifecycle")
    check(card?.reportedState == .waiting, "newer report state should survive old replay")
    check(card?.summary == "새 작업 대기", "newer report summary must survive old replay")
}

run("pruned completed card reactivates from retained header") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("prune.sqlite3").path)
    let thread = UUID(uuidString: "1A1A1A1A-1A1A-41A1-81A1-1A1A1A1A1A1A")!
    let now = Date()
    let old = now.addingTimeInterval(-35 * 24 * 60 * 60)
    let path = "/tmp/pruned.jsonl"
    try ingest(
        try [
            sessionMeta(id: thread.uuidString, timestamp: AgentBoardDate.string(old)),
            event(
                "task_started",
                timestamp: AgentBoardDate.string(old),
                extra: ["turn_id": "old"]
            ),
            callLine(
                callId: "old",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: AgentBoardDate.string(old)
            ),
            outputLine(
                callId: "old",
                output: try reportMarker(
                    reportEnvelope(
                        threadId: thread,
                        eventId: UUID(uuidString: "1B1B1B1B-1B1B-41B1-81B1-1B1B1B1B1B1B")!,
                        timestamp: old,
                        state: .completed,
                        summary: "오래된 완료"
                    )
                ),
                timestamp: AgentBoardDate.string(old)
            ),
            event(
                "task_complete",
                timestamp: AgentBoardDate.string(old),
                extra: ["turn_id": "old"]
            )
        ],
        store: store,
        path: path,
        inode: 20,
        now: now
    )
    try store.pruneCompleted(olderThan: now.addingTimeInterval(-30 * 24 * 60 * 60))
    try check(try store.loadCards(includeArchived: true).isEmpty, "completed card should prune")
    let fresh = now.addingTimeInterval(10)
    try ingest(
        try [
            event(
                "task_started",
                timestamp: AgentBoardDate.string(fresh),
                extra: ["turn_id": "fresh"]
            ),
            event(
                "user_message",
                timestamp: AgentBoardDate.string(fresh.addingTimeInterval(1)),
                extra: ["message": "다시 시작한 작업"]
            )
        ],
        store: store,
        path: path,
        inode: 20,
        now: fresh
    )
    let restored = try store.loadCards(includeArchived: true)
    check(restored.count == 1, "new activity should recreate same UUID card")
    check(restored.first?.id == thread, "recreated card should use retained header UUID")
    check(restored.first?.state == .running, "recreated card should reactivate")
    check(restored.first?.title == "다시 시작한 작업", "new user turn title should apply")
}

run("historical pending reports survive split batches and cannot cross turns") {
    let thread = UUID(uuidString: "2A2A2A2A-2A2A-42A2-82A2-2A2A2A2A2A2A")!
    let old = Date().addingTimeInterval(-3 * 24 * 60 * 60)
    let header = SessionHeader(
        id: thread,
        source: "cli",
        cwd: "/tmp/pending",
        modelProvider: "openai",
        cliVersion: "0.167.1",
        historyMode: "paginated"
    )
    let completed = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "2B2B2B2B-2B2B-42B2-82B2-2B2B2B2B2B2B")!,
        timestamp: old.addingTimeInterval(2),
        state: .completed,
        summary: "히스토리 완료"
    )
    let first = SessionReducer.reduce(
        records: [
            ParsedRecord(timestamp: old, signal: .sessionMeta(header)),
            ParsedRecord(timestamp: old, signal: .taskStarted(turnId: "old")),
            ParsedRecord(
                timestamp: old.addingTimeInterval(1),
                signal: .toolCall(
                    callId: "historical",
                    eligibleForReport: true,
                    toolName: "exec"
                )
            )
        ],
        card: nil,
        cursor: CursorContext(),
        seenEventIds: [],
        now: Date()
    )
    let second = SessionReducer.reduce(
        records: [
            ParsedRecord(
                timestamp: old.addingTimeInterval(2),
                signal: .toolOutput(
                    callId: "historical",
                    text: try reportMarker(completed)
                )
            )
        ],
        card: first.card,
        cursor: first.cursor,
        seenEventIds: [],
        now: Date()
    )
    check(second.card?.state == .running,
          "historical split report must not infer response completion")
    check(second.card?.reportedState == .completed,
          "historical split report should retain reported state")

    let fresh = Date()
    let pending = SessionReducer.reduce(
        records: [
            ParsedRecord(timestamp: fresh, signal: .sessionMeta(header)),
            ParsedRecord(timestamp: fresh, signal: .taskStarted(turnId: "old-turn")),
            ParsedRecord(
                timestamp: fresh.addingTimeInterval(1),
                signal: .toolCall(
                    callId: "late",
                    eligibleForReport: true,
                    toolName: "exec"
                )
            )
        ],
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    let afterNewTurn = SessionReducer.reduce(
        records: [
            ParsedRecord(
                timestamp: fresh.addingTimeInterval(2),
                signal: .taskStarted(turnId: "new-turn")
            ),
            ParsedRecord(
                timestamp: fresh.addingTimeInterval(3),
                signal: .toolOutput(
                    callId: "late",
                    text: try reportMarker(completed)
                )
            )
        ],
        card: pending.card,
        cursor: pending.cursor,
        seenEventIds: []
    )
    check(afterNewTurn.card?.state == .running, "old-turn output must not complete new turn")
    check(afterNewTurn.card?.summary == nil, "old-turn report summary must be ignored")
}

run("tool output decoding preserves escaped reports and rejects echoes") {
    let thread = UUID(uuidString: "3A3A3A3A-3A3A-43A3-83A3-3A3A3A3A3A3A")!
    let summary = "quote \"word\", slash \\\\, newline\nsecond line"
    let envelope = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "3B3B3B3B-3B3B-43B3-83B3-3B3B3B3B3B3B")!,
        timestamp: Date(),
        state: .waiting,
        summary: summary
    )
    let marker = try reportMarker(envelope)
    let direct = SessionLineParser.extractReports(fromToolOutput: marker)
    check(direct.first?.payload.summary == summary, "direct report should parse")

    let layer1 = try String(
        data: jsonData(["output": marker]),
        encoding: .utf8
    )!
    let layer2 = try String(
        data: jsonData(["result": layer1]),
        encoding: .utf8
    )!
    let nested: [String: Any] = [
        "content": [
            ["type": "text", "text": layer2] as [String: Any]
        ]
    ]
    let flattened = SessionLineParser.flattenToolOutput(nested)
    let serialized = SessionLineParser.extractReports(fromToolOutput: flattened)
    check(serialized.count == 1, "deeply serialized JSON output should decode")
    check(serialized.first?.payload.summary == summary, "escaped summary must survive recursively")

    let echo: [String: Any] = [
        "command": marker,
        "output": ""
    ]
    let echoText = SessionLineParser.flattenToolOutput(echo)
    check(
        SessionLineParser.extractReports(fromToolOutput: echoText).isEmpty,
        "marker in command metadata must not parse"
    )

    let prefixed = "printf '\(marker)'\n"
    check(
        SessionLineParser.extractReports(fromToolOutput: prefixed).isEmpty,
        "quoted marker not at a genuine output line must not parse"
    )
}

run("unrelated tools and asynchronous waits are rejected") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("trust.sqlite3").path)
    let thread = UUID(uuidString: "4A4A4A4A-4A4A-44A4-84A4-4A4A4A4A4A4A")!
    try ingest(
        try [
            sessionMeta(id: thread.uuidString, timestamp: "2026-11-12T04:00:00.000Z"),
            event(
                "task_started",
                timestamp: "2026-11-12T04:00:01.000Z",
                extra: ["turn_id": "trust"]
            )
        ],
        store: store
    )
    let envelope = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "4B4B4B4B-4B4B-44B4-84B4-4B4B4B4B4B4B")!,
        timestamp: AgentBoardDate.parse("2026-11-12T04:00:03.000Z")!,
        state: .completed,
        summary: "허용되면 안 됨"
    )
    let marker = try reportMarker(envelope)

    try ingest(
        [
            try callLine(
                callId: "unrelated",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-12T04:00:02.000Z",
                toolName: "read_file"
            ),
            try outputLine(
                callId: "unrelated",
                output: marker,
                timestamp: "2026-11-12T04:00:03.000Z"
            )
        ],
        store: store
    )
    try check(try store.loadCards().first?.state == .running, "unrelated tool must not report")

    try ingest(
        [
            try callLine(
                callId: "exec-ok",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-12T04:00:04.000Z"
            ),
            try outputLine(
                callId: "exec-ok",
                output: "Script started asynchronously",
                timestamp: "2026-11-12T04:00:04.100Z"
            ),
            try callLine(
                callId: "wait-ok",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-12T04:00:05.000Z",
                toolName: "functions.wait"
            ),
            try outputLine(
                callId: "wait-ok",
                output: marker,
                timestamp: "2026-11-12T04:00:06.000Z"
            )
        ],
        store: store
    )
    try check(try store.loadCards().first?.state == .running, "async wait output must be rejected")
}

run("oversized discard state spans read limits without parsing tail") {
    let directory = try temporaryDirectory()
    let path = directory.appendingPathComponent("oversized-span.jsonl").path
    try Data(String(repeating: "X", count: 100).utf8).write(
        to: URL(fileURLWithPath: path)
    )
    let first = try IncrementalLineReader.readCompleteLines(
        path: path,
        from: 0,
        maximumBytes: 20,
        maximumLineBytes: 8
    )
    check(first.lines.isEmpty, "oversized prefix must not emit a line")
    check(first.discardUntilNewline, "reader should persist discard state")
    let tail = #"{"type":"session_meta","payload":{}}"# + "\n"
    try append(Data(tail.utf8), to: URL(fileURLWithPath: path))
    let second = try IncrementalLineReader.readCompleteLines(
        path: path,
        from: first.nextOffset,
        discardUntilNewline: first.discardUntilNewline,
        maximumBytes: 4_096,
        maximumLineBytes: 8
    )
    check(second.lines.isEmpty, "valid-looking tail of oversized line must be discarded")
    check(!second.discardUntilNewline, "newline should end discard mode")
    try append(Data(#"{"ok":true}"# .utf8 + Data("\n".utf8)), to: URL(fileURLWithPath: path))
    let third = try IncrementalLineReader.readCompleteLines(
        path: path,
        from: second.nextOffset,
        discardUntilNewline: second.discardUntilNewline,
        maximumBytes: 4_096,
        maximumLineBytes: 64
    )
    check(third.lines == [Data(#"{"ok":true}"#.utf8)], "reader should resume after discarded line")
}

run("envelope version and full snapshot fields are exact") {
    let thread = UUID(uuidString: "5A5A5A5A-5A5A-45A5-85A5-5A5A5A5A5A5A")!
    let payload: [String: Any] = [
        "title": "검증",
        "state": "running",
        "steps": [] as [Any],
        "summary": "진행"
    ]
    func envelope(version: Any) throws -> Data {
        try jsonData([
            "version": version,
            "eventId": "5B5B5B5B-5B5B-45B5-85B5-5B5B5B5B5B5B",
            "threadId": thread.uuidString,
            "timestamp": "2026-11-12T05:00:00.000Z",
            "payload": payload
        ] as [String: Any])
    }
    try check(
        try ReportValidator.decodeEnvelope(try envelope(version: 1)).version == 1,
        "integer version one should pass"
    )
    checkThrows(
        { try ReportValidator.decodeEnvelope(try envelope(version: true)) },
        "boolean version must fail"
    )
    checkThrows(
        { try ReportValidator.decodeEnvelope(try envelope(version: 1.5)) },
        "fractional version must fail"
    )
    let missingSummary: [String: Any] = [
        "title": "검증",
        "state": "running",
        "steps": [] as [Any]
    ]
    checkThrows(
        { try ReportValidator.decodePayload(try jsonData(missingSummary)) },
        "missing summary must fail full snapshot validation"
    )
}

run("title filter rejects AGENTS instruction preambles") {
    let title = TitleSanitizer.safeTitle(
        "# AGENTS.md instructions for /Users/example/project\n\nActual task follows"
    )
    check(title == "Actual task follows",
          "AGENTS preamble should not replace the following genuine request")

    let injected = """
    # AGENTS.md instructions for /Users/example/project

    <INSTRUCTIONS>
    ## GitHub PR 생성 규칙
    모든 작업은 GitHub PR 생성 규칙을 따라야 합니다.
    </INSTRUCTIONS>
    <environment_context>
      <cwd>/Users/example/project</cwd>
    </environment_context>
    카탈로그 유닛맵 버전 갱신 시점을 조사해줘
    """
    let identity = TitleSanitizer.taskIdentity(injected)
    check(identity?.title == "카탈로그 유닛맵 버전 갱신 시점을 조사해줘",
          "entire AGENTS INSTRUCTIONS block should be excluded from identity")
    check(identity?.description.contains("GitHub PR 생성 규칙") == false,
          "AGENTS body must not become task description")

    let replacement = """
    # AGENTS.md instructions for /Users/example/project
    <INSTRUCTIONS>
    These AGENTS.md instructions replace all previously provided AGENTS.md instructions.
    ## Replacement Rules
    </INSTRUCTIONS>
    실제 사용자 요청
    """
    check(TitleSanitizer.taskIdentity(replacement)?.title == "실제 사용자 요청",
          "replacement preamble block should not become identity")

    let normalRequest = "# AGENTS.md instructions 파일의 적용 범위를 설명해줘"
    check(TitleSanitizer.taskIdentity(normalRequest)?.title
            == "AGENTS.md instructions 파일의 적용 범위를 설명해줘",
          "ordinary user request containing instruction words must be preserved")
}

run("task purpose formatting is scannable and deduplicates title") {
    let description = """
    # AGENTS.md instructions
    You are Codex and must follow setup.
    목적은 Codex 작업을 한눈에 확인하는 것입니다. 두 모델의 작업을 구분합니다. 완료 상태를 명확히 보여 줍니다. 진행 중인 작업도 안전하게 추적합니다.
    /Users/example/Projects/agentboard
    """
    let purpose = TaskDescriptionFormatter.presentation(
        title: "AgentBoard 개발",
        description: description
    )
    check(purpose.previewLines.count == 3,
          "long purpose should present at most three readable lines initially")
    check(purpose.isTruncated && purpose.allLines.count > 3,
          "additional purpose lines should be available through expansion")
    check(!purpose.allLines.joined().contains("AGENTS.md"),
          "setup boilerplate should be filtered from purpose")
    check(!purpose.allLines.contains(where: { $0.hasPrefix("/Users/") }),
          "path-only setup lines should be filtered from purpose")

    let proseWithPath = TaskDescriptionFormatter.presentation(
        title: "결제 취소",
        description: """
        구현 담당입니다. /Users/me/app에서 결제 취소를 구현합니다.
        /Users/me/app
        결제 취소
        사용자가 결제를 취소하면 재고와 결제 상태를 일관되게 복구합니다.
        """
    )
    check(
        proseWithPath.allLines.joined(separator: " ").contains(
            "/Users/me/app에서 결제 취소를 구현합니다"
        ),
        "path-prefixed task prose must not be deleted"
    )
    check(
        !proseWithPath.allLines.contains("/Users/me/app"),
        "standalone path token should still be removed"
    )
    check(
        !proseWithPath.allLines.contains(where: {
            $0.hasPrefix("구현 담당입니다")
        }),
        "role boilerplate should be removed without deleting task prose"
    )
    check(
        !proseWithPath.allLines.contains("결제 취소"),
        "title-duplicate line should not be repeated in purpose"
    )

    let identical = TaskDescriptionFormatter.presentation(
        title: "AgentBoard 개발",
        description: "AgentBoard 개발"
    )
    check(identical.isEmpty,
          "description identical to title should not be repeated")

    let longSingleLine = TaskDescriptionFormatter.presentation(
        title: "Long purpose",
        description: (1...40).map { "긴 목적 \($0) 설명" }.joined(separator: " "),
        maximumLineLength: 80
    )
    check(
        longSingleLine.allLines.count == 1,
        "one long sentence must remain one logical full purpose entry"
    )
    check(
        longSingleLine.previewLines.count == 1
            && longSingleLine.previewLines[0].hasSuffix("…")
            && longSingleLine.isTruncated,
        "long sentence preview should shorten at a word boundary with disclosure"
    )
    check(
        longSingleLine.allLines[0].contains("긴 목적 40 설명"),
        "더 보기 content should retain the full logical sentence"
    )

    let compactChunks = TaskDescriptionFormatter.presentation(
        title: "Compact purpose",
        description: (1...20)
            .map { "사용자에게 읽기 쉬운 목적 문장 \($0)입니다." }
            .joined(separator: " ")
    )
    check(compactChunks.previewLines.count == 3,
          "compact layout should keep at most three short preview bullets")
    check(compactChunks.allLines.count == 20,
          "allLines should retain logical sentences rather than 40-character fragments")
    check(compactChunks.previewLines.allSatisfy { $0.count <= 49 },
          "preview sentences should be shortened near the readable character budget")
    check(compactChunks.isTruncated,
          "remaining long purpose content should be disclosed through more action")
}

run("visibility policy and panel geometry follow review requirements") {
    let now = Date()
    let oldResponse = AgentCard(
        id: UUID(),
        provider: .openai,
        title: "오래된 응답",
        cwd: nil,
        state: .responseEnded,
        lastEventAt: now.addingTimeInterval(-31 * 24 * 60 * 60)
    )
    check(
        !BoardVisibilityPolicy.isVisible(oldResponse, now: now),
        "response-ended older than 30 days should follow completed visibility"
    )
    let oldExplicit = AgentCard(
        id: UUID(),
        provider: .deepseek,
        title: "오래된 대기",
        cwd: nil,
        state: .waiting,
        lastEventAt: now.addingTimeInterval(-60 * 24 * 60 * 60),
        hasExplicitReport: true
    )
    check(
        BoardVisibilityPolicy.isVisible(oldExplicit, now: now),
        "explicit unfinished report should remain visible"
    )
    let twentyDayCompleted = AgentCard(
        id: UUID(),
        provider: .openai,
        title: "완료",
        cwd: nil,
        state: .completed,
        lastEventAt: now.addingTimeInterval(-20 * 24 * 60 * 60),
        hasExplicitReport: true
    )
    check(
        BoardVisibilityPolicy.isVisible(twentyDayCompleted, now: now),
        "completed 30-day display window should include twenty days"
    )
    let oldExplicitResponseEnded = AgentCard(
        id: UUID(),
        provider: .deepseek,
        title: "오래된 응답 종료",
        cwd: nil,
        state: .responseEnded,
        lastEventAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
        hasExplicitReport: true
    )
    check(
        !BoardVisibilityPolicy.isVisible(oldExplicitResponseEnded, now: now),
        "responseEnded should use the same 30-day visibility window"
    )
    check(
        BoardVisibilityPolicy.isVisible(oldResponse, now: now, showAllHistory: true),
        "all-history toggle should reveal old records"
    )
    let frozen = FrozenCardOrder.merged(
        frozen: [oldResponse.id],
        currentSorted: [oldExplicit, oldResponse]
    )
    check(frozen == [oldResponse.id, oldExplicit.id], "newcomers should append to frozen order")

    check(BoardPanelGeometry.defaultSize == CGSize(width: 360, height: 480),
          "default panel size should remain 360x480")
    let resized = BoardPanelGeometry.constrainedResize(
        proposed: CGSize(width: 1_600, height: 1_200),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
    )
    check(resized == CGSize(width: 1_200, height: 800), "resize should cap at screen bounds")
    let minimum = BoardPanelGeometry.constrainedResize(
        proposed: CGSize(width: 100, height: 100),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
    )
    check(minimum == CGSize(width: 320, height: 260), "resize minimum should be 320x260")
    let clamped = BoardPanelGeometry.clamped(
        frame: CGRect(x: -100, y: 900, width: 500, height: 400),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
    )
    check(clamped.minX >= 0 && clamped.maxX <= 1_200, "panel x should clamp into screen")
    check(clamped.minY >= 0 && clamped.maxY <= 800, "panel y should clamp into screen")
    let cursorSize = CGSize(width: 320, height: 260)
    check(
        ResizeCursorDirection.at(
            point: CGPoint(x: 1, y: 259),
            in: cursorSize
        ) == .diagonalNWSE,
        "top-left corner should use NWSE cursor"
    )
    check(
        ResizeCursorDirection.at(
            point: CGPoint(x: 319, y: 1),
            in: cursorSize
        ) == .diagonalNWSE,
        "bottom-right corner should use NWSE cursor"
    )
    check(
        ResizeCursorDirection.at(
            point: CGPoint(x: 319, y: 259),
            in: cursorSize
        ) == .diagonalNESW,
        "top-right corner should use NESW cursor"
    )
    check(
        ResizeCursorDirection.at(
            point: CGPoint(x: 1, y: 1),
            in: cursorSize
        ) == .diagonalNESW,
        "bottom-left corner should use NESW cursor"
    )
    check(
        ResizeCursorDirection.at(
            point: CGPoint(x: 1, y: 130),
            in: cursorSize
        ) == .leftRight,
        "vertical edge should use horizontal resize cursor"
    )
    check(
        ResizeCursorDirection.at(
            point: CGPoint(x: 160, y: 1),
            in: cursorSize
        ) == .upDown,
        "horizontal edge should use vertical resize cursor"
    )
    var snap = MagneticSnapAxis()
    check(snap.update(rawEdge: 102, candidates: [100, 300]) == 100,
          "magnetic edge should acquire within 8pt")
    check(snap.update(rawEdge: 115, candidates: [100, 300]) == 100,
          "magnetic edge should hold within release threshold")
    check(snap.update(rawEdge: 121, candidates: [100, 300]) == 121,
          "magnetic edge should release beyond 20pt")
    check(snap.update(rawEdge: 104, candidates: [100, 300]) == 100,
          "released edge should reacquire on return")
    check(snap.update(rawEdge: 108, candidates: [300]) == 108,
          "snap should release when locked target disappears from candidates")
    var crossingSnap = MagneticSnapAxis()
    check(
        crossingSnap.update(
            rawEdge: 120,
            previousRawEdge: 80,
            candidates: [100, 300]
        ) == 100,
        "fast drag segment crossing a candidate should acquire snap on that event"
    )
    check(
        crossingSnap.update(
            rawEdge: 125,
            previousRawEdge: 120,
            candidates: [100, 300]
        ) == 125,
        "crossing snap should require a further event before deliberate breakout"
    )
    check(
        PanelMoveGeometry.originCandidates(
            edgeCandidates: [100, 300],
            axisSpan: 360
        ) == [-260, -60, 100, 300],
        "move snap candidates should align either panel edge to desktop edges"
    )
    check(
        PanelMoveGeometry.originCandidates(
            edgeCandidates: [100, 300],
            axisSpan: 480
        ) == [-380, -180, 100, 300],
        "vertical move candidates should align using panel height, not width"
    )
    let firstScreen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    let secondScreen = CGRect(x: 1_200, y: 0, width: 1_200, height: 800)
    check(
        MultiScreenGeometry.targetVisibleFrame(
            pointer: CGPoint(x: 1_350, y: 300),
            proposedFrame: CGRect(x: 1_100, y: 200, width: 360, height: 480),
            visibleFrames: [firstScreen, secondScreen],
            fallback: firstScreen
        ) == secondScreen,
        "pointer on a second monitor should select that screen for move"
    )
    let moveClamped = PanelMoveGeometry.frame(
        initialFrame: CGRect(x: 100, y: 100, width: 360, height: 480),
        rawOrigin: CGPoint(x: 2_300, y: 700),
        movingX: 2_300,
        movingY: 700,
        visibleFrame: secondScreen
    )
    check(
        moveClamped.maxX <= secondScreen.maxX
            && moveClamped.maxY <= secondScreen.maxY,
        "move should remain fully inside the pointer target screen"
    )
    let panelSize = CGSize(width: 360, height: 480)
    let leftDisplayed = CGRect(
        origin: CGPoint(x: firstScreen.minX, y: 120),
        size: panelSize
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: leftDisplayed,
            rawFrame: leftDisplayed.offsetBy(dx: -32, dy: 0),
            mouseDelta: CGSize(width: -32, height: 0),
            pointer: CGPoint(x: 10, y: 300),
            startVisibleFrame: firstScreen,
            targetVisibleFrame: firstScreen
        ) == .left,
        "outer left edge should collapse after a 32pt outward drag"
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: leftDisplayed,
            rawFrame: leftDisplayed.offsetBy(dx: -31, dy: 0),
            mouseDelta: CGSize(width: -31, height: 0),
            pointer: CGPoint(x: 10, y: 300),
            startVisibleFrame: firstScreen,
            targetVisibleFrame: firstScreen
        ) == nil,
        "simple edge contact or less than 32pt should not collapse"
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: leftDisplayed,
            rawFrame: leftDisplayed.offsetBy(dx: -40, dy: 0),
            mouseDelta: CGSize(width: 0, height: -80),
            pointer: CGPoint(x: 10, y: 300),
            startVisibleFrame: firstScreen,
            targetVisibleFrame: firstScreen
        ) == nil,
        "vertical movement at the left edge should not collapse"
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: leftDisplayed,
            rawFrame: leftDisplayed.offsetBy(dx: -40, dy: -200),
            mouseDelta: CGSize(width: -40, height: -200),
            pointer: CGPoint(x: 10, y: 100),
            startVisibleFrame: firstScreen,
            targetVisibleFrame: firstScreen
        ) == nil,
        "diagonal movement should not collapse when vertical motion dominates"
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: leftDisplayed,
            rawFrame: leftDisplayed.offsetBy(dx: -40, dy: 0),
            mouseDelta: CGSize(width: 40, height: 0),
            pointer: CGPoint(x: 10, y: 300),
            startVisibleFrame: firstScreen,
            targetVisibleFrame: firstScreen
        ) == nil,
        "wrong horizontal drag direction should cancel edge collapse"
    )
    let rightDisplayed = CGRect(
        x: secondScreen.maxX - panelSize.width,
        y: 120,
        width: panelSize.width,
        height: panelSize.height
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: rightDisplayed,
            rawFrame: rightDisplayed.offsetBy(dx: 32, dy: 0),
            mouseDelta: CGSize(width: 32, height: 0),
            pointer: CGPoint(x: 2_390, y: 300),
            startVisibleFrame: secondScreen,
            targetVisibleFrame: secondScreen
        ) == .right,
        "outer right edge should collapse after a 32pt outward drag"
    )
    let sharedRight = CGRect(
        x: firstScreen.maxX - panelSize.width,
        y: 120,
        width: panelSize.width,
        height: panelSize.height
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: sharedRight,
            rawFrame: sharedRight.offsetBy(dx: 40, dy: 0),
            mouseDelta: CGSize(width: 40, height: 0),
            pointer: CGPoint(x: 1_150, y: 300),
            startVisibleFrame: firstScreen,
            targetVisibleFrame: firstScreen
        ) == .right,
        "rightward collapse should work at a screen edge even with an adjacent monitor"
    )
    let sharedLeft = CGRect(
        x: secondScreen.minX,
        y: 120,
        width: panelSize.width,
        height: panelSize.height
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: sharedLeft,
            rawFrame: sharedLeft.offsetBy(dx: -40, dy: 0),
            mouseDelta: CGSize(width: -40, height: 0),
            pointer: CGPoint(x: 1_250, y: 300),
            startVisibleFrame: secondScreen,
            targetVisibleFrame: secondScreen
        ) == .left,
        "leftward collapse should work symmetrically at the right-hand screen edge"
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: sharedRight,
            rawFrame: sharedRight.offsetBy(dx: 40, dy: 0),
            mouseDelta: CGSize(width: 40, height: 0),
            pointer: CGPoint(x: 1_210, y: 300),
            startVisibleFrame: firstScreen,
            targetVisibleFrame: secondScreen
        ) == nil,
        "entering the right-hand monitor should not trigger left collapse from raw overflow"
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: sharedRight,
            rawFrame: sharedRight.offsetBy(dx: 40, dy: 0),
            mouseDelta: CGSize(width: 40, height: 0),
            pointer: CGPoint(x: 1_150, y: 300),
            startVisibleFrame: secondScreen,
            targetVisibleFrame: firstScreen
        ) == nil,
        "a drag that starts and ends on different screens must not collapse"
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: sharedRight,
            rawFrame: sharedRight.offsetBy(dx: 40, dy: 0),
            mouseDelta: CGSize(width: 40, height: 0),
            pointer: CGPoint(x: 1_210, y: 300),
            startVisibleFrame: secondScreen,
            targetVisibleFrame: firstScreen
        ) == nil,
        "collapse should require the pointer to remain inside its target screen"
    )
    check(
        PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: CGRect(
                x: secondScreen.minX + 80,
                y: 120,
                width: panelSize.width,
                height: panelSize.height
            ),
            rawFrame: CGRect(
                x: secondScreen.minX + 40,
                y: 120,
                width: panelSize.width,
                height: panelSize.height
            ),
            mouseDelta: CGSize(width: -40, height: 0),
            pointer: CGPoint(x: 1_250, y: 300),
            startVisibleFrame: secondScreen,
            targetVisibleFrame: secondScreen
        ) == nil,
        "collapse should require the actually displayed frame to touch the screen edge"
    )
    check(
        PanelEdgeCollapseGeometry.handleFrame(
            edge: .left,
            visibleFrame: firstScreen,
            referenceFrame: CGRect(
                x: 40,
                y: firstScreen.maxY - 20,
                width: panelSize.width,
                height: panelSize.height
            )
        ) == CGRect(
            x: firstScreen.minX,
            y: firstScreen.maxY
                - PanelEdgeCollapseGeometry.handleSize.height,
            width: PanelEdgeCollapseGeometry.handleSize.width,
            height: PanelEdgeCollapseGeometry.handleSize.height
        ),
        "collapsed handle should sit on the screen edge and clamp vertically"
    )
    check(
        PanelEdgeCollapseGeometry.handleFrame(
            edge: .right,
            visibleFrame: secondScreen,
            referenceFrame: CGRect(
                x: 1_500,
                y: 200,
                width: panelSize.width,
                height: panelSize.height
            )
        ).maxX == secondScreen.maxX,
        "right collapsed handle should remain attached to the right screen edge"
    )

    let overlap = CGRect(x: 50, y: 50, width: 200, height: 200)
    let nonOverlap = CGRect(x: 500, y: 500, width: 100, height: 100)
    let verticalEdges = MagneticSnapCandidates.verticalEdges(
        externalFrames: [overlap, nonOverlap],
        panelFrame: CGRect(x: 100, y: 100, width: 320, height: 260),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
    )
    check(verticalEdges.contains(50) && verticalEdges.contains(250),
          "overlapping external window edges should be snap candidates")
    check(!verticalEdges.contains(500) && !verticalEdges.contains(600),
          "orthogonally irrelevant windows should be excluded")
    check(verticalEdges.contains(0) && verticalEdges.contains(1_200),
          "visible display edges should be snap candidates")
    let gapNeighbor = CGRect(x: 600, y: 150, width: 120, height: 100)
    let gapEdges = MagneticSnapCandidates.verticalEdges(
        externalFrames: [gapNeighbor],
        panelFrame: CGRect(x: 100, y: 100, width: 320, height: 260),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
    )
    check(gapEdges.contains(600) && gapEdges.contains(720),
          "adjacent window across a horizontal gap should remain a vertical snap target")
    let horizontalGapEdges = MagneticSnapCandidates.horizontalEdges(
        externalFrames: [CGRect(x: 150, y: 500, width: 100, height: 100)],
        panelFrame: CGRect(x: 100, y: 100, width: 320, height: 260),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
    )
    check(horizontalGapEdges.contains(500) && horizontalGapEdges.contains(600),
          "adjacent window across a vertical gap should remain a horizontal snap target")

    let converted = MagneticSnapCandidates.appKitBounds(
        fromCoreGraphics: CGRect(x: 10, y: 20, width: 100, height: 50),
        primaryDisplayHeight: 900
    )
    check(converted.origin == CGPoint(x: 10, y: 830),
          "CG top-left coordinates should translate to AppKit bottom-left")

    let resizeStart = CGRect(x: 100, y: 100, width: 360, height: 480)
    let resizeVisible = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    let rightEdges = PanelResizeGeometry.rawMovingEdges(
        initialFrame: resizeStart,
        handle: .right,
        mouseDelta: CGSize(width: 40, height: 0),
        visibleFrame: resizeVisible
    )
    let rightFrame = PanelResizeGeometry.frame(
        initialFrame: resizeStart,
        handle: .right,
        movingX: rightEdges.x,
        movingY: rightEdges.y,
        visibleFrame: resizeVisible
    )
    check(rightFrame.minX == resizeStart.minX && rightFrame.width == 400,
          "right resize should preserve opposite left edge")
    let leftEdges = PanelResizeGeometry.rawMovingEdges(
        initialFrame: resizeStart,
        handle: .left,
        mouseDelta: CGSize(width: 30, height: 0),
        visibleFrame: resizeVisible
    )
    let leftFrame = PanelResizeGeometry.frame(
        initialFrame: resizeStart,
        handle: .left,
        movingX: leftEdges.x,
        movingY: leftEdges.y,
        visibleFrame: resizeVisible
    )
    check(leftFrame.maxX == resizeStart.maxX && leftFrame.width == 330,
          "left resize should preserve opposite right edge")
    let topEdges = PanelResizeGeometry.rawMovingEdges(
        initialFrame: resizeStart,
        handle: .top,
        mouseDelta: CGSize(width: 0, height: 40),
        visibleFrame: resizeVisible
    )
    let topFrame = PanelResizeGeometry.frame(
        initialFrame: resizeStart,
        handle: .top,
        movingX: topEdges.x,
        movingY: topEdges.y,
        visibleFrame: resizeVisible
    )
    check(topFrame.minY == resizeStart.minY && topFrame.height == 520,
          "top resize should preserve opposite bottom edge")
    let bottomEdges = PanelResizeGeometry.rawMovingEdges(
        initialFrame: resizeStart,
        handle: .bottom,
        mouseDelta: CGSize(width: 0, height: 20),
        visibleFrame: resizeVisible
    )
    let bottomFrame = PanelResizeGeometry.frame(
        initialFrame: resizeStart,
        handle: .bottom,
        movingX: bottomEdges.x,
        movingY: bottomEdges.y,
        visibleFrame: resizeVisible
    )
    check(
        bottomFrame.maxY == resizeStart.maxY && bottomFrame.height == 460,
        "bottom resize should preserve opposite top edge"
    )
    let snappedPastMinimum = PanelResizeGeometry.frame(
        initialFrame: resizeStart,
        handle: .left,
        movingX: 350,
        movingY: nil,
        visibleFrame: resizeVisible
    )
    check(
        snappedPastMinimum.maxX == resizeStart.maxX
            && snappedPastMinimum.width == BoardPanelGeometry.minimumSize.width,
        "post-snap left clamp must preserve the fixed right edge"
    )
    let cornerPastMinimum = PanelResizeGeometry.frame(
        initialFrame: resizeStart,
        handle: .bottomLeft,
        movingX: 350,
        movingY: 350,
        visibleFrame: resizeVisible
    )
    check(
        cornerPastMinimum.maxX == resizeStart.maxX
            && cornerPastMinimum.maxY == resizeStart.maxY
            && cornerPastMinimum.size == BoardPanelGeometry.minimumSize,
        "corner clamp should preserve both fixed opposite edges"
    )
}

run("AGENTS integration preserves surrounding bytes and rejects malformed markers") {
    let directory = try temporaryDirectory()
    let path = directory.appendingPathComponent("AGENTS.md")
    let original = Data("기존 지침 🌏 no trailing newline".utf8)
    try original.write(to: path)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o640)],
        ofItemAtPath: path.path
    )
    let block = Data(
        "\(AgentsIntegration.beginMarker)\nmanaged\n\(AgentsIntegration.endMarker)\n".utf8
    )
    let installed = try AgentsIntegration.install(existing: original, block: block)
    check(installed.usedLeadingSeparator, "no-final-newline install should track separator")
    try AgentsIntegration.writeFile(installed.data, to: path)
    let installedText = String(data: try Data(contentsOf: path), encoding: .utf8)!
    check(installedText.hasPrefix(String(data: original, encoding: .utf8)!),
          "install should preserve original prefix")
    let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
    check(permissions?.intValue == 0o640, "AGENTS permissions should be preserved")

    let reinstalled = try AgentsIntegration.install(
        existing: try Data(contentsOf: path),
        block: block
    )
    let reinstalledText = String(data: reinstalled.data, encoding: .utf8)!
    check(
        reinstalledText.components(separatedBy: AgentsIntegration.beginMarker).count == 2,
        "reinstall should keep one managed block"
    )
    let removedWithoutEdit = try AgentsIntegration.remove(
        existing: reinstalled.data,
        removeLeadingSeparator: true
    )
    let removedInitialInstall = try AgentsIntegration.remove(
        existing: installed.data,
        removeLeadingSeparator: true
    )
    check(removedInitialInstall == original, "initial install should remove cleanly")
    let simpleRemoved = try AgentsIntegration.remove(
        existing: Data(
            "A\n\(AgentsIntegration.beginMarker)\nB\n\(AgentsIntegration.endMarker)\n".utf8
        ),
        removeLeadingSeparator: true
    )
    check(simpleRemoved == Data("A".utf8), "simple leading separator removal should work")
    let unicodeRemoved = try AgentsIntegration.remove(
        existing: Data(
            "A🌏\n\(AgentsIntegration.beginMarker)\nB\n\(AgentsIntegration.endMarker)\n".utf8
        ),
        removeLeadingSeparator: true
    )
    check(unicodeRemoved == Data("A🌏".utf8), "unicode leading separator removal should work")
    let markerStart = reinstalledText.range(of: AgentsIntegration.beginMarker)!.lowerBound
    let prefixBeforeMarker = String(reinstalledText[..<markerStart].suffix(4))
    check(
        removedWithoutEdit == original,
        "uninstall without later edits should restore original bytes: lengths=\(reinstalled.data.count)/\(installed.data.count) before=\(String(reflecting: prefixBeforeMarker)) removed=\(String(reflecting: String(data: removedWithoutEdit, encoding: .utf8)))"
    )

    let edited = Data(
        (String(data: reinstalled.data, encoding: .utf8)! + "사용자 추가 지침\n").utf8
    )
    let removed = try AgentsIntegration.remove(
        existing: edited,
        removeLeadingSeparator: true
    )
    check(
        String(data: removed, encoding: .utf8) ==
            String(data: original, encoding: .utf8)! + "\n사용자 추가 지침\n",
        "uninstall should remove only its block while preserving later edits: \(String(reflecting: String(data: removed, encoding: .utf8)))"
    )

    let malformed = Data(
        "before\n\(AgentsIntegration.beginMarker)\nunterminated\n".utf8
    )
    checkThrows(
        { try AgentsIntegration.remove(existing: malformed, removeLeadingSeparator: false) },
        "unmatched begin marker must fail"
    )
    checkThrows(
        { try AgentsIntegration.install(existing: malformed, block: block) },
        "install must not rewrite malformed delimiter state"
    )
}

run("task identity stays stable across follow-up turns and legacy decoding is safe") {
    let thread = UUID(uuidString: "B1B1B1B1-B1B1-41B1-81B1-B1B1B1B1B1B1")!
    let records = try [
        sessionMeta(id: thread.uuidString, timestamp: "2026-11-13T01:00:00.000Z"),
        event(
            "task_started",
            timestamp: "2026-11-13T01:00:01.000Z",
            extra: ["turn_id": "one"]
        ),
        event(
            "user_message",
            timestamp: "2026-11-13T01:00:02.000Z",
            extra: [
                "message": "<environment_context>noise</environment_context>\n# Build a stable AgentBoard task identity\n\nKeep the overall purpose visible while progress changes."
            ]
        ),
        event(
            "task_complete",
            timestamp: "2026-11-13T01:01:00.000Z",
            extra: ["turn_id": "one"]
        ),
        event(
            "task_started",
            timestamp: "2026-11-13T01:02:00.000Z",
            extra: ["turn_id": "two"]
        ),
        event(
            "user_message",
            timestamp: "2026-11-13T01:02:01.000Z",
            extra: ["message": "Now update the status tabs"]
        )
    ].compactMap {
        SessionLineParser.parse(
            $0,
            trustPolicy: testTrustPolicy
        )
    }
    let result = SessionReducer.reduce(
        records: records,
        card: nil,
        cursor: CursorContext(),
        seenEventIds: []
    )
    check(result.card?.title == "Build a stable AgentBoard task identity",
          "first genuine prompt should establish task title")
    check(result.card?.description?.contains("overall purpose") == true,
          "first prompt should establish bounded description")
    check(result.card?.currentRequest == "Now update the status tabs",
          "follow-up should update current request only")
    check(
        TitleSanitizer.mergedTaskTitle(
            initialTitle: "Initial task purpose",
            existingTitle: "AgentBoard 개발",
            hasExplicitReport: true
        ) == "AgentBoard 개발",
        "useful explicit report title should survive backfill"
    )
    check(
        TitleSanitizer.mergedTaskTitle(
            initialTitle: "Initial task purpose",
            existingTitle: "음 너무 길다 follow-up",
            hasExplicitReport: false
        ) == "Initial task purpose",
        "bad follow-up title should be replaced by initial identity"
    )

    let modern = AgentCard(
        id: thread,
        provider: .openai,
        title: "Legacy title",
        cwd: "/tmp/legacy"
    )
    var object = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(modern)
    ) as! [String: Any]
    for key in [
        "description", "currentRequest", "archivedAt",
        "taskIdentityCaptured", "completionUnread", "completionRevision",
        "customTitle"
    ] {
        object.removeValue(forKey: key)
    }
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let legacy = try JSONDecoder().decode(AgentCard.self, from: legacyData)
    check(legacy.title == "Legacy title", "legacy card title should decode")
    check(legacy.description == nil && legacy.taskIdentityCaptured == nil,
          "legacy cards should remain safely backfillable")
    check(!legacy.isCompletionUnread, "legacy cards must baseline as read")
}

run("custom title override survives source changes and restart") {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("custom-title.sqlite3")
    let store = try StateStore(path: database.path)
    let thread = UUID(uuidString: "E1E1E1E1-E1E1-41E1-81E1-E1E1E1E1E1E1")!
    let path = "/tmp/custom-title.jsonl"
    try ingest(
        try [
            sessionMeta(
                id: thread.uuidString,
                timestamp: "2026-11-13T10:00:00.000Z"
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T10:00:01.000Z",
                extra: ["turn_id": "one"]
            ),
            event(
                "user_message",
                timestamp: "2026-11-13T10:00:02.000Z",
                extra: ["message": "원래 source-derived 제목"]
            )
        ],
        store: store,
        path: path
    )
    checkThrows(
        { try AgentTitleOverride.normalized("   ") },
        "empty custom title should be rejected"
    )
    check(
        (try? AgentTitleOverride.normalized(String(repeating: "가", count: 81))) == nil,
        "custom title longer than 80 characters should be rejected"
    )
    check(
        (try? AgentTitleOverride.normalized("  사용자   지정\n제목  "))
            == "사용자 지정 제목",
        "custom title should trim and normalize whitespace"
    )

    let beforeState = try store.loadCards().first!
    try store.setCustomTitle(cardId: thread, title: "사용자 지정 제목")
    var card = try store.loadCards().first!
    check(card.title == beforeState.title, "custom title must not overwrite source title")
    check(card.displayTitle == "사용자 지정 제목", "display title should use override")
    check(card.state == beforeState.state
            && card.isCompletionUnread == beforeState.isCompletionUnread
            && card.archived == beforeState.archived,
          "custom title should not alter state/read/archive")

    try ingest(
        try [
            event(
                "task_started",
                timestamp: "2026-11-13T10:01:00.000Z",
                extra: ["turn_id": "two"]
            ),
            event(
                "user_message",
                timestamp: "2026-11-13T10:01:01.000Z",
                extra: ["message": "새 follow-up 요청"]
            )
        ],
        store: store,
        path: path
    )
    card = try store.loadCards().first!
    check(card.displayTitle == "사용자 지정 제목",
          "new user turn should preserve custom title")

    let report = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "E2E2E2E2-E2E2-42E2-82E2-E2E2E2E2E2E2")!,
        timestamp: AgentBoardDate.parse("2026-11-13T10:01:02.000Z")!,
        state: .running,
        title: "report source-derived 제목",
        summary: "진행 중"
    )
    try ingest(
        [
            try callLine(
                callId: "custom-title-report",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-13T10:01:01.500Z"
            ),
            try outputLine(
                callId: "custom-title-report",
                output: try reportMarker(report),
                timestamp: "2026-11-13T10:01:02.000Z"
            )
        ],
        store: store,
        path: path
    )
    card = try store.loadCards().first!
    check(card.title == "report source-derived 제목",
          "report should be able to update source-derived title")
    check(card.displayTitle == "사용자 지정 제목",
          "report update must preserve custom title")

    try executeSQL(
        path: database.path,
        sql: """
        UPDATE cards SET payload = CAST(json_set(
          CAST(payload AS TEXT),
          '$.title', 'Injected source title',
          '$.description', 'Injected instruction body',
          '$.taskIdentityCaptured', json('true')
        ) AS BLOB) WHERE id = '\(thread.uuidString)';
        """
    )
    try store.repairTaskIdentity(
        cardId: thread,
        path: "/tmp/custom-title-repair.jsonl",
        identity: TitleSanitizer.TaskIdentity(
            title: "복구된 source 제목",
            description: "복구된 source 설명"
        ),
        contaminations: [
            TitleSanitizer.LegacyInjectionContamination(
                title: "Injected source title",
                description: "Injected instruction body"
            )
        ]
    )
    card = try store.loadCards().first!
    check(card.displayTitle == "사용자 지정 제목",
          "identity repair should preserve custom title override")

    let reopened = try StateStore(path: database.path)
    card = try reopened.loadCards().first!
    check(card.displayTitle == "사용자 지정 제목",
          "custom title should survive restart")
    try reopened.setCustomTitle(cardId: thread, title: nil)
    card = try reopened.loadCards().first!
    check(card.displayTitle == card.title,
          "reset should restore the source-derived title")
}

run("bounded identity backfill preserves archive and does not overwrite twice") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("identity.sqlite3").path)
    let thread = UUID(uuidString: "B2B2B2B2-B2B2-42B2-82B2-B2B2B2B2B2B2")!
    try ingest(
        try [
            sessionMeta(id: thread.uuidString, timestamp: "2026-11-13T02:00:00.000Z"),
            event(
                "task_started",
                timestamp: "2026-11-13T02:00:01.000Z",
                extra: ["turn_id": "legacy"]
            )
        ],
        store: store
    )
    try store.setArchived(cardId: thread, archived: true)
    let identity = TitleSanitizer.TaskIdentity(
        title: "Recovered overall purpose",
        description: "Recovered from the initial user prompt without resetting the cursor."
    )
    try store.backfillTaskIdentity(
        cardId: thread,
        path: "/tmp/legacy.jsonl",
        identity: identity
    )
    var card = try store.loadCards(includeArchived: true).first
    check(card?.title == identity.title, "backfill should restore useful title")
    check(card?.description == identity.description, "backfill should restore description")
    check(card?.archived == true, "backfill must preserve archive preference")
    try store.backfillTaskIdentity(
        cardId: thread,
        path: "/tmp/legacy.jsonl",
        identity: TitleSanitizer.TaskIdentity(
            title: "Wrong later value",
            description: "Must not replace captured identity"
        )
    )
    card = try store.loadCards(includeArchived: true).first
    check(card?.title == identity.title, "captured identity should not be overwritten")

    let explicitThread = UUID(uuidString: "C1C1C1C1-C1C1-41C1-81C1-C1C1C1C1C1C1")!
    try ingest(
        try [
            sessionMeta(
                id: explicitThread.uuidString,
                timestamp: "2026-11-13T02:10:00.000Z"
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T02:10:01.000Z",
                extra: ["turn_id": "explicit"]
            ),
            callLine(
                callId: "explicit-title",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-13T02:10:02.000Z"
            ),
            outputLine(
                callId: "explicit-title",
                output: try reportMarker(
                    reportEnvelope(
                        threadId: explicitThread,
                        eventId: UUID(uuidString: "C2C2C2C2-C2C2-42C2-82C2-C2C2C2C2C2C2")!,
                        timestamp: AgentBoardDate.parse("2026-11-13T02:10:03.000Z")!,
                        state: .running,
                        title: "AgentBoard 개발",
                        summary: "진행 중"
                    )
                ),
                timestamp: "2026-11-13T02:10:03.000Z"
            )
        ],
        store: store,
        path: "/tmp/explicit-controlled.jsonl",
        inode: 2
    )
    let identityDatabase = directory.appendingPathComponent("identity.sqlite3").path
    try executeSQL(
        path: identityDatabase,
        sql: """
        UPDATE cards
        SET payload = CAST(json_set(
            CAST(payload AS TEXT),
            '$.title', '음 너무 길다 bad follow-up',
            '$.taskIdentityCaptured', NULL,
            '$.description', NULL
        ) AS BLOB)
        WHERE id = '\(explicitThread.uuidString)';
        """
    )
    let preBackfill = try store.loadCards(includeArchived: true)
        .first(where: { $0.id == explicitThread })
    check(preBackfill?.title == "음 너무 길다 bad follow-up",
          "test setup should overwrite explicit card title")
    check(preBackfill?.hasExplicitReport == true,
          "test setup should retain explicit report provenance")
    try check(
        try reportTitles(path: identityDatabase, threadId: explicitThread)
            .contains("AgentBoard 개발"),
        "stored report payload should contain useful title"
    )
    try store.backfillTaskIdentity(
        cardId: explicitThread,
        path: "/tmp/explicit.jsonl",
        identity: TitleSanitizer.TaskIdentity(
            title: "Initial conversation request",
            description: "Original task purpose from the first user prompt"
        )
    )
    let explicitCard = try store.loadCards(includeArchived: true)
        .first(where: { $0.id == explicitThread })
    check(explicitCard?.title == "AgentBoard 개발",
          "backfill should preserve useful explicit report title")
    check(explicitCard?.description == "Original task purpose from the first user prompt",
          "backfill should still recover description")
    check(explicitCard?.currentRequest == "음 너무 길다 bad follow-up",
          "overwritten follow-up should be preserved as current request")
}

run("captured contaminated identity repair preserves report and lifecycle state") {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("repair.sqlite3")
    let store = try StateStore(path: database.path)
    let thread = UUID(uuidString: "CF1CF1CF-CF1C-4F1C-8F1C-CF1CF1CF1CF1")!
    let sessionPath = "/tmp/repair-session.jsonl"
    try ingest(
        try [
            sessionMeta(
                id: thread.uuidString,
                timestamp: "2026-11-13T05:00:00.000Z"
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T05:00:01.000Z",
                extra: ["turn_id": "repair"]
            ),
            callLine(
                callId: "repair-report",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-13T05:00:02.000Z"
            ),
            outputLine(
                callId: "repair-report",
                output: try reportMarker(
                    ReportEnvelope(
                        threadId: thread,
                        timestamp: AgentBoardDate.parse("2026-11-13T05:00:03.000Z")!,
                        payload: ReportPayload(
                            title: "정상 보고 제목",
                            state: .waiting,
                            steps: [
                                ReportStep(
                                    id: "inspect",
                                    title: "조사",
                                    status: .inProgress
                                )
                            ],
                            summary: "사용자 입력 대기",
                            description: "명시적으로 보고된 작업 목적"
                        )
                    )
                ),
                timestamp: "2026-11-13T05:00:03.000Z"
            )
        ],
        store: store,
        path: sessionPath
    )
    try store.setArchived(cardId: thread, archived: true)
    try executeSQL(
        path: database.path,
        sql: """
        UPDATE cards SET
          state = 'waiting',
          payload = CAST(json_set(
            CAST(payload AS TEXT),
            '$.title', 'GitHub PR 생성 규칙',
            '$.description', '## GitHub PR 생성 규칙\n모든 작업은 PR 규칙을 따라야 합니다.',
            '$.taskIdentityCaptured', json('true'),
            '$.currentRequest', '음 아냐 잘 해결함 ㅋ',
            '$.state', 'waiting',
            '$.completionUnread', json('true'),
            '$.completionRevision', 9
          ) AS BLOB)
        WHERE id = '\(thread.uuidString)';
        """
    )
    let identity = TitleSanitizer.TaskIdentity(
        title: "카탈로그 유닛맵 버전 갱신 시점 조사",
        description: "카탈로그 유닛맵 테이블의 버전 갱신 시점을 실제 사용자 요청에 맞춰 조사합니다."
    )
    try store.repairTaskIdentity(
        cardId: thread,
        path: sessionPath,
        identity: identity,
        contaminations: [
            TitleSanitizer.LegacyInjectionContamination(
                title: "GitHub PR 생성 규칙",
                description: "## GitHub PR 생성 규칙\n모든 작업은 PR 규칙을 따라야 합니다."
            )
        ]
    )
    var card = try store.loadCards(includeArchived: true).first!
    check(card.title == "정상 보고 제목",
          "repair should preserve trusted explicit report title")
    check(card.description == "명시적으로 보고된 작업 목적",
          "repair should preserve trusted explicit report purpose: \(String(reflecting: card.description))")
    check(card.currentRequest == "음 아냐 잘 해결함 ㅋ",
          "repair should preserve latest current request")
    check(card.state == .waiting, "repair should preserve state")
    check(card.steps.map(\.id) == ["inspect"], "repair should preserve steps")
    check(card.isCompletionUnread && card.completionRevision == 9,
          "repair should preserve unread and revision")
    check(card.archived, "repair should preserve hidden/archive preference")

    try store.repairTaskIdentity(
        cardId: thread,
        path: sessionPath,
        identity: TitleSanitizer.TaskIdentity(
            title: "Wrong repeated repair",
            description: "Must not replace"
        )
    )
    card = try store.loadCards(includeArchived: true).first!
    check(card.title == "정상 보고 제목",
          "identity repair should be idempotent")
}

run("collector repairs already captured contaminated card without touching cursor") {
    let directory = try temporaryDirectory()
    let codexHome = directory.appendingPathComponent("repair-codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/11/13", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sessions,
        withIntermediateDirectories: true
    )
    let file = sessions.appendingPathComponent("rollout-repair.jsonl")
    let thread = UUID(uuidString: "CF2CF2CF-CF2C-4F2C-8F2C-CF2CF2CF2CF2")!
    let injected = """
    # AGENTS.md instructions for /Users/example/msa

    <INSTRUCTIONS>
    ## GitHub PR 생성 규칙
    모든 작업은 GitHub PR 생성 규칙을 따라야 합니다.
    </INSTRUCTIONS>
    <environment_context>
      <cwd>/Users/example/msa</cwd>
    </environment_context>
    """
    let contaminationDescription = "## GitHub PR 생성 규칙\n모든 작업은 GitHub PR 생성 규칙을 따라야 합니다."
    let detectedContaminations = TitleSanitizer
        .legacyInjectionContaminations(in: injected)
    check(
        detectedContaminations.contains(where: {
            $0.title == "GitHub PR 생성 규칙"
                && $0.description == contaminationDescription
        }),
        "legacy contamination detector should reproduce injected body: \(detectedContaminations)"
    )
    let lines = try [
        sessionMeta(
            id: thread.uuidString,
            cwd: "/Users/example/msa",
            timestamp: "2026-11-13T06:00:00.000Z"
        ),
        event(
            "task_started",
            timestamp: "2026-11-13T06:00:01.000Z",
            extra: ["turn_id": "repair"]
        ),
        response(
            "message",
            timestamp: "2026-11-13T06:00:02.000Z",
            payload: [
                "role": "user",
                "content": [["type": "input_text", "text": injected]]
            ]
        ),
        response(
            "message",
            timestamp: "2026-11-13T06:00:03.000Z",
            payload: [
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "카탈로그 유닛맵 widget_unit_map 버전 업데이트 조사"
                ]]
            ]
        ),
        event(
            "task_complete",
            timestamp: "2026-11-13T06:00:04.000Z",
            extra: ["turn_id": "repair"]
        )
    ]
    try append(
        lines.reduce(Data()) { $0 + $1 + Data("\n".utf8) },
        to: file
    )
    let database = directory.appendingPathComponent("collector-repair.sqlite3")
    let store = try StateStore(path: database.path)
    let collector = SessionCollector(
        codexHome: codexHome.resolvingSymlinksInPath(),
        store: store
    )
    _ = collector.scanOnceSync()
    var card = try store.loadCards(includeArchived: true).first!
    check(card.title == "카탈로그 유닛맵 widget_unit_map 버전 업데이트 조사",
          "real-shaped contaminated input should use first genuine user prompt")
    check(card.description?.contains("GitHub PR 생성 규칙") == false,
          "collector first ingest must exclude full INSTRUCTIONS body")

    try store.setArchived(cardId: thread, archived: true)
    try executeSQL(
        path: database.path,
        sql: """
        UPDATE cards SET payload = CAST(json_set(
          CAST(payload AS TEXT),
          '$.title', 'GitHub PR 생성 규칙',
          '$.description', '## GitHub PR 생성 규칙\n모든 작업은 GitHub PR 생성 규칙을 따라야 합니다.',
          '$.taskIdentityCaptured', json('true'),
          '$.currentRequest', '음 아냐 잘 해결함 ㅋ'
        ) AS BLOB) WHERE id = '\(thread.uuidString)';
        """
    )
    let offsetsBefore = try cursorOffsets(path: database.path)
    _ = collector.scanOnceSync()
    card = try store.loadCards(includeArchived: true).first!
    check(card.title == "카탈로그 유닛맵 widget_unit_map 버전 업데이트 조사",
          "collector should repair already captured contaminated title")
    check(card.description?.contains("GitHub PR 생성 규칙") == false,
          "collector repair should replace contaminated description: \(String(reflecting: card.description))")
    check(card.currentRequest == "음 아냐 잘 해결함 ㅋ",
          "collector repair should preserve current request")
    check(card.archived, "collector repair should preserve hidden preference")
    check(card.state == .responseEnded,
          "collector repair should preserve lifecycle state")
    try check(try cursorOffsets(path: database.path) == offsetsBefore,
          "identity repair must not reset or advance source cursor")

    _ = collector.scanOnceSync()
    try check(try store.loadCards(includeArchived: true).first?.title
            == "카탈로그 유닛맵 widget_unit_map 버전 업데이트 조사",
          "identity repair should remain idempotent on later scans")
}

run("legacy report-error state repairs only with current-turn completion evidence") {
    let directory = try temporaryDirectory()
    let codexHome = directory.appendingPathComponent("state-repair-codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/11/13", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sessions,
        withIntermediateDirectories: true
    )
    let completedThread = UUID(uuidString: "FA1FA1FA-FA1F-4A1F-8A1F-FA1FA1FA1FA1")!
    let errorOnlyThread = UUID(uuidString: "FA2FA2FA-FA2F-4A2F-8A2F-FA2FA2FA2FA2")!

    func sourceLines(for thread: UUID, turn: String, complete: Bool) throws -> [Data] {
        var lines = try [
            sessionMeta(
                id: thread.uuidString,
                timestamp: "2026-11-13T12:00:00.000Z"
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T12:00:01.000Z",
                extra: ["turn_id": turn]
            )
        ]
        if complete {
            lines.append(
                try event(
                    "task_complete",
                    timestamp: "2026-11-13T12:00:02.000Z",
                    extra: ["turn_id": turn]
                )
            )
        }
        return lines
    }

    let completedFileURL = sessions.appendingPathComponent("completed.jsonl")
    let completedLines = try sourceLines(
        for: completedThread,
        turn: "repair-me",
        complete: true
    )
    try completedLines.reduce(Data()) {
        $0 + $1 + Data("\n".utf8)
    }.write(to: completedFileURL)
    let errorFileURL = sessions.appendingPathComponent("error-only.jsonl")
    let errorLines = try sourceLines(
        for: errorOnlyThread,
        turn: "still-error",
        complete: false
    )
    try errorLines.reduce(Data()) {
        $0 + $1 + Data("\n".utf8)
    }.write(to: errorFileURL)

    let enumerator = FileManager.default.enumerator(
        at: codexHome,
        includingPropertiesForKeys: nil
    )
    var enumerated: [String: URL] = [:]
    while let candidate = enumerator?.nextObject() as? URL {
        if candidate.pathExtension == "jsonl" {
            enumerated[candidate.lastPathComponent] = candidate
        }
    }
    guard let completedFile = enumerated["completed.jsonl"],
          let errorFile = enumerated["error-only.jsonl"] else {
        check(false, "state repair fixtures should be enumerable")
        return
    }

    let database = directory.appendingPathComponent("state-repair.sqlite3")
    let store = try StateStore(path: database.path)
    for (file, thread, lines, turn) in [
        (completedFile, completedThread, completedLines, "repair-me"),
        (errorFile, errorOnlyThread, errorLines, "still-error")
    ] {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        let inode = (attributes[.systemFileNumber] as! NSNumber).int64Value
        let size = (attributes[.size] as! NSNumber).int64Value
        let seed = lines.prefix(2).compactMap {
            SessionLineParser.parse($0, trustPolicy: testTrustPolicy)
        }
        try store.ingest(
            records: seed,
            path: file.path,
            inode: inode,
            endOffset: size
        )
        try executeSQL(
            path: database.path,
            sql: """
            UPDATE cards SET
              state = 'error',
              completed_at = NULL,
              payload = CAST(json_set(
                CAST(payload AS TEXT),
                '$.state', 'error',
                '$.responseLifecycle', NULL,
                '$.currentTurnId', '\(turn)',
                '$.summary', '도커 캐시 경로 오류',
                '$.steps', json('[{"id":"cleanup","title":"정리","status":"inProgress"}]'),
                '$.customTitle', '보존된 사용자 제목',
                '$.completionUnread', json('false'),
                '$.completionRevision', 7
              ) AS BLOB)
            WHERE id = '\(thread.uuidString)';
            """
        )
        try store.setArchived(cardId: thread, archived: true)
    }

    let collector = SessionCollector(
        codexHome: codexHome,
        store: store
    )
    _ = collector.scanOnceSync()
    let repaired = try store.loadCards(includeArchived: true)
        .first(where: { $0.id == completedThread })!
    check(repaired.state == .responseEnded,
          "current-turn task_complete should repair legacy error board state")
    check(repaired.responseLifecycle == .completed,
          "terminal evidence should set completed response lifecycle")
    check(repaired.reportedState == .error,
          "legacy report error outcome should move to reportedState")
    check(repaired.summary == "도커 캐시 경로 오류"
            && repaired.steps.first?.id == "cleanup",
          "response repair should preserve report summary and steps")
    check(repaired.displayTitle == "보존된 사용자 제목",
          "response repair should preserve custom title")
    check(repaired.archived && !repaired.isCompletionUnread
            && repaired.completionRevision == 7,
          "response repair should preserve archive/read/revision preferences")
    let untouchedError = try store.loadCards(includeArchived: true)
        .first(where: { $0.id == errorOnlyThread })!
    check(untouchedError.state == .running,
          "current-turn task_started evidence should repair legacy error to running")
    check(untouchedError.responseLifecycle == .running,
          "legacy card with active-turn evidence should receive running lifecycle")
    check(untouchedError.reportedState == .error
            && untouchedError.summary == "도커 캐시 경로 오류"
            && untouchedError.steps.first?.id == "cleanup",
          "running lifecycle repair should preserve helper report metadata")
    check(untouchedError.displayTitle == "보존된 사용자 제목"
            && untouchedError.archived
            && !untouchedError.isCompletionUnread
            && untouchedError.completionRevision == 7,
          "running lifecycle repair should preserve title and read/archive preferences")
    try check(
        try store.responseStateRepairCompleted(
            path: completedFile.path,
            cardId: completedThread,
            turnId: "repair-me"
        ),
        "successful response repair should be idempotently marked"
    )
    try check(
        try store.responseStateRepairCompleted(
            path: errorFile.path,
            cardId: errorOnlyThread,
            turnId: "still-error"
        ),
        "current-turn running evidence should be idempotently marked repaired"
    )
}

run("legacy lifecycle repair distinguishes abort, active, and read completion") {
    let directory = try temporaryDirectory()
    let codexHome = directory.appendingPathComponent("lifecycle-repair-codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/11/13", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sessions,
        withIntermediateDirectories: true
    )
    let database = directory.appendingPathComponent("lifecycle-repair.sqlite3")
    let store = try StateStore(path: database.path)

    func writeFixture(
        _ file: URL,
        thread: UUID,
        turn: String,
        includeComplete: Bool,
        includeAbort: Bool
    ) throws -> (URL, [Data], String) {
        var lines = try [
            sessionMeta(
                id: thread.uuidString,
                timestamp: "2026-11-13T14:00:00.000Z"
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T14:00:01.000Z",
                extra: ["turn_id": turn]
            )
        ]
        if includeComplete {
            lines.append(
                try event(
                    "task_complete",
                    timestamp: "2026-11-13T14:00:02.000Z",
                    extra: ["turn_id": turn]
                )
            )
        }
        if includeAbort {
            lines.append(
                try event(
                    "turn_aborted",
                    timestamp: "2026-11-13T14:00:03.000Z",
                    extra: ["turn_id": turn, "reason": "interrupted"]
                )
            )
        }
        try lines.reduce(Data()) {
            $0 + $1 + Data("\n".utf8)
        }.write(to: file)
        let enumerator = FileManager.default.enumerator(
            at: file.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        var enumeratedFile: URL?
        while let candidate = enumerator?.nextObject() as? URL {
            if candidate.lastPathComponent == file.lastPathComponent {
                enumeratedFile = candidate
                break
            }
        }
        return (enumeratedFile ?? file, lines, turn)
    }

    let abortThread = UUID(uuidString: "FB1FB1FB-FB1F-4B1F-8B1F-FB1FB1FB1FB1")!
    let activeThread = UUID(uuidString: "FB2FB2FB-FB2F-4B2F-8B2F-FB2FB2FB2FB2")!
    let readThread = UUID(uuidString: "FB3FB3FB-FB3F-4B3F-8B3F-FB3FB3FB3FB3")!
    let (abortFile, abortLines, _) = try writeFixture(
        sessions.appendingPathComponent("abort.jsonl"),
        thread: abortThread,
        turn: "abort-turn",
        includeComplete: false,
        includeAbort: true
    )
    let (activeFile, activeLines, _) = try writeFixture(
        sessions.appendingPathComponent("active.jsonl"),
        thread: activeThread,
        turn: "active-turn",
        includeComplete: false,
        includeAbort: false
    )
    let (readFile, readLines, _) = try writeFixture(
        sessions.appendingPathComponent("read.jsonl"),
        thread: readThread,
        turn: "read-turn",
        includeComplete: true,
        includeAbort: true
    )

    for (file, lines, thread, seedState) in [
        (abortFile, abortLines, abortThread, "completed"),
        (activeFile, activeLines, activeThread, "completed"),
        (readFile, readLines, readThread, "responseEnded")
    ] {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        let inode = (attributes[.systemFileNumber] as! NSNumber).int64Value
        let size = (attributes[.size] as! NSNumber).int64Value
        let seed = lines.prefix(2).compactMap {
            SessionLineParser.parse($0, trustPolicy: testTrustPolicy)
        }
        try store.ingest(
            records: seed,
            path: file.path,
            inode: inode,
            endOffset: size
        )
        try executeSQL(
            path: database.path,
            sql: """
            UPDATE cards SET
              state = '\(seedState)',
              completed_at = \(seedState == "responseEnded" ? "1794391202" : "NULL"),
              payload = CAST(json_set(
                CAST(payload AS TEXT),
                '$.state', '\(seedState)',
                '$.responseLifecycle', NULL,
                '$.reportedState', 'completed',
                '$.currentTurnId', CASE
                  WHEN id='\(abortThread.uuidString)' THEN 'abort-turn'
                  WHEN id='\(activeThread.uuidString)' THEN 'active-turn'
                  ELSE 'read-turn' END,
                '$.summary', 'helper completed report',
                '$.completionUnread', json('false'),
                '$.completionRevision', 7
              ) AS BLOB)
            WHERE id = '\(thread.uuidString)';
            """
        )
    }

    let collector = SessionCollector(
        codexHome: codexHome.resolvingSymlinksInPath(),
        store: store
    )
    _ = collector.scanOnceSync()
    let cards = try store.loadCards(includeArchived: true)
    let aborted = cards.first(where: { $0.id == abortThread })!
    check(aborted.state == .interrupted
            && aborted.responseLifecycle == .interrupted,
          "helper completed followed by real abort should repair interrupted")
    check(aborted.reportedState == .completed
            && aborted.summary == "helper completed report",
          "abort repair should preserve helper report metadata")
    let active = cards.first(where: { $0.id == activeThread })!
    check(active.state == .running
            && active.responseLifecycle == .running,
          "helper completed without response end should repair running")
    let read = cards.first(where: { $0.id == readThread })!
    check(read.state == .responseEnded
            && read.responseLifecycle == .completed,
          "late abort after task_complete should remain completed")
    check(!read.isCompletionUnread
            && read.completionRevision == 7,
          "legacy read completion should not become unread after duplicate complete")
}

run("legacy lifecycle repair tracks turn context and caches evidence-free tails") {
    let directory = try temporaryDirectory()
    let codexHome = directory.appendingPathComponent("turn-aware-repair", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/11/13", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sessions,
        withIntermediateDirectories: true
    )
    let database = directory.appendingPathComponent("turn-aware.sqlite3")
    let store = try StateStore(path: database.path)

    func writeFixture(
        name: String,
        lines: [Data]
    ) throws -> URL {
        let file = sessions.appendingPathComponent(name)
        try lines.reduce(Data()) {
            $0 + $1 + Data("\n".utf8)
        }.write(to: file)
        let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: nil
        )
        while let candidate = enumerator?.nextObject() as? URL {
            if candidate.lastPathComponent == name {
                return candidate
            }
        }
        return file
    }

    let previousAbortThread = UUID(
        uuidString: "FC1FC1FC-FC1F-4C1F-8C1F-FC1FC1FC1FC1"
    )!
    let completedThread = UUID(
        uuidString: "FC2FC2FC-FC2F-4C2F-8C2F-FC2FC2FC2FC2"
    )!
    let cachedThread = UUID(
        uuidString: "FC3FC3FC-FC3F-4C3F-8C3F-FC3FC3FC3FC3"
    )!

    let previousAbortFile = try writeFixture(
        name: "previous-abort.jsonl",
        lines: try [
            sessionMeta(
                id: previousAbortThread.uuidString,
                timestamp: "2026-11-13T15:00:00.000Z"
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T15:00:01.000Z",
                extra: ["turn_id": "previous"]
            ),
            event(
                "turn_aborted",
                timestamp: "2026-11-13T15:00:02.000Z",
                extra: ["reason": "interrupted"]
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T15:00:03.000Z",
                extra: ["turn_id": "current"]
            )
        ]
    )
    let completedFile = try writeFixture(
        name: "current-completed.jsonl",
        lines: try [
            sessionMeta(
                id: completedThread.uuidString,
                timestamp: "2026-11-13T15:01:00.000Z"
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T15:01:01.000Z",
                extra: ["turn_id": "previous"]
            ),
            event(
                "turn_aborted",
                timestamp: "2026-11-13T15:01:02.000Z",
                extra: ["reason": "interrupted"]
            ),
            jsonLine([
                "timestamp": "2026-11-13T15:01:03.000Z",
                "type": "turn_context",
                "payload": ["turn_id": "current", "model": "gpt-test"]
            ]),
            event(
                "task_complete",
                timestamp: "2026-11-13T15:01:04.000Z"
            ),
            event(
                "turn_aborted",
                timestamp: "2026-11-13T15:01:05.000Z",
                extra: ["reason": "interrupted"]
            )
        ]
    )
    let cachedFile = try writeFixture(
        name: "cached.jsonl",
        lines: try [
            sessionMeta(
                id: cachedThread.uuidString,
                timestamp: "2026-11-13T15:02:00.000Z"
            )
        ]
    )

    for (file, thread, turn) in [
        (previousAbortFile, previousAbortThread, "current"),
        (completedFile, completedThread, "current"),
        (cachedFile, cachedThread, "current")
    ] {
        let lines = try Data(contentsOf: file).split(separator: UInt8(ascii: "\n"))
            .map { Data($0) }
        let seed = lines.prefix(2).compactMap {
            SessionLineParser.parse($0, trustPolicy: testTrustPolicy)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        try store.ingest(
            records: seed,
            path: file.path,
            inode: (attributes[.systemFileNumber] as! NSNumber).int64Value,
            endOffset: (attributes[.size] as! NSNumber).int64Value
        )
        try executeSQL(
            path: database.path,
            sql: """
            UPDATE cards SET
              state = 'error',
              completed_at = NULL,
              payload = CAST(json_set(
                CAST(payload AS TEXT),
                '$.state', 'error',
                '$.responseLifecycle', NULL,
                '$.currentTurnId', '\(turn)'
              ) AS BLOB)
            WHERE id = '\(thread.uuidString)';
            """
        )
    }

    let collector = SessionCollector(
        codexHome: codexHome,
        store: store
    )
    _ = collector.scanOnceSync()
    let cards = try store.loadCards(includeArchived: true)
    let previousAbort = cards.first { $0.id == previousAbortThread }!
    check(previousAbort.state == .running
            && previousAbort.responseLifecycle == .running,
          "turn-less abort from the previous turn must not mark the current turn interrupted")
    let completed = cards.first { $0.id == completedThread }!
    check(completed.state == .responseEnded
            && completed.responseLifecycle == .completed,
          "turn_context must bind turn-less completion to the current turn: state=\(completed.state) lifecycle=\(String(describing: completed.responseLifecycle))")

    let cachedAttributes = try FileManager.default.attributesOfItem(
        atPath: cachedFile.path
    )
    let cachedSize = (cachedAttributes[.size] as! NSNumber).int64Value
    let cachedModified = cachedAttributes[.modificationDate] as! Date
    try check(
        try store.responseStateScanIsCurrent(
            path: cachedFile.path,
            cardId: cachedThread,
            turnId: "current",
            fileSize: cachedSize,
            modifiedAt: cachedModified
        ),
        "evidence-free tail scan should be cached by size and mtime: card=\(cards.first { $0.id == cachedThread }!.state)/\(String(describing: cards.first { $0.id == cachedThread }!.responseLifecycle))"
    )
    try check(
        try !store.responseStateScanIsCurrent(
            path: cachedFile.path,
            cardId: cachedThread,
            turnId: "current",
            fileSize: cachedSize + 1,
            modifiedAt: cachedModified
        ),
        "appended bytes must invalidate the cached tail scan"
    )
    try check(
        try !store.responseStateScanIsCurrent(
            path: cachedFile.path,
            cardId: cachedThread,
            turnId: "current",
            fileSize: cachedSize,
            modifiedAt: cachedModified.addingTimeInterval(1)
        ),
        "mtime change must invalidate the cached tail scan"
    )

    let appended = try event(
        "task_started",
        timestamp: "2026-11-13T15:03:00.000Z",
        extra: ["turn_id": "current"]
    )
    let handle = try FileHandle(forWritingTo: cachedFile)
    try handle.seekToEnd()
    try handle.write(contentsOf: appended + Data("\n".utf8))
    try handle.close()
    _ = collector.scanOnceSync()
    let reactivated = try store.loadCards(includeArchived: true)
        .first { $0.id == cachedThread }!
    check(reactivated.state == .running
            && reactivated.responseLifecycle == .running,
          "new tail evidence should be reparsed after the cached file changes")
}

run("identity repair preserves normal fields byte-for-byte") {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("identity-guard.sqlite3")
    let store = try StateStore(path: database.path)
    let thread = UUID(uuidString: "D0D0D0D0-D0D0-40D0-80D0-D0D0D0D0D0D0")!
    let path = "/tmp/identity-guard.jsonl"
    try ingest(
        try [
            sessionMeta(
                id: thread.uuidString,
                timestamp: "2026-11-13T07:00:00.000Z"
            ),
            event(
                "task_started",
                timestamp: "2026-11-13T07:00:01.000Z",
                extra: ["turn_id": "guard"]
            ),
            event(
                "user_message",
                timestamp: "2026-11-13T07:00:02.000Z",
                extra: ["message": "정상적인 고유 작업 이름"]
            )
        ],
        store: store,
        path: path
    )
    try executeSQL(
        path: database.path,
        sql: """
        UPDATE cards SET payload = CAST(json_set(
          CAST(payload AS TEXT),
          '$.currentRequest', NULL
        ) AS BLOB) WHERE id = '\(thread.uuidString)';
        """
    )
    let before = try store.loadCards(includeArchived: true).first!
    try store.repairTaskIdentity(
        cardId: thread,
        path: path,
        identity: TitleSanitizer.TaskIdentity(
            title: "Replacement must not apply",
            description: "Replacement description"
        ),
        contaminations: [
            TitleSanitizer.LegacyInjectionContamination(
                title: "Different injected title",
                description: "Different injected description"
            )
        ]
    )
    let after = try store.loadCards(includeArchived: true).first!
    check(after.title == before.title,
          "normal title should remain byte-for-byte unchanged")
    check(after.description == before.description,
          "normal description should remain byte-for-byte unchanged")
    check(after.currentRequest == nil,
          "repair should not fill an empty currentRequest from previous title")
}

run("identity repair prefix doubles after an incomplete scan") {
    let directory = try temporaryDirectory()
    let codexHome = directory.appendingPathComponent("large-repair-codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/11/13", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sessions,
        withIntermediateDirectories: true
    )
    let file = sessions.resolvingSymlinksInPath()
        .appendingPathComponent("rollout-large.jsonl")
    let thread = UUID(uuidString: "D1D1D1D1-D1D1-41D1-81D1-D1D1D1D1D1D1")!
    let headerLine = try sessionMeta(
        id: thread.uuidString,
        timestamp: "2026-11-13T08:00:00.000Z"
    )
    let taskLine = try event(
        "task_started",
        timestamp: "2026-11-13T08:00:01.000Z",
        extra: ["turn_id": "large"]
    )
    let injectedLine = try response(
        "message",
        timestamp: "2026-11-13T08:00:02.000Z",
        payload: [
            "role": "user",
            "content": [[
                "type": "input_text",
                "text": "# AGENTS.md instructions for /tmp/project\n<INSTRUCTIONS>\n## GitHub PR 생성 규칙\nbody\n</INSTRUCTIONS>"
            ]]
        ]
    )
    let paddingObject: [String: Any] = [
        "timestamp": "2026-11-13T08:00:03.000Z",
        "type": "world_state",
        "payload": ["blob": String(repeating: "x", count: 1_100_000)]
    ]
    let paddingLine = try jsonLine(paddingObject)
    let actualLine = try response(
        "message",
        timestamp: "2026-11-13T08:00:04.000Z",
        payload: [
            "role": "user",
            "content": [[
                "type": "input_text",
                "text": "대용량 prefix 이후에 위치한 실제 사용자 요청"
            ]]
        ]
    )
    let data = [headerLine, taskLine, injectedLine, paddingLine, actualLine]
        .reduce(Data()) { $0 + $1 + Data("\n".utf8) }
    try data.write(to: file)
    let fileEnumerator = FileManager.default.enumerator(
        at: codexHome,
        includingPropertiesForKeys: nil
    )
    var collectorFile: URL?
    while let candidate = fileEnumerator?.nextObject() as? URL {
        if candidate.pathExtension == "jsonl" {
            collectorFile = candidate
            break
        }
    }
    guard let collectorFile else {
        check(false, "large repair fixture file should be enumerable")
        return
    }
    let database = directory.appendingPathComponent("large-repair.sqlite3")
    let store = try StateStore(path: database.path)
    let attributes = try FileManager.default.attributesOfItem(
        atPath: collectorFile.path
    )
    let inode = (attributes[.systemFileNumber] as! NSNumber).int64Value
    let size = (attributes[.size] as! NSNumber).int64Value
    let records = [headerLine, taskLine].compactMap {
        SessionLineParser.parse($0, trustPolicy: testTrustPolicy)
    }
    try store.ingest(
        records: records,
        path: collectorFile.path,
        inode: inode,
        endOffset: size
    )
    let seededCursor = try store.cursor(path: collectorFile.path)
    check(
        seededCursor?.offset == size,
        "large repair fixture cursor should start at EOF"
    )
    check(
        seededCursor?.context.header?.provider == .openai,
        "large repair fixture cursor should retain supported provider"
    )
    try executeSQL(
        path: database.path,
        sql: """
        UPDATE cards SET payload = CAST(json_set(
          CAST(payload AS TEXT),
          '$.title', 'GitHub PR 생성 규칙',
          '$.description', '## GitHub PR 생성 규칙\nbody',
          '$.taskIdentityCaptured', json('true')
        ) AS BLOB) WHERE id = '\(thread.uuidString)';
        """
    )
    let collector = SessionCollector(
        codexHome: codexHome.resolvingSymlinksInPath(),
        store: store
    )
    let firstRepairScan = collector.scanOnceSync()
    var progress = try store.identityRepairProgress(
        path: collectorFile.path,
        cardId: thread
    )
    check(!progress.isComplete && progress.searchedBytes >= 1_024 * 1_024,
          "first repair scan should persist incomplete 1MiB progress: \(progress) file=\(size) files=\(firstRepairScan.filesScanned) errors=\(firstRepairScan.errors)")
    try check(try store.loadCards(includeArchived: true).first?.title
            == "GitHub PR 생성 규칙",
          "incomplete scan must not mark or alter repaired identity")

    _ = collector.scanOnceSync()
    progress = try store.identityRepairProgress(
        path: collectorFile.path,
        cardId: thread
    )
    check(progress.isComplete,
          "second scan should extend prefix and complete repair: \(progress)")
    try check(try store.loadCards(includeArchived: true).first?.title
            == "대용량 prefix 이후에 위치한 실제 사용자 요청",
          "extended prefix should recover real prompt beyond 1MiB: \(String(reflecting: try store.loadCards(includeArchived: true).first?.title))")
}

run("identity repair retries after a later user prompt append") {
    let directory = try temporaryDirectory()
    let codexHome = directory.appendingPathComponent("append-repair-codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/11/13", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sessions,
        withIntermediateDirectories: true
    )
    let fileURL = sessions.appendingPathComponent("rollout-append.jsonl")
    let thread = UUID(uuidString: "D2D2D2D2-D2D2-42D2-82D2-D2D2D2D2D2D2")!
    let headerLine = try sessionMeta(
        id: thread.uuidString,
        timestamp: "2026-11-13T09:00:00.000Z"
    )
    let taskLine = try event(
        "task_started",
        timestamp: "2026-11-13T09:00:01.000Z",
        extra: ["turn_id": "append"]
    )
    let injectedLine = try response(
        "message",
        timestamp: "2026-11-13T09:00:02.000Z",
        payload: [
            "role": "user",
            "content": [[
                "type": "input_text",
                "text": "# AGENTS.md instructions for /tmp/project\n<INSTRUCTIONS>\n## GitHub PR 생성 규칙\nbody only\n</INSTRUCTIONS>"
            ]]
        ]
    )
    try [headerLine, taskLine, injectedLine]
        .reduce(Data()) { $0 + $1 + Data("\n".utf8) }
        .write(to: fileURL)
    let enumerator = FileManager.default.enumerator(
        at: codexHome,
        includingPropertiesForKeys: nil
    )
    var collectorFile: URL?
    while let candidate = enumerator?.nextObject() as? URL {
        if candidate.pathExtension == "jsonl" {
            collectorFile = candidate
            break
        }
    }
    guard let collectorFile else {
        check(false, "append repair fixture file should be enumerable")
        return
    }
    let database = directory.appendingPathComponent("append-repair.sqlite3")
    let store = try StateStore(path: database.path)
    let attributes = try FileManager.default.attributesOfItem(
        atPath: collectorFile.path
    )
    let inode = (attributes[.systemFileNumber] as! NSNumber).int64Value
    let initialSize = (attributes[.size] as! NSNumber).int64Value
    let seededRecords = [headerLine, taskLine].compactMap {
        SessionLineParser.parse($0, trustPolicy: testTrustPolicy)
    }
    try store.ingest(
        records: seededRecords,
        path: collectorFile.path,
        inode: inode,
        endOffset: initialSize
    )
    try executeSQL(
        path: database.path,
        sql: """
        UPDATE cards SET payload = CAST(json_set(
          CAST(payload AS TEXT),
          '$.title', 'GitHub PR 생성 규칙',
          '$.description', '## GitHub PR 생성 규칙\nbody only',
          '$.taskIdentityCaptured', json('true')
        ) AS BLOB) WHERE id = '\(thread.uuidString)';
        """
    )
    let collector = SessionCollector(
        codexHome: codexHome.resolvingSymlinksInPath(),
        store: store
    )
    _ = collector.scanOnceSync()
    var progress = try store.identityRepairProgress(
        path: collectorFile.path,
        cardId: thread
    )
    check(!progress.isComplete && progress.searchedBytes == initialSize,
          "instructions-only scan should remain incomplete at current EOF")
    _ = collector.scanOnceSync()
    let unchangedProgress = try store.identityRepairProgress(
        path: collectorFile.path,
        cardId: thread
    )
    check(unchangedProgress == progress,
          "unchanged file should skip bounded repair reread")

    let actualLine = try response(
        "message",
        timestamp: "2026-11-13T09:01:00.000Z",
        payload: [
            "role": "user",
            "content": [[
                "type": "input_text",
                "text": "나중에 append된 실제 사용자 요청"
            ]]
        ]
    )
    try append(actualLine + Data("\n".utf8), to: collectorFile)
    _ = collector.scanOnceSync()
    progress = try store.identityRepairProgress(
        path: collectorFile.path,
        cardId: thread
    )
    check(progress.isComplete,
          "later append should allow incomplete repair to finish")
    try check(try store.loadCards(includeArchived: true).first?.title
            == "나중에 append된 실제 사용자 요청",
          "later appended real prompt should repair contaminated identity")
}

run("completion unread persists, clears on read and reacts only to genuine transitions") {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("unread.sqlite3")
    let store = try StateStore(path: database.path)
    let thread = UUID(uuidString: "B3B3B3B3-B3B3-43B3-83B3-B3B3B3B3B3B3")!
    let base = try [
        sessionMeta(id: thread.uuidString, timestamp: "2026-11-13T03:00:00.000Z"),
        event(
            "task_started",
            timestamp: "2026-11-13T03:00:01.000Z",
            extra: ["turn_id": "one"]
        )
    ]
    try ingest(base, store: store, path: "/tmp/unread.jsonl")
    let firstReport = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "B4B4B4B4-B4B4-44B4-84B4-B4B4B4B4B4B4")!,
        timestamp: AgentBoardDate.parse("2026-11-13T03:00:02.000Z")!,
        state: .completed,
        steps: [ReportStep(id: "done", title: "완료", status: .completed)],
        summary: "완료됨"
    )
    try ingest(
        [
            try callLine(
                callId: "first",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-13T03:00:01.500Z"
            ),
            try outputLine(
                callId: "first",
                output: try reportMarker(firstReport),
                timestamp: "2026-11-13T03:00:02.000Z"
            )
        ],
        store: store,
        path: "/tmp/unread.jsonl"
    )
    try check(
        try store.loadCards().first?.state == .running
            && store.loadCards().first?.reportedState == .completed,
        "structured completed before response end must not finish lifecycle"
    )
    try check(try store.loadCards().first?.isCompletionUnread == false,
          "report completion alone must not create completion unread")
    try ingest(
        [
            try event(
                "task_complete",
                timestamp: "2026-11-13T03:00:02.500Z",
                extra: ["turn_id": "one"]
            )
        ],
        store: store,
        path: "/tmp/unread.jsonl"
    )
    try check(try store.loadCards().first?.isCompletionUnread == true,
          "normal response end should create unread completion")
    try store.markCompletionRead(cardId: thread)
    let reopened = try StateStore(path: database.path)
    try check(try reopened.loadCards().first?.isCompletionUnread == false,
          "read state should survive reopen")

    let repeatedReport = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "B4B4B4B4-B4B4-44B4-84B4-B4B4B4B4B4B5")!,
        timestamp: AgentBoardDate.parse("2026-11-13T03:00:02.300Z")!,
        state: .completed,
        steps: [ReportStep(id: "done", title: "완료", status: .completed)],
        summary: "반복 완료 보고"
    )
    try ingest(
        [
            try callLine(
                callId: "repeat",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: "2026-11-13T03:00:02.200Z"
            ),
            try outputLine(
                callId: "repeat",
                output: try reportMarker(repeatedReport),
                timestamp: "2026-11-13T03:00:02.300Z"
            )
        ],
        store: store,
        path: "/tmp/unread.jsonl"
    )
    try check(
        try store.loadCards().first?.isCompletionUnread == false,
        "repeated completed report must not re-trigger unread"
    )

    try ingest(
        [
            try event(
                "task_complete",
                timestamp: "2026-11-13T03:00:03.000Z",
                extra: ["turn_id": "one"]
            )
        ],
        store: store,
        path: "/tmp/unread.jsonl"
    )
    try check(try store.loadCards().first?.isCompletionUnread == false,
          "duplicate task_complete after response end must not re-trigger unread")

    try ingest(
        [
            try event(
                "task_started",
                timestamp: "2026-11-13T03:01:00.000Z",
                extra: ["turn_id": "two"]
            )
        ],
        store: store,
        path: "/tmp/unread.jsonl"
    )
    try check(try store.loadCards().first?.isCompletionUnread == false,
          "new turn should clear old completion unread")
    try ingest(
        [
            try event(
                "task_complete",
                timestamp: "2026-11-13T03:02:00.000Z",
                extra: ["turn_id": "two"]
            )
        ],
        store: store,
        path: "/tmp/unread.jsonl"
    )
    try check(try store.loadCards().first?.isCompletionUnread == true,
          "new response-ended terminal should become unread")

    var historical = AgentCard(
        id: UUID(),
        provider: .openai,
        title: "Historical",
        cwd: nil,
        state: .running,
        completionUnread: false
    )
    SessionReducer.applyReport(
        try reportEnvelope(
            threadId: historical.id,
            eventId: UUID(),
            timestamp: Date(),
            state: .completed,
            summary: "Historical replay"
        ),
        to: &historical,
        isHistoricalReplay: true
    )
    check(!historical.isCompletionUnread, "historical replay must not create unread badge")
}

run("fresh work auto-unhides while historical tails and activity do not") {
    let thread = UUID(uuidString: "B5B5B5B5-B5B5-45B5-85B5-B5B5B5B5B5B5")!
    let now = Date()
    let header = SessionHeader(
        id: thread,
        source: "cli",
        cwd: "/tmp/unhide",
        modelProvider: "openai",
        cliVersion: "0.167.1",
        historyMode: "paginated"
    )
    var archived = AgentCard(
        id: thread,
        provider: .openai,
        title: "Archived task",
        cwd: "/tmp/unhide",
        state: .responseEnded,
        lastEventAt: now,
        archived: true,
        archivedAt: now
    )
    let historical = SessionReducer.reduce(
        records: [
            ParsedRecord(
                timestamp: now.addingTimeInterval(-10),
                signal: .taskStarted(turnId: "old")
            ),
            ParsedRecord(
                timestamp: now.addingTimeInterval(-9),
                signal: .taskComplete(turnId: "old")
            ),
            ParsedRecord(
                timestamp: now.addingTimeInterval(-8),
                signal: .activity
            )
        ],
        card: archived,
        cursor: CursorContext(header: header),
        seenEventIds: []
    )
    archived = historical.card!
    check(archived.archived, "historical activity must not unhide archived card")

    let fresh = SessionReducer.reduce(
        records: [
            ParsedRecord(
                timestamp: now.addingTimeInterval(10),
                signal: .taskStarted(turnId: "fresh")
            )
        ],
        card: archived,
        cursor: historical.cursor,
        seenEventIds: []
    )
    check(!fresh.card!.archived, "genuine fresh task should auto-unhide")
    check(fresh.card!.archivedAt == nil, "auto-unhide should clear archive boundary")

    var reportUnhide = archived
    SessionReducer.applyReport(
        try reportEnvelope(
            threadId: thread,
            eventId: UUID(),
            timestamp: now.addingTimeInterval(20),
            state: .running,
            summary: "Fresh running report"
        ),
        to: &reportUnhide
    )
    check(!reportUnhide.archived, "fresh running report should auto-unhide")
}

run("turn boundaries ignore preambles and equal-timestamp duplicates") {
    let thread = UUID(uuidString: "CA1CA1CA-CA1C-4A1C-8A1C-CA1CA1CA1CA1")!
    let now = Date()
    let header = SessionHeader(
        id: thread,
        source: "cli",
        cwd: "/tmp/boundary",
        modelProvider: "openai",
        cliVersion: "0.167.1",
        historyMode: "paginated"
    )
    var card = AgentCard(
        id: thread,
        provider: .openai,
        title: "Boundary task",
        cwd: "/tmp/boundary",
        state: .responseEnded,
        startedAt: now,
        lastEventAt: now,
        currentTurnId: "t2",
        archived: true,
        archivedAt: now,
        completionUnread: true
    )

    let duplicate = SessionReducer.reduce(
        records: [
            ParsedRecord(timestamp: now, signal: .taskStarted(turnId: "t2")),
            ParsedRecord(timestamp: now, signal: .taskComplete(turnId: "t2"))
        ],
        card: card,
        cursor: CursorContext(header: header),
        seenEventIds: [],
        unreadBaseline: now.addingTimeInterval(-100)
    )
    card = duplicate.card!
    check(card.state == .responseEnded, "duplicate same-turn task_started must not reactivate")
    check(card.isCompletionUnread, "equal timestamp duplicate must not re-trigger unread")
    check(card.archived, "equal archive boundary timestamp must not unhide")

    let preamble = SessionReducer.reduce(
        records: [
            ParsedRecord(
                timestamp: now.addingTimeInterval(1),
                signal: .userMessage(
                    text: "# AGENTS.md instructions\n<INSTRUCTIONS>setup only</INSTRUCTIONS>",
                    turnId: nil
                )
            )
        ],
        card: card,
        cursor: duplicate.cursor,
        seenEventIds: []
    )
    card = preamble.card!
    check(card.archived, "context preamble must not unhide")
    check(card.state == .responseEnded, "context preamble must not reset state")

    let resumed = SessionReducer.reduce(
        records: [
            ParsedRecord(
                timestamp: now.addingTimeInterval(2),
                signal: .userMessage(
                    text: "Fresh work without a turn id",
                    turnId: nil
                )
            )
        ],
        card: card,
        cursor: preamble.cursor,
        seenEventIds: []
    )
    card = resumed.card!
    check(
        card.state == .running,
        "fresh unidentified user work must become running: \(card.state)"
    )
    check(
        !card.archived,
        "fresh unidentified user work must unhide: archive=\(card.archivedAt?.timeIntervalSince1970 ?? -1) resume=\(now.addingTimeInterval(2).timeIntervalSince1970)"
    )
    check(
        !card.isCompletionUnread,
        "fresh work must clear previous unread completion: \(String(describing: card.completionUnread))"
    )
}

run("stale report output cannot regress newer card state") {
    let thread = UUID(uuidString: "CB1CB1CB-CB1C-4B1C-8B1C-CB1CB1CB1CB1")!
    let now = Date()
    let header = SessionHeader(
        id: thread,
        source: "cli",
        cwd: "/tmp/stale-report",
        modelProvider: "openai",
        cliVersion: "0.167.1",
        historyMode: "paginated"
    )
    var card = AgentCard(
        id: thread,
        provider: .openai,
        title: "Newer state",
        cwd: "/tmp/stale-report",
        state: .waiting,
        lastEventAt: now,
        currentTurnId: "current",
        completionUnread: false
    )
    let staleReport = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "CB2CB2CB-CB2C-4B2C-8B2C-CB2CB2CB2CB2")!,
        timestamp: now.addingTimeInterval(-10),
        state: .completed,
        summary: "Old report"
    )
    let pending = PendingReportCall(
        createdAt: now.addingTimeInterval(-20),
        turnId: "current"
    )
    var cursor = CursorContext(
        header: header,
        pendingCalls: ["stale": pending]
    )
    let result = SessionReducer.reduce(
        records: [
            ParsedRecord(
                timestamp: now.addingTimeInterval(-5),
                signal: .toolOutput(
                    callId: "stale",
                    text: try reportMarker(staleReport)
                )
            )
        ],
        card: card,
        cursor: cursor,
        seenEventIds: []
    )
    card = result.card!
    cursor = result.cursor
    check(card.state == .waiting, "stale report output must not regress state")
    check(!card.isCompletionUnread, "stale report output must not create unread")
    check(cursor.pendingCalls.isEmpty, "stale output should consume its pending call")
}

run("first upgrade baselines historical completions without unread badges") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("baseline.sqlite3").path)
    let thread = UUID(uuidString: "B7B7B7B7-B7B7-47B7-87B7-B7B7B7B7B7B7")!
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let path = "/tmp/unread-baseline.jsonl"
    try ingest(
        try [
            sessionMeta(id: thread.uuidString, timestamp: AgentBoardDate.string(old)),
            event(
                "task_started",
                timestamp: AgentBoardDate.string(old.addingTimeInterval(1)),
                extra: ["turn_id": "historical"]
            ),
            callLine(
                callId: "historical",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: AgentBoardDate.string(old.addingTimeInterval(2))
            ),
            outputLine(
                callId: "historical",
                output: try reportMarker(
                    reportEnvelope(
                        threadId: thread,
                        eventId: UUID(uuidString: "B8B8B8B8-B8B8-48B8-88B8-B8B8B8B8B8B8")!,
                        timestamp: old.addingTimeInterval(3),
                        state: .completed,
                        summary: "Historical completion"
                    )
                ),
                timestamp: AgentBoardDate.string(old.addingTimeInterval(3))
            )
        ],
        store: store,
        path: path
    )
    try check(
        try store.loadCards().first?.isCompletionUnread == false,
        "pre-upgrade historical completion should baseline as read"
    )

    let fresh = Date().addingTimeInterval(5)
    try ingest(
        [
            try event(
                "task_started",
                timestamp: AgentBoardDate.string(fresh),
                extra: ["turn_id": "live"]
            ),
            try event(
                "task_complete",
                timestamp: AgentBoardDate.string(fresh.addingTimeInterval(1)),
                extra: ["turn_id": "live"]
            )
        ],
        store: store,
        path: path
    )
    try check(
        try store.loadCards().first?.isCompletionUnread == true,
        "completion after baseline should still become unread"
    )
}

run("status filters group responseEnded as completed and separate stale attention") {
    let now = Date()
    let ended = AgentCard(
        id: UUID(),
        provider: .openai,
        title: "Ended",
        cwd: nil,
        state: .responseEnded,
        lastEventAt: now
    )
    let stale = AgentCard(
        id: UUID(),
        provider: .deepseek,
        title: "Stale",
        cwd: nil,
        state: .running,
        lastEventAt: now.addingTimeInterval(-100)
    )
    check(BoardStatusFilter.completed.includes(ended, now: now),
          "responseEnded should belong to completed tab")
    check(BoardStatusFilter.attention.includes(stale, now: now),
          "stale running should belong to attention tab")
    check(!BoardStatusFilter.running.includes(stale, now: now),
          "stale running should not count as running")
}

run("auto-unhide persists through archive preference transaction") {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("unhide.sqlite3")
    let store = try StateStore(path: database.path)
    let thread = UUID(uuidString: "B6B6B6B6-B6B6-46B6-86B6-B6B6B6B6B6B6")!
    let initial = Date().addingTimeInterval(-30)
    let path = "/tmp/persistent-unhide.jsonl"
    try ingest(
        try [
            sessionMeta(
                id: thread.uuidString,
                timestamp: AgentBoardDate.string(initial)
            ),
            event(
                "task_started",
                timestamp: AgentBoardDate.string(initial.addingTimeInterval(1)),
                extra: ["turn_id": "one"]
            ),
            event(
                "task_complete",
                timestamp: AgentBoardDate.string(initial.addingTimeInterval(2)),
                extra: ["turn_id": "one"]
            )
        ],
        store: store,
        path: path
    )
    try store.setArchived(cardId: thread, archived: true)
    try ingest(
        [
            try event(
                "token_count",
                timestamp: AgentBoardDate.string(initial.addingTimeInterval(3))
            )
        ],
        store: store,
        path: path
    )
    try check(
        try store.loadCards(includeArchived: true).first?.archived == true,
        "historical token activity must not unhide"
    )

    let fresh = Date().addingTimeInterval(10)
    try ingest(
        [
            try event(
                "user_message",
                timestamp: AgentBoardDate.string(fresh),
                extra: ["message": "A genuinely new follow-up request"]
            )
        ],
        store: store,
        path: path
    )
    try check(
        try store.loadCards(includeArchived: true).first?.archived == false,
        "fresh user task without turn id should auto-unhide"
    )
    try ingest(
        [
            try event(
                "token_count",
                timestamp: AgentBoardDate.string(fresh.addingTimeInterval(1))
            )
        ],
        store: store,
        path: path
    )
    try store.setArchived(cardId: thread, archived: true)
    let runningReport = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "B9B9B9B9-B9B9-49B9-89B9-B9B9B9B9B9B9")!,
        timestamp: fresh.addingTimeInterval(20),
        state: .running,
        summary: "Fresh running report"
    )
    try ingest(
        [
            try callLine(
                callId: "running-report",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: AgentBoardDate.string(fresh.addingTimeInterval(19))
            ),
            try outputLine(
                callId: "running-report",
                output: try reportMarker(runningReport),
                timestamp: AgentBoardDate.string(fresh.addingTimeInterval(20))
            )
        ],
        store: store,
        path: path
    )
    let reopened = try StateStore(path: database.path)
    try check(
        try reopened.loadCards(includeArchived: true).first?.archived == false,
        "fresh running report must update persisted archive preference"
    )
}

run("legacy archive preference derives boundary from updated_at") {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("legacy-archive.sqlite3")
    let thread = UUID(uuidString: "CC1CC1CC-CC1C-4C1C-8C1C-CC1CC1CC1CC1")!
    let path = "/tmp/legacy-archive.jsonl"
    let initial = Date().addingTimeInterval(-100)
    do {
        let store = try StateStore(path: database.path)
        try ingest(
            try [
                sessionMeta(
                    id: thread.uuidString,
                    timestamp: AgentBoardDate.string(initial)
                ),
                event(
                    "task_started",
                    timestamp: AgentBoardDate.string(initial.addingTimeInterval(1)),
                    extra: ["turn_id": "legacy"]
                ),
                event(
                    "task_complete",
                    timestamp: AgentBoardDate.string(initial.addingTimeInterval(2)),
                    extra: ["turn_id": "legacy"]
                )
            ],
            store: store,
            path: path
        )
        try store.setArchived(cardId: thread, archived: true)
    }
    try executeSQL(
        path: database.path,
        sql: """
        UPDATE card_preferences SET archived_at = NULL WHERE card_id = '\(thread.uuidString)';
        UPDATE cards
        SET payload = CAST(json_remove(CAST(payload AS TEXT), '$.archivedAt') AS BLOB)
        WHERE id = '\(thread.uuidString)';
        """
    )
    let reopened = try StateStore(path: database.path)
    var card = try reopened.loadCards(includeArchived: true).first!
    check(card.archivedAt != nil, "NULL legacy boundary should migrate from updated_at")
    check(card.archived, "legacy preference should begin archived")
    let boundary = card.archivedAt!
    let running = try reportEnvelope(
        threadId: thread,
        eventId: UUID(uuidString: "CC2CC2CC-CC2C-4C2C-8C2C-CC2CC2CC2CC2")!,
        timestamp: boundary,
        state: .running,
        summary: "Boundary report"
    )
    try ingest(
        [
            try callLine(
                callId: "boundary",
                command: "/Users/me/.local/bin/agentboard report --json '{}'",
                timestamp: AgentBoardDate.string(boundary.addingTimeInterval(-1))
            ),
            try outputLine(
                callId: "boundary",
                output: try reportMarker(running),
                timestamp: AgentBoardDate.string(boundary)
            )
        ],
        store: reopened,
        path: path
    )
    card = try reopened.loadCards(includeArchived: true).first!
    check(
        card.archived,
        "equal archived_at timestamp must not unhide legacy card: boundary=\(boundary.timeIntervalSince1970) archive=\(card.archivedAt?.timeIntervalSince1970 ?? -1)"
    )
}

run("batch completion confirmation is terminal-only and snapshot-bounded") {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("batch-read.sqlite3")
    let store = try StateStore(path: database.path)
    let first = UUID(uuidString: "CD1CD1CD-CD1C-4D1C-8D1C-CD1CD1CD1CD1")!
    let second = UUID(uuidString: "CD2CD2CD-CD2C-4D2C-8D2C-CD2CD2CD2CD2")!
    let running = UUID(uuidString: "CD3CD3CD-CD3C-4D3C-8D3C-CD3CD3CD3CD3")!

    func makeCard(_ id: UUID, suffix: String, complete: Bool) throws {
        let start = Date().addingTimeInterval(10)
        var lines = try [
            sessionMeta(
                id: id.uuidString,
                timestamp: AgentBoardDate.string(start)
            ),
            event(
                "task_started",
                timestamp: AgentBoardDate.string(start.addingTimeInterval(1)),
                extra: ["turn_id": suffix]
            )
        ]
        if complete {
            lines.append(
                try event(
                    "task_complete",
                    timestamp: AgentBoardDate.string(start.addingTimeInterval(2)),
                    extra: ["turn_id": suffix]
                )
            )
        }
        try ingest(
            lines,
            store: store,
            path: "/tmp/batch-\(suffix).jsonl",
            inode: Int64(suffix.count + 10)
        )
    }

    try makeCard(first, suffix: "first", complete: true)
    try makeCard(second, suffix: "second", complete: true)
    try makeCard(running, suffix: "running", complete: false)
    try store.markCompletionsRead(cardIds: [first, running])
    var cards = try store.loadCards(includeArchived: true)
    check(
        cards.first(where: { $0.id == first })?.isCompletionUnread == false,
        "batch confirmation should read requested terminal card"
    )
    check(
        cards.first(where: { $0.id == second })?.isCompletionUnread == true,
        "batch confirmation should ignore terminal cards outside snapshot"
    )
    check(
        cards.first(where: { $0.id == running })?.state == .running,
        "batch confirmation must not mutate running cards"
    )

    let arriving = UUID(uuidString: "CD4CD4CD-CD4C-4D4C-8D4C-CD4CD4CD4CD4")!
    try makeCard(arriving, suffix: "arriving", complete: true)
    let reopened = try StateStore(path: database.path)
    cards = try reopened.loadCards(includeArchived: true)
    check(
        cards.first(where: { $0.id == arriving })?.isCompletionUnread == true,
        "completion arriving after bulk snapshot should remain unread"
    )
    check(
        cards.first(where: { $0.id == first })?.isCompletionUnread == false,
        "batch read state should persist across restart"
    )
}

run("completion acknowledgement revision prevents stale bulk reads") {
    let directory = try temporaryDirectory()
    let store = try StateStore(path: directory.appendingPathComponent("revision.sqlite3").path)
    let thread = UUID(uuidString: "CE1CE1CE-CE1C-4E1C-8E1C-CE1CE1CE1CE1")!
    let path = "/tmp/revision-read.jsonl"
    let start = Date().addingTimeInterval(5)
    try ingest(
        try [
            sessionMeta(
                id: thread.uuidString,
                timestamp: AgentBoardDate.string(start)
            ),
            event(
                "task_started",
                timestamp: AgentBoardDate.string(start.addingTimeInterval(1)),
                extra: ["turn_id": "one"]
            ),
            event(
                "task_complete",
                timestamp: AgentBoardDate.string(start.addingTimeInterval(2)),
                extra: ["turn_id": "one"]
            )
        ],
        store: store,
        path: path
    )
    var card = try store.loadCards(includeArchived: true).first!
    let firstRevision = card.completionRevision ?? 0
    check(card.isCompletionUnread, "first terminal transition should be unread")
    try store.acknowledgeCompletions([
        CompletionAcknowledgement(
            cardId: thread,
            revision: firstRevision
        )
    ])
    try check(
        try store.loadCards(includeArchived: true).first?.isCompletionUnread == false,
        "matching revision should acknowledge completion"
    )

    try ingest(
        try [
            event(
                "task_started",
                timestamp: AgentBoardDate.string(start.addingTimeInterval(3)),
                extra: ["turn_id": "two"]
            ),
            event(
                "task_complete",
                timestamp: AgentBoardDate.string(start.addingTimeInterval(4)),
                extra: ["turn_id": "two"]
            )
        ],
        store: store,
        path: path
    )
    card = try store.loadCards(includeArchived: true).first!
    check((card.completionRevision ?? 0) > firstRevision,
          "later completion should advance revision")
    check(card.isCompletionUnread, "later completion should be unread")
    try store.acknowledgeCompletions([
        CompletionAcknowledgement(
            cardId: thread,
            revision: firstRevision
        )
    ])
    try check(
        try store.loadCards(includeArchived: true).first?.isCompletionUnread == true,
        "stale bulk revision must not acknowledge a later completion"
    )
}

if failures.isEmpty {
    print("PASS \(totalChecks) checks")
    exit(0)
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    print("FAILED \(failures.count)/\(totalChecks) checks")
    exit(1)
}
