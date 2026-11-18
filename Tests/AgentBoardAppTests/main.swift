import AgentBoardCore
import Darwin
import Foundation

private var checks = 0
private var failures: [String] = []

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() {
        failures.append(message)
    }
}

let suiteName = "app.agentboard.tests.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suiteName) else {
    fatalError("test defaults suite unavailable")
}
defer { defaults.removePersistentDomain(forName: suiteName) }
defaults.set(false, forKey: "AgentBoard.pinned")

let model = BoardViewModel.demo(defaults: defaults)
check(model.pinned == false, "demo should use injected preference suite")
check(model.allCount == 4, "default all tab count should include all visible cards")
check(model.completionSoundEnabled, "completion sound should default on")
model.completionSoundEnabled = false
check(
    defaults.object(forKey: "AgentBoard.completionSoundEnabled") as? Bool
        == false,
    "completion sound preference should persist"
)
model.completionSoundEnabled = true

let first = model.displayedCards[0]
let second = model.displayedCards[1]
model.toggleExpanded(first.id)
model.toggleExpanded(second.id)
check(model.expandedIds.count == 2, "multiple cards should stay expanded")
check(model.expandedIds.contains(first.id), "first expanded card should remain")
check(model.expandedIds.contains(second.id), "second expanded card should be added")
check(model.displayedCards.prefix(2).map(\.id) == [first.id, second.id],
      "expanding another card should not reorder existing cards")
check(model.statusFilter == .all, "default status tab should include all cards")
check(model.completedCount == 2, "responseEnded and completed should share completed tab")
check(model.unreadCompletedCount == 2, "demo should expose two unread completions")

model.archive(first.id)
check(model.archivedCards.contains(where: { $0.id == first.id }),
      "demo archive should move a card into hidden history")
check(model.allCount == 3, "tab counts should exclude hidden cards")
check(!model.expandedIds.contains(first.id), "archived card should close")
model.restore(first.id)
check(!model.archivedCards.contains(where: { $0.id == first.id }),
      "demo restore should make the card reversible")
check(model.allCount == 4, "restored card should return to tab counts")

model.statusFilter = .completed
check(model.displayedCards.allSatisfy(\.isTerminal),
      "completed tab should contain only terminal cards")
let unreadCard = model.displayedCards.first(where: \.isCompletionUnread)
if let unreadCard {
    let expandedBefore = model.expandedIds
    model.confirmCompletion(unreadCard.id)
    check(!model.cards.first(where: { $0.id == unreadCard.id })!.isCompletionUnread,
          "independent confirm action should clear unread badge")
    check(model.expandedIds == expandedBefore,
          "individual confirmation must not expand or collapse cards")
}
check(model.unreadCompletedCount == 1, "single confirmation should clear only one card")

model.showAllHistory = true
check(model.showAllHistory, "all-history mode should toggle")

let titleTarget = model.displayedCards.first!
let titleSource = titleTarget.title
let titleState = titleTarget.state
let titleUnread = titleTarget.isCompletionUnread
let expandedBeforeTitle = model.expandedIds
try model.setCustomTitle("  사용자 지정 카드 제목  ", for: titleTarget.id)
let titleUpdated = model.cards.first(where: { $0.id == titleTarget.id })!
check(titleUpdated.displayTitle == "사용자 지정 카드 제목",
      "view model should expose custom display title")
check(titleUpdated.title == titleSource,
      "custom title should preserve source title")
check(model.expandedIds == expandedBeforeTitle,
      "title edit should not alter expansion set")
check(titleUpdated.state == titleState && titleUpdated.isCompletionUnread == titleUnread,
      "title edit should not alter lifecycle/read state")
try model.setCustomTitle(nil, for: titleTarget.id)
check(model.cards.first(where: { $0.id == titleTarget.id })?.displayTitle
        == titleSource,
      "reset should restore source title in view model")

let bulkModel = BoardViewModel.demo(defaults: defaults)
let runningCard = bulkModel.displayedCards.first(where: { $0.state == .running })
if let runningCard {
    bulkModel.toggleExpanded(runningCard.id)
}
bulkModel.statusFilter = .completed
let unreadTerminalCards = bulkModel.displayedCards.filter(\.isCompletionUnread)
check(unreadTerminalCards.count == 2, "bulk fixture should begin with two unread cards")
bulkModel.archive(unreadTerminalCards[0].id)
check(bulkModel.unreadCompletedCount == 1,
      "hidden unread card should be excluded from visible bulk scope")
let expandedBeforeBulk = bulkModel.expandedIds
check(!expandedBeforeBulk.isEmpty, "bulk confirmation test should have an expanded card")
let nonTerminalStatesBeforeBulk = Dictionary(
    uniqueKeysWithValues: bulkModel.cards
        .filter { !$0.isTerminal }
        .map { ($0.id, $0.state) }
)
bulkModel.statusFilter = .running
check(
    !bulkModel.displayedCards.contains(where: \.isTerminal),
    "cross-tab bulk scope check should run while completion cards are outside the current tab"
)
check(
    bulkModel.unreadCompletedCount == 1,
    "bulk count should retain visible completion scope on non-completed tabs"
)
bulkModel.confirmVisibleCompletions()
check(bulkModel.unreadCompletedCount == 0,
      "bulk confirmation should clear current-history unread completions from any status tab")
check(bulkModel.expandedIds == expandedBeforeBulk,
      "bulk confirmation must preserve expansion set")
check(
    Dictionary(
        uniqueKeysWithValues: bulkModel.cards
            .filter { !$0.isTerminal }
            .map { ($0.id, $0.state) }
    ) == nonTerminalStatesBeforeBulk,
    "bulk confirmation must not alter running or attention card states"
)
check(
    bulkModel.cards.first(where: { $0.id == unreadTerminalCards[0].id })?
        .isCompletionUnread == true,
    "bulk confirmation must leave hidden cards untouched"
)

let reorderSuite = "app.agentboard.reorder.\(UUID().uuidString)"
let reorderDefaults = UserDefaults(suiteName: reorderSuite)!
defer { reorderDefaults.removePersistentDomain(forName: reorderSuite) }
let reorderModel = BoardViewModel.demo(defaults: reorderDefaults)
let reorderInitial = reorderModel.displayedCards.map(\.id)
let reorderFirst = reorderInitial[0]
let reorderLast = reorderInitial[3]
reorderModel.reorderCard(
    boardIdentifier: reorderModel.reorderBoardIdentifier,
    reorderLast,
    relativeTo: reorderFirst,
    placeAfterTarget: false,
    visibleIds: reorderInitial
)
check(reorderModel.manualOrder != nil,
      "first valid drop should switch automatic order to manual")
check(reorderModel.displayedCards.prefix(2).map(\.id)
        == [reorderLast, reorderFirst],
      "manual drop should move the dragged card before the target")

let reorderManualFirst = reorderModel.displayedCards[0].id
reorderModel.archive(reorderManualFirst)
check(reorderModel.manualOrder?.contains(reorderManualFirst) == true,
      "archiving should retain the card manual position")
reorderModel.restore(reorderManualFirst)
check(reorderModel.displayedCards.first?.id == reorderManualFirst,
      "restoring a hidden card should restore its manual position")

let manualDisplayBeforeDrag = reorderModel.displayedCards.map(\.id)
reorderModel.beginReorderDrag()
check(reorderModel.displayedCards.map(\.id) == manualDisplayBeforeDrag,
      "beginning a drag must preserve the visible manual order")
reorderModel.endReorderDrag()
check(reorderModel.displayedCards.map(\.id) == manualDisplayBeforeDrag,
      "ending a drag without a drop must preserve the visible manual order")
reorderModel.beginReorderDrag()
check(reorderModel.displayedCards.map(\.id) == manualDisplayBeforeDrag,
      "a second drag must start from the current manual order")
reorderModel.endReorderDrag()

reorderModel.toggleExpanded(reorderModel.displayedCards[1].id)
reorderModel.statusFilter = .running
let filteredFrozenDisplayBeforeDrag =
    reorderModel.displayedCards.map(\.id)
let tabCountsBeforeDrag = Dictionary(
    uniqueKeysWithValues: BoardStatusFilter.allCases.map {
        ($0, reorderModel.count(for: $0))
    }
)
reorderModel.beginReorderDrag()
check(
    reorderModel.displayedCards.map(\.id)
        == filteredFrozenDisplayBeforeDrag,
    "beginning a drag must preserve the expanded filtered display"
)
check(
    Dictionary(
        uniqueKeysWithValues: BoardStatusFilter.allCases.map {
            ($0, reorderModel.count(for: $0))
        }
    ) == tabCountsBeforeDrag,
    "starting a drag must preserve counts for every status tab"
)
reorderModel.statusFilter = .completed
check(
    !reorderModel.displayedCards.isEmpty,
    "the drag snapshot must retain all history so switching tabs cannot show an empty subset"
)
reorderModel.statusFilter = .running
reorderModel.endReorderDrag()
check(
    reorderModel.displayedCards.map(\.id)
        == filteredFrozenDisplayBeforeDrag,
      "ending a drag must preserve an expanded card's frozen order")
reorderModel.beginReorderDrag()
check(
    reorderModel.displayedCards.map(\.id)
        == filteredFrozenDisplayBeforeDrag,
    "a repeated drag must start from the currently filtered frozen display"
)
reorderModel.endReorderDrag()
reorderModel.statusFilter = .all

let reorderedBeforeRestart = reorderModel.displayedCards.map(\.id)
let restartedReorderModel = BoardViewModel.demo(defaults: reorderDefaults)
check(restartedReorderModel.displayedCards.map(\.id) == reorderedBeforeRestart,
      "manual order should persist across restart")

restartedReorderModel.statusFilter = .completed
let completedSubset = restartedReorderModel.displayedCards.map(\.id)
check(completedSubset.count == 2,
      "reorder fixture should expose two completed-tab cards")
let subsetFirst = completedSubset[0]
let subsetLast = completedSubset[1]
restartedReorderModel.reorderCard(
    boardIdentifier: restartedReorderModel.reorderBoardIdentifier,
    subsetFirst,
    relativeTo: subsetLast,
    placeAfterTarget: true,
    visibleIds: completedSubset
)
check(
    (restartedReorderModel.manualOrder ?? []).filter {
        completedSubset.contains($0)
    } == [subsetLast, subsetFirst],
      "subset reorder should affect only relative order of visible cards")

let orderBeforeInvalidDrop = restartedReorderModel.manualOrder
restartedReorderModel.reorderCard(
    boardIdentifier: "external-board",
    subsetFirst,
    relativeTo: subsetLast,
    placeAfterTarget: false,
    visibleIds: completedSubset
)
check(restartedReorderModel.manualOrder == orderBeforeInvalidDrop,
      "external board payload must not change manual order")

restartedReorderModel.resetManualOrder()
check(restartedReorderModel.manualOrder == nil,
      "automatic order action should clear persisted manual order")
check(
    reorderDefaults.stringArray(forKey: "AgentBoard.manualCardOrder") == nil,
    "automatic order action should remove persisted order"
)

let hiddenOrderSuite =
    "app.agentboard.reorder.hidden.\(UUID().uuidString)"
let hiddenOrderDefaults = UserDefaults(suiteName: hiddenOrderSuite)!
defer {
    hiddenOrderDefaults.removePersistentDomain(
        forName: hiddenOrderSuite
    )
}
let templateDefaultsSuite =
    "app.agentboard.reorder.template.\(UUID().uuidString)"
let templateDefaults = UserDefaults(suiteName: templateDefaultsSuite)!
defer {
    templateDefaults.removePersistentDomain(
        forName: templateDefaultsSuite
    )
}
let hiddenFixtureIds = BoardViewModel.demo(
    defaults: templateDefaults
)
    .cards.map(\.id)
hiddenOrderDefaults.set(
    [
        hiddenFixtureIds[3].uuidString,
        hiddenFixtureIds[0].uuidString,
        hiddenFixtureIds[1].uuidString,
        hiddenFixtureIds[2].uuidString
    ],
    forKey: "AgentBoard.manualCardOrder"
)
let hiddenOrderModel = BoardViewModel.demo(
    defaults: hiddenOrderDefaults
)
hiddenOrderModel.archive(hiddenFixtureIds[3])
hiddenOrderModel.archive(hiddenFixtureIds[1])
let hiddenIds = Set([
    hiddenFixtureIds[3],
    hiddenFixtureIds[1]
])
let hiddenManualBefore = hiddenOrderModel.manualOrder?
    .filter { hiddenIds.contains($0) } ?? []
let hiddenAutomatic = SessionReducer.ordered(
    hiddenOrderModel.cards
).map(\.id).filter { hiddenIds.contains($0) }
check(
    hiddenManualBefore != hiddenAutomatic,
    "hidden reorder regression should use a manual order distinct from time-based order"
)
hiddenOrderModel.toggleExpanded(hiddenFixtureIds[0])
let visibleBeforeHiddenOrderDrop =
    hiddenOrderModel.displayedCards.map(\.id)
hiddenOrderModel.beginReorderDrag()
hiddenOrderModel.reorderCard(
    boardIdentifier:
        hiddenOrderModel.reorderBoardIdentifier,
    hiddenFixtureIds[0],
    relativeTo: hiddenFixtureIds[2],
    placeAfterTarget: true,
    visibleIds: hiddenOrderModel.displayedCards.map(\.id)
)
hiddenOrderModel.endReorderDrag()
check(
    hiddenOrderModel.displayedCards.map(\.id)
        == [hiddenFixtureIds[2], hiddenFixtureIds[0]],
    "first actual drag should move the visible card"
)
hiddenOrderModel.beginReorderDrag()
hiddenOrderModel.reorderCard(
    boardIdentifier:
        hiddenOrderModel.reorderBoardIdentifier,
    hiddenFixtureIds[0],
    relativeTo: hiddenFixtureIds[2],
    placeAfterTarget: false,
    visibleIds: hiddenOrderModel.displayedCards.map(\.id)
)
hiddenOrderModel.endReorderDrag()
check(
    hiddenOrderModel.displayedCards.map(\.id)
        == visibleBeforeHiddenOrderDrop,
    "second actual drag should restore the original visible order"
)
let hiddenManualAfter = hiddenOrderModel.manualOrder?
    .filter { hiddenIds.contains($0) } ?? []
check(
    hiddenManualAfter == hiddenManualBefore,
    "reorder drags must preserve hidden cards' manual relative order"
)

let expandedDropSuite =
    "app.agentboard.reorder.expanded-drop.\(UUID().uuidString)"
let expandedDropDefaults = UserDefaults(suiteName: expandedDropSuite)!
defer {
    expandedDropDefaults.removePersistentDomain(
        forName: expandedDropSuite
    )
}
let expandedDropWork = FileManager.default.temporaryDirectory
    .appendingPathComponent(
        "AgentBoardExpandedDrop-\(UUID().uuidString)",
        isDirectory: true
    )
try FileManager.default.createDirectory(
    at: expandedDropWork,
    withIntermediateDirectories: true
)
let expandedDropStore = try StateStore(
    path: expandedDropWork.appendingPathComponent("board.sqlite3").path
)
let dropCardA = UUID(
    uuidString: "77777777-7777-4777-8777-777777777777"
)!
let dropCardB = UUID(
    uuidString: "88888888-8888-4888-8888-888888888888"
)!
let dropCardC = UUID(
    uuidString: "99999999-9999-4999-8999-999999999999"
)!
let dropBase = Date().addingTimeInterval(-10)
for (offset, thread) in [
    dropCardC,
    dropCardB,
    dropCardA
].enumerated() {
    let path = expandedDropWork
        .appendingPathComponent("\(thread.uuidString).jsonl")
        .path
    try expandedDropStore.ingest(
        records: [
            ParsedRecord(
                timestamp: dropBase.addingTimeInterval(
                    TimeInterval(offset)
                ),
                signal: .sessionMeta(soundHeader(thread, path: path))
            ),
            ParsedRecord(
                timestamp: dropBase.addingTimeInterval(
                    TimeInterval(offset) + 0.1
                ),
                signal: .taskStarted(turnId: "turn-\(offset)")
            ),
            ParsedRecord(
                timestamp: dropBase.addingTimeInterval(
                    TimeInterval(offset) + 0.2
                ),
                signal: .userMessage(
                    text: "카드 \(offset) 작업",
                    turnId: "turn-\(offset)"
                )
            )
        ],
        path: path,
        inode: Int64(offset + 1),
        endOffset: Int64((offset + 1) * 100)
    )
}
let expandedDropModel = BoardViewModel(
    store: expandedDropStore,
    defaults: expandedDropDefaults
)
check(
    expandedDropModel.displayedCards.prefix(3).map(\.id)
        == [dropCardA, dropCardB, dropCardC],
    "expanded-drop fixture should begin in automatic recent activity order"
)
expandedDropModel.toggleExpanded(dropCardA)
let frozenABC = expandedDropModel.displayedCards.map(\.id)
check(
    frozenABC == [dropCardA, dropCardB, dropCardC],
    "expanded-drop fixture should freeze its current display order"
)
let dropCardCPath = expandedDropWork
    .appendingPathComponent("\(dropCardC.uuidString).jsonl")
    .path
try expandedDropStore.ingest(
    records: [
        ParsedRecord(
            timestamp: dropBase.addingTimeInterval(20),
            signal: .userMessage(
                text: "카드 C의 새 활동",
                turnId: "turn-c-new"
            )
        )
    ],
    path: dropCardCPath,
    inode: 3,
    endOffset: 400
)
expandedDropModel.refresh()
check(
    expandedDropModel.displayedCards.map(\.id) == frozenABC,
    "new activity on another card must not reorder an expanded board"
)
expandedDropModel.beginReorderDrag()
let visibleDuringExpandedDrop =
    expandedDropModel.displayedCards.map(\.id)
expandedDropModel.reorderCard(
    boardIdentifier: expandedDropModel.reorderBoardIdentifier,
    dropCardA,
    relativeTo: dropCardB,
    placeAfterTarget: true,
    visibleIds: visibleDuringExpandedDrop
)
expandedDropModel.endReorderDrag()
check(
    expandedDropModel.displayedCards.map(\.id)
        == [dropCardB, dropCardA, dropCardC],
    "first drop must move A after B from the visible frozen order, not jump from automatic order"
)

let missingOrderSuite = "app.agentboard.reorder.missing.\(UUID().uuidString)"
let missingOrderDefaults = UserDefaults(suiteName: missingOrderSuite)!
defer { missingOrderDefaults.removePersistentDomain(forName: missingOrderSuite) }
let demoIds = BoardViewModel.demo(defaults: missingOrderDefaults)
    .cards.map(\.id)
missingOrderDefaults.set(
    [demoIds[3].uuidString, demoIds[0].uuidString],
    forKey: "AgentBoard.manualCardOrder"
)
let normalizedNewCardModel = BoardViewModel.demo(defaults: missingOrderDefaults)
check(normalizedNewCardModel.manualOrder?.count == demoIds.count,
      "manual order should append cards missing from an older persisted order")
check(Array(normalizedNewCardModel.manualOrder?.prefix(2) ?? [])
        == [demoIds[3], demoIds[0]],
      "existing persisted relative order should remain first")

let soundWork = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentBoardSoundTests-\(UUID().uuidString)")
try FileManager.default.createDirectory(
    at: soundWork,
    withIntermediateDirectories: true
)

func soundHeader(_ id: UUID, path: String) -> SessionHeader {
    SessionHeader(
        id: id,
        source: "cli",
        cwd: path,
        modelProvider: "openai",
        cliVersion: "0.167.1",
        historyMode: "paginated"
    )
}

let soundThread = UUID(
    uuidString: "55555555-5555-4555-8555-555555555555"
)!
let soundPath = soundWork.appendingPathComponent("sound.jsonl").path
let soundStore = try StateStore(
    path: soundWork.appendingPathComponent("sound.sqlite3").path
)
let soundStart = Date().addingTimeInterval(-30)
try soundStore.ingest(
    records: [
        ParsedRecord(
            timestamp: soundStart,
            signal: .sessionMeta(soundHeader(soundThread, path: soundPath))
        ),
        ParsedRecord(
            timestamp: soundStart.addingTimeInterval(1),
            signal: .taskStarted(turnId: "turn-1")
        )
    ],
    path: soundPath,
    inode: 1,
    endOffset: 100
)
let soundModel = BoardViewModel(store: soundStore, defaults: defaults)
var freshSoundCount = 0
soundModel.onFreshCompletionSound = {
    freshSoundCount += 1
}
let freshEventStart = Date().addingTimeInterval(1)

let report = ReportEnvelope(
    threadId: soundThread,
    timestamp: freshEventStart,
    payload: ReportPayload(
        title: "효과음 테스트",
        state: .completed,
        steps: [],
        summary: "report completed but response still running"
    )
)
let reportText = "AGENTBOARD_EVENT_V1 "
    + String(
        data: try ReportValidator.encodeEnvelope(report),
        encoding: .utf8
    )!
try soundStore.ingest(
    records: [
        ParsedRecord(
            timestamp: freshEventStart,
            signal: .toolCall(
                callId: "report-call",
                eligibleForReport: true,
                toolName: "exec_command"
            )
        ),
        ParsedRecord(
            timestamp: freshEventStart.addingTimeInterval(0.1),
            signal: .toolOutput(
                callId: "report-call",
                text: reportText
            )
        )
    ],
    path: soundPath,
    inode: 1,
    endOffset: 200
)
soundModel.refresh()
check(
    freshSoundCount == 0,
    "report completed before normal response end must not play completion sound"
)

try soundStore.ingest(
    records: [
        ParsedRecord(
            timestamp: freshEventStart.addingTimeInterval(1),
            signal: .taskComplete(turnId: "turn-1")
        )
    ],
    path: soundPath,
    inode: 1,
    endOffset: 300
)
soundModel.refresh()
check(
    freshSoundCount == 1,
    "fresh normal task_complete should play once"
)

try soundStore.ingest(
    records: [
        ParsedRecord(
            timestamp: freshEventStart.addingTimeInterval(2),
            signal: .taskComplete(turnId: "turn-1")
        )
    ],
    path: soundPath,
    inode: 1,
    endOffset: 400
)
soundModel.refresh()
check(
    freshSoundCount == 1,
    "duplicate task_complete must not replay completion sound"
)
if let completed = soundModel.cards.first(where: { $0.id == soundThread }) {
    soundModel.confirmCompletion(completed.id)
}
soundModel.statusFilter = .completed
soundModel.showAllHistory = true
soundModel.refresh()
check(
    freshSoundCount == 1,
    "read and filter changes must not replay completion sound"
)

try soundStore.ingest(
    records: [
        ParsedRecord(
            timestamp: freshEventStart.addingTimeInterval(3),
            signal: .taskStarted(turnId: "turn-2")
        ),
        ParsedRecord(
            timestamp: freshEventStart.addingTimeInterval(4),
            signal: .taskComplete(turnId: "turn-2")
        )
    ],
    path: soundPath,
    inode: 1,
    endOffset: 500
)
soundModel.refresh()
check(
    freshSoundCount == 2,
    "each genuine new response completion should play once"
)

soundModel.completionSoundEnabled = false
try soundStore.ingest(
    records: [
        ParsedRecord(
            timestamp: freshEventStart.addingTimeInterval(5),
            signal: .taskStarted(turnId: "turn-3")
        ),
        ParsedRecord(
            timestamp: freshEventStart.addingTimeInterval(6),
            signal: .taskComplete(turnId: "turn-3")
        )
    ],
    path: soundPath,
    inode: 1,
    endOffset: 600
)
soundModel.refresh()
check(
    freshSoundCount == 2,
    "completion sound disabled should be silent"
)
soundModel.completionSoundEnabled = true
soundModel.refresh()
check(
    freshSoundCount == 2,
    "re-enabling completion sound must not replay disabled-period completions"
)

let historicalThread = UUID(
    uuidString: "66666666-6666-4666-8666-666666666666"
)!
let historicalPath = soundWork.appendingPathComponent("history.jsonl").path
let historicalStore = try StateStore(
    path: soundWork.appendingPathComponent("history.sqlite3").path
)
try historicalStore.ingest(
    records: [
        ParsedRecord(
            timestamp: soundStart,
            signal: .sessionMeta(
                soundHeader(historicalThread, path: historicalPath)
            )
        ),
        ParsedRecord(
            timestamp: soundStart.addingTimeInterval(1),
            signal: .taskStarted(turnId: "history-turn")
        ),
        ParsedRecord(
            timestamp: soundStart.addingTimeInterval(2),
            signal: .taskComplete(turnId: "history-turn")
        )
    ],
    path: historicalPath,
    inode: 2,
    endOffset: 100
)
var historySoundCount = 0
let historicalModel = BoardViewModel(
    store: historicalStore,
    defaults: defaults
)
historicalModel.onFreshCompletionSound = {
    historySoundCount += 1
}
historicalModel.refresh()
check(
    historySoundCount == 0,
    "startup and migration baseline must be silent"
)
let restartedModel = BoardViewModel(
    store: historicalStore,
    defaults: defaults
)
restartedModel.onFreshCompletionSound = {
    historySoundCount += 1
}
restartedModel.refresh()
check(
    historySoundCount == 0,
    "app restart with existing completion must be silent"
)

let batchStore = try StateStore(
    path: soundWork.appendingPathComponent("batch.sqlite3").path
)
let batchThreads = [
    UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
    UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
]
let batchPaths = batchThreads.enumerated().map {
    soundWork.appendingPathComponent("batch-\($0.offset).jsonl").path
}
for (index, thread) in batchThreads.enumerated() {
    try batchStore.ingest(
        records: [
            ParsedRecord(
                timestamp: soundStart,
                signal: .sessionMeta(
                    soundHeader(thread, path: batchPaths[index])
                )
            ),
            ParsedRecord(
                timestamp: soundStart.addingTimeInterval(1),
                signal: .taskStarted(turnId: "batch-\(index)")
            )
        ],
        path: batchPaths[index],
        inode: Int64(10 + index),
        endOffset: 100
    )
}
let batchSoundModel = BoardViewModel(
    store: batchStore,
    defaults: defaults
)
var batchSoundCount = 0
batchSoundModel.onFreshCompletionSound = {
    batchSoundCount += 1
}
for (index, _) in batchThreads.enumerated() {
    try batchStore.ingest(
        records: [
            ParsedRecord(
                timestamp: Date().addingTimeInterval(
                    2 + Double(index)
                ),
                signal: .taskComplete(turnId: "batch-\(index)")
            )
        ],
        path: batchPaths[index],
        inode: Int64(10 + index),
        endOffset: 200
    )
}
batchSoundModel.refresh()
check(
    batchSoundCount == 1,
    "multiple fresh completions in one poll should merge into one sound"
)

let shortObservationStart = Date().addingTimeInterval(10)
let shortStore = try StateStore(
    path: soundWork.appendingPathComponent("short.sqlite3").path
)
let shortModel = BoardViewModel(
    store: shortStore,
    defaults: defaults,
    observationStart: shortObservationStart
)
var shortSoundCount = 0
shortModel.onFreshCompletionSound = {
    shortSoundCount += 1
}
let shortThread = UUID(
    uuidString: "99999999-9999-4999-8999-999999999999"
)!
let shortPath = soundWork.appendingPathComponent("short.jsonl").path
let shortCompletedAt = shortObservationStart.addingTimeInterval(2)
try shortStore.ingest(
    records: [
        ParsedRecord(
            timestamp: shortObservationStart.addingTimeInterval(1),
            signal: .sessionMeta(
                soundHeader(shortThread, path: shortPath)
            )
        ),
        ParsedRecord(
            timestamp: shortObservationStart.addingTimeInterval(1.2),
            signal: .taskStarted(turnId: "short-turn")
        ),
        ParsedRecord(
            timestamp: shortCompletedAt,
            signal: .taskComplete(turnId: "short-turn")
        )
    ],
    path: shortPath,
    inode: 30,
    endOffset: 100
)
shortModel.refresh()
check(
    shortSoundCount == 1,
    "a short new card completed after observation start should sound once"
)
check(
    shortModel.cards.first(where: { $0.id == shortThread })?.completedAt
        == shortCompletedAt,
    "fresh completion timestamp must be preserved for sound tracking"
)

let catchupObservationStart = Date().addingTimeInterval(5)
let catchupStore = try StateStore(
    path: soundWork.appendingPathComponent("catchup.sqlite3").path
)
let catchupThread = UUID(
    uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
)!
let catchupPath = soundWork.appendingPathComponent("catchup.jsonl").path
try catchupStore.ingest(
    records: [
        ParsedRecord(
            timestamp: catchupObservationStart.addingTimeInterval(-60),
            signal: .sessionMeta(
                soundHeader(catchupThread, path: catchupPath)
            )
        ),
        ParsedRecord(
            timestamp: catchupObservationStart.addingTimeInterval(-59),
            signal: .taskStarted(turnId: "catchup-turn")
        )
    ],
    path: catchupPath,
    inode: 31,
    endOffset: 100
)
let catchupModel = BoardViewModel(
    store: catchupStore,
    defaults: defaults,
    observationStart: catchupObservationStart
)
var catchupSoundCount = 0
catchupModel.onFreshCompletionSound = {
    catchupSoundCount += 1
}
let catchupCompletedAt = Date().addingTimeInterval(1)
try catchupStore.ingest(
    records: [
        ParsedRecord(
            timestamp: catchupCompletedAt,
            signal: .taskComplete(turnId: "catchup-turn")
        )
    ],
    path: catchupPath,
    inode: 31,
    endOffset: 200
)
catchupModel.refresh()
check(
    catchupSoundCount == 0,
    "historical running-task completion caught up after launch must be silent"
)
check(
    catchupModel.cards.first(where: { $0.id == catchupThread })?.completedAt
        == catchupCompletedAt,
    "historical completion timestamp should remain available for filtering"
)

print(checks)
if failures.isEmpty {
    print("PASS AppViewModel \(checks) checks")
    exit(0)
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
