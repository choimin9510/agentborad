import AgentBoardCore
import Combine
import Foundation

final class BoardViewModel: ObservableObject {
    private struct CompletionSoundSignature: Equatable {
        let revision: Int
        let completedAt: Date
    }

    @Published private(set) var cards: [AgentCard]
    @Published private(set) var collectorMessage = "모니터링 준비 중"
    @Published private(set) var collectorIsError = false
    @Published var expandedIds: Set<UUID> = []
    @Published var statusFilter: BoardStatusFilter = .all
    @Published var showAllHistory = false {
        didSet { synchronizeFrozenOrder() }
    }
    @Published var showArchived = false
    @Published var pinned: Bool {
        didSet {
            defaults.set(pinned, forKey: "AgentBoard.pinned")
        }
    }
    @Published var completionSoundEnabled: Bool {
        didSet {
            defaults.set(
                completionSoundEnabled,
                forKey: "AgentBoard.completionSoundEnabled"
            )
        }
    }
    @Published private(set) var manualOrder: [UUID]?
    @Published private(set) var isReorderDragActive = false

    private let store: StateStore?
    let defaults: UserDefaults
    let reorderBoardIdentifier: String
    private var frozenOrder: [UUID]?
    private var reorderDragOrder: [UUID]?
    private let completionObservationStartedAt: Date
    private var completionSoundSignatures: [
        UUID: CompletionSoundSignature
    ] = [:]
    private var completionBaselineEstablished = false
    var onFreshCompletionSound: (() -> Void)?

    init(
        store: StateStore?,
        defaults: UserDefaults = .standard,
        observationStart: Date = Date()
    ) {
        self.store = store
        self.defaults = defaults
        let boardIdentifier: String
        if let existing = defaults.string(
            forKey: "AgentBoard.reorderBoardIdentifier"
        ) {
            boardIdentifier = existing
        } else {
            boardIdentifier = UUID().uuidString
            defaults.set(
                boardIdentifier,
                forKey: "AgentBoard.reorderBoardIdentifier"
            )
        }
        reorderBoardIdentifier = boardIdentifier
        manualOrder = defaults.stringArray(
            forKey: "AgentBoard.manualCardOrder"
        )?.compactMap(UUID.init(uuidString:))
        completionObservationStartedAt = observationStart
        cards = []
        pinned = defaults.object(forKey: "AgentBoard.pinned") as? Bool ?? true
        completionSoundEnabled = defaults.object(
            forKey: "AgentBoard.completionSoundEnabled"
        ) as? Bool ?? true
        refresh()
    }

    static func demo(defaults: UserDefaults) -> BoardViewModel {
        let model = BoardViewModel(store: nil, defaults: defaults)
        model.cards = DemoData.cards
        model.normalizeManualOrder()
        model.collectorMessage = "데모 데이터"
        return model
    }

    func refresh(now: Date = Date()) {
        guard let store else { return }
        do {
            let loadedCards = try store.loadCards(includeArchived: true)
            var signatures: [UUID: CompletionSoundSignature] = [:]
            for card in loadedCards {
                guard card.responseLifecycle == .completed,
                      let completedAt = card.completedAt else {
                    continue
                }
                signatures[card.id] = CompletionSoundSignature(
                    revision: card.completionRevision ?? 0,
                    completedAt: completedAt
                )
            }
            let hasFreshCompletion = completionBaselineEstablished
                && loadedCards.contains { card in
                    guard card.responseLifecycle == .completed,
                          let completedAt = card.completedAt,
                          completedAt >= completionObservationStartedAt,
                          let current = signatures[card.id]
                    else {
                        return false
                    }
                    return completionSoundSignatures[card.id] != current
                }
            cards = loadedCards
            normalizeManualOrder()
            completionSoundSignatures = signatures
            completionBaselineEstablished = true
            if isReorderDragActive {
                let current = orderedHistoryCards(now: Date())
                reorderDragOrder = FrozenCardOrder.merged(
                    frozen: reorderDragOrder ?? [],
                    currentSorted: current
                )
            }
            synchronizeFrozenOrder()
            if hasFreshCompletion, completionSoundEnabled {
                onFreshCompletionSound?()
            }
        } catch {
            collectorIsError = true
            collectorMessage = "저장소 오류: \(error.localizedDescription)"
        }
    }

    func setCollector(_ update: CollectorUpdate) {
        collectorMessage = update.message
        collectorIsError = update.isError
        refresh()
    }

    func setFatalError(_ message: String) {
        collectorMessage = message
        collectorIsError = true
    }

    var displayedCards: [AgentCard] {
        let now = Date()
        if isReorderDragActive, let reorderDragOrder {
            let visible = cards.filter {
                !$0.archived
                    && BoardVisibilityPolicy.isVisible(
                        $0,
                        now: now,
                        showAllHistory: showAllHistory
                    )
                    && statusFilter.includes($0, now: now)
            }
            let byId = Dictionary(
                uniqueKeysWithValues: visible.map { ($0.id, $0) }
            )
            return reorderDragOrder.compactMap { byId[$0] }
        }
        return orderedHistoryCards(now: now).filter {
            statusFilter.includes($0, now: now)
        }
    }

    var archivedCards: [AgentCard] {
        cards.filter { $0.archived }
    }

    var needsAttentionCount: Int {
        count(for: .attention)
    }

    var runningCount: Int {
        count(for: .running)
    }

    var completedCount: Int {
        count(for: .completed)
    }

    var allCount: Int {
        count(for: .all)
    }

    var unreadCompletedCount: Int {
        visibleUnreadCompletionIds.count
    }

    var visibleUnreadCompletionIds: [UUID] {
        visibleUnreadAcknowledgements.map(\.cardId)
    }

    var visibleUnreadAcknowledgements: [CompletionAcknowledgement] {
        orderedHistoryCards(now: Date()).compactMap { card in
            guard BoardStatusFilter.completed.includes(card),
                  card.isCompletionUnread else {
                return nil
            }
            return CompletionAcknowledgement(
                cardId: card.id,
                revision: card.completionRevision
            )
        }
    }

    func beginReorderDrag() {
        guard !isReorderDragActive else { return }
        let currentDisplayOrder = orderedHistoryCards(now: Date())
        reorderDragOrder = currentDisplayOrder.map(\.id)
        isReorderDragActive = true
    }

    func endReorderDrag() {
        isReorderDragActive = false
        reorderDragOrder = nil
    }

    func reorderCard(
        boardIdentifier: String,
        _ draggedId: UUID,
        relativeTo targetId: UUID,
        placeAfterTarget: Bool,
        visibleIds: [UUID]
    ) {
        guard boardIdentifier == reorderBoardIdentifier,
              draggedId != targetId,
              visibleIds.contains(draggedId),
              visibleIds.contains(targetId),
              cards.contains(where: { $0.id == draggedId }),
              cards.contains(where: { $0.id == targetId }) else {
            return
        }
        let automaticOrder = SessionReducer.ordered(cards).map(\.id)
        let seedOrder = manualOrder ?? automaticOrder
        let desiredVisibleOrder =
            reorderDragOrder ?? visibleIds
        var order = Self.mergingDisplayOrder(
            desiredVisibleOrder,
            into: seedOrder
        )
        order.removeAll { $0 == draggedId }
        guard let targetIndex = order.firstIndex(of: targetId) else {
            return
        }
        let insertion = placeAfterTarget
            ? order.index(after: targetIndex)
            : targetIndex
        order.insert(draggedId, at: insertion)
        manualOrder = order
        defaults.set(
            order.map(\.uuidString),
            forKey: "AgentBoard.manualCardOrder"
        )
        reorderDragOrder = order
        synchronizeFrozenOrder()
    }

    func resetManualOrder() {
        guard manualOrder != nil else { return }
        manualOrder = nil
        defaults.removeObject(forKey: "AgentBoard.manualCardOrder")
        reorderDragOrder = nil
        if expandedIds.isEmpty {
            frozenOrder = nil
        } else {
            freezeCurrentOrder()
        }
    }

    func count(for filter: BoardStatusFilter) -> Int {
        let now = Date()
        return orderedHistoryCards(now: now).filter {
            filter.includes($0, now: now)
        }.count
    }

    func toggleExpanded(_ id: UUID) {
        if let card = cards.first(where: { $0.id == id }), card.isTerminal {
            confirmCompletion(id)
        }
        if expandedIds.contains(id) {
            expandedIds.remove(id)
        } else {
            if expandedIds.isEmpty {
                freezeCurrentOrder()
            }
            expandedIds.insert(id)
        }
        if expandedIds.isEmpty {
            frozenOrder = nil
        }
    }

    func archive(_ id: UUID) {
        setArchived(id, archived: true)
    }

    func restore(_ id: UUID) {
        setArchived(id, archived: false)
    }

    func confirmCompletion(_ id: UUID) {
        guard let card = cards.first(where: { $0.id == id }),
              card.isTerminal else {
            return
        }
        let acknowledgement = CompletionAcknowledgement(
            cardId: id,
            revision: card.completionRevision
        )
        acknowledge([acknowledgement])
    }

    func confirmVisibleCompletions() {
        let acknowledgements = visibleUnreadAcknowledgements
        guard !acknowledgements.isEmpty else { return }
        acknowledge(acknowledgements)
    }

    func setCustomTitle(_ title: String?, for id: UUID) throws {
        let normalized: String?
        if let title {
            normalized = try AgentTitleOverride.normalized(title)
        } else {
            normalized = nil
        }
        if let store {
            try store.setCustomTitle(cardId: id, title: normalized)
            refresh()
        } else if let index = cards.firstIndex(where: { $0.id == id }) {
            cards[index].customTitle = normalized
        }
    }

    private func acknowledge(
        _ acknowledgements: [CompletionAcknowledgement]
    ) {
        if let store {
            do {
                try store.acknowledgeCompletions(acknowledgements)
            } catch {
                setFatalError(
                    "완료 읽음 상태를 저장하지 못했습니다: \(error.localizedDescription)"
                )
                return
            }
        } else {
            let revisions = Dictionary(
                uniqueKeysWithValues: acknowledgements.map {
                    ($0.cardId, $0.revision ?? 0)
                }
            )
            for index in cards.indices {
                let revision = cards[index].completionRevision ?? 0
                if revisions[cards[index].id] == revision {
                    cards[index].completionUnread = false
                }
            }
        }
        refresh()
    }

    func setShowAllHistory(_ value: Bool) {
        showAllHistory = value
    }

    private func setArchived(_ id: UUID, archived: Bool) {
        if let store {
            do {
                try store.setArchived(cardId: id, archived: archived)
            } catch {
                setFatalError("카드 보관 상태를 바꾸지 못했습니다: \(error.localizedDescription)")
                return
            }
        } else if let index = cards.firstIndex(where: { $0.id == id }) {
            cards[index].archived = archived
        }
        if archived {
            expandedIds.remove(id)
        }
        if expandedIds.isEmpty {
            frozenOrder = nil
        }
        refresh()
    }

    private func orderedHistoryCards(now: Date) -> [AgentCard] {
        let historyFiltered = cards.filter {
            !$0.archived
                && BoardVisibilityPolicy.isVisible(
                    $0,
                    now: now,
                    showAllHistory: showAllHistory
                )
        }
        let baseOrdered: [AgentCard]
        if let manualOrder {
            let byId = Dictionary(
                uniqueKeysWithValues: historyFiltered.map { ($0.id, $0) }
            )
            baseOrdered = manualOrder.compactMap { byId[$0] }
        } else {
            baseOrdered = SessionReducer.ordered(historyFiltered, now: now)
        }
        if let frozenOrder, !expandedIds.isEmpty {
            let byId = Dictionary(
                uniqueKeysWithValues: historyFiltered.map { ($0.id, $0) }
            )
            return frozenOrder.compactMap { byId[$0] }
        }
        return baseOrdered
    }

    private func freezeCurrentOrder() {
        let visible = cards.filter { !$0.archived }
            .filter {
                BoardVisibilityPolicy.isVisible(
                    $0,
                    showAllHistory: showAllHistory
                )
            }
        let ordered: [AgentCard]
        if let manualOrder {
            let byId = Dictionary(
                uniqueKeysWithValues: visible.map { ($0.id, $0) }
            )
            let manualVisible = manualOrder.compactMap { byId[$0] }
            ordered = manualVisible
            frozenOrder = manualVisible.map(\.id)
            return
        } else {
            ordered = SessionReducer.ordered(visible)
        }
        frozenOrder = ordered.map(\.id)
    }

    private func synchronizeFrozenOrder() {
        guard !expandedIds.isEmpty else { return }
        let visible = cards.filter { !$0.archived }
            .filter {
                BoardVisibilityPolicy.isVisible(
                    $0,
                    showAllHistory: showAllHistory
                )
            }
        let ordered: [AgentCard]
        if let manualOrder {
            let byId = Dictionary(
                uniqueKeysWithValues: visible.map { ($0.id, $0) }
            )
            let manualVisible = manualOrder.compactMap { byId[$0] }
            frozenOrder = manualVisible.map(\.id)
            return
        } else {
            ordered = SessionReducer.ordered(visible)
        }
        let frozen = frozenOrder ?? []
        frozenOrder = FrozenCardOrder.merged(
            frozen: frozen,
            currentSorted: ordered
        )
    }

    private func normalizeManualOrder() {
        guard var order = manualOrder else { return }
        let ids = Set(cards.map(\.id))
        let original = order
        order.removeAll { !ids.contains($0) }
        let orderedIds = Set(order)
        let newIds = SessionReducer.ordered(
            cards.filter { !orderedIds.contains($0.id) }
        ).map(\.id)
        order.append(contentsOf: newIds)
        if order != original {
            manualOrder = order
            defaults.set(
                order.map(\.uuidString),
                forKey: "AgentBoard.manualCardOrder"
            )
        }
    }

    private static func mergingDisplayOrder(
        _ displayedIds: [UUID],
        into completeOrder: [UUID]
    ) -> [UUID] {
        let completeSet = Set(completeOrder)
        var seen = Set<UUID>()
        let desired = displayedIds.filter {
            completeSet.contains($0) && seen.insert($0).inserted
        }
        let desiredSet = Set(desired)
        var desiredIndex = 0
        var merged: [UUID] = []
        merged.reserveCapacity(completeOrder.count)

        for id in completeOrder {
            if desiredSet.contains(id), desiredIndex < desired.count {
                merged.append(desired[desiredIndex])
                desiredIndex += 1
            } else {
                merged.append(id)
            }
        }
        if desiredIndex < desired.count {
            merged.append(contentsOf: desired[desiredIndex...])
        }
        return merged
    }
}

private enum DemoData {
    static let cards: [AgentCard] = {
        let now = Date()
        return [
            AgentCard(
                id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                provider: .deepseek,
                title: "결제 화면 접근성 개선",
                cwd: "/Users/example/Projects/shop",
                model: "deepseek-flash",
                state: .waiting,
                steps: [
                    ReportStep(id: "audit", title: "접근성 항목 점검", status: .completed),
                    ReportStep(id: "color", title: "색 대비 수정", status: .inProgress),
                    ReportStep(id: "test", title: "VoiceOver 검증", status: .pending)
                ],
                summary: "색 대비 수정 범위를 확인한 뒤 테스트할 준비가 되었습니다.",
                description: "쇼핑 결제 화면의 접근성을 점검하고 색 대비와 VoiceOver 동작을 개선합니다.",
                currentRequest: "색 대비 수정 결과를 확인해 주세요.",
                startedAt: now.addingTimeInterval(-1_380),
                lastEventAt: now.addingTimeInterval(-240),
                lastReportAt: now.addingTimeInterval(-260),
                currentTurnId: "demo-turn-waiting",
                hasExplicitReport: true,
                taskIdentityCaptured: true
            ),
            AgentCard(
                id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                provider: .openai,
                title: "AgentBoard 모니터링 안정화",
                cwd: "/Users/example/Projects/agentboard",
                model: "gpt-6-astra",
                state: .running,
                steps: [
                    ReportStep(id: "parser", title: "세션 파서 구현", status: .completed),
                    ReportStep(id: "store", title: "SQLite 저장소 연결", status: .inProgress),
                    ReportStep(id: "ui", title: "패널 UI 마무리", status: .pending)
                ],
                summary: "세션 파서 구현을 마치고 저장소 연결을 진행하고 있습니다.",
                description: "Codex 세션을 안전하게 수집하고 안정적인 macOS 모니터링 패널로 보여 줍니다.",
                currentRequest: "SQLite 저장소 연결을 진행합니다.",
                startedAt: now.addingTimeInterval(-2_040),
                lastEventAt: now.addingTimeInterval(-35),
                lastReportAt: now.addingTimeInterval(-45),
                currentTurnId: "demo-turn-running",
                hasExplicitReport: true,
                taskIdentityCaptured: true
            ),
            AgentCard(
                id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                provider: .deepseek,
                title: "검색 필터 API 정리",
                cwd: "/Users/example/Projects/search-api",
                model: "deepseek-flash",
                state: .responseEnded,
                steps: [],
                summary: "필터 조합과 빈 결과 응답을 확인했습니다.",
                description: "검색 필터 API의 조합 규칙과 빈 결과 응답을 정리합니다.",
                currentRequest: "검색 필터 API 응답을 확인했습니다.",
                startedAt: now.addingTimeInterval(-4_200),
                lastEventAt: now.addingTimeInterval(-1_500),
                lastReportAt: now.addingTimeInterval(-1_520),
                currentTurnId: "demo-turn-ended",
                hasExplicitReport: true,
                taskIdentityCaptured: true,
                completionUnread: true
            ),
            AgentCard(
                id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
                provider: .openai,
                title: "릴리스 노트 초안 작성",
                cwd: "/Users/example/Projects/release",
                model: "gpt-6-astra",
                state: .completed,
                steps: [
                    ReportStep(id: "collect", title: "변경 사항 수집", status: .completed),
                    ReportStep(id: "write", title: "초안 작성", status: .completed),
                    ReportStep(id: "review", title: "검토", status: .completed)
                ],
                summary: "변경 사항을 정리하고 한국어 릴리스 노트 초안을 완성했습니다.",
                description: "이번 배포의 변경 사항을 모아 한국어 릴리스 노트 초안을 작성합니다.",
                startedAt: now.addingTimeInterval(-9_200),
                lastEventAt: now.addingTimeInterval(-3_000),
                lastReportAt: now.addingTimeInterval(-3_020),
                completedAt: now.addingTimeInterval(-3_000),
                currentTurnId: "demo-turn-complete",
                hasExplicitReport: true,
                taskIdentityCaptured: true,
                completionUnread: true
            )
        ]
    }()
}
