import AgentBoardCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CardReorderPayload: Codable, Equatable {
    let boardIdentifier: String
    let cardId: UUID
}

enum CardSwipeGeometry {
    static let maximumThreshold: CGFloat = 96
    static let widthRatio: CGFloat = 0.30
    static let activationDistance: CGFloat = 10
    static let horizontalDominance: CGFloat = 1.25

    static func threshold(cardWidth: CGFloat) -> CGFloat {
        min(
            maximumThreshold,
            max(cardWidth, 1) * widthRatio
        )
    }

    static func hasHorizontalIntent(_ translation: CGSize) -> Bool {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        return horizontal >= activationDistance
            && horizontal >= vertical * horizontalDominance
    }

    static func shouldArchive(
        translation: CGSize,
        cardWidth: CGFloat
    ) -> Bool {
        hasHorizontalIntent(translation)
            && abs(translation.width)
                >= threshold(cardWidth: cardWidth)
    }

    static func lockedDirection(
        translation: CGSize
    ) -> CardDragDirection? {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard max(horizontal, vertical) >= activationDistance else {
            return nil
        }
        if horizontal >= vertical * horizontalDominance {
            return .horizontal
        }
        if vertical >= horizontal * horizontalDominance {
            return .vertical
        }
        return nil
    }
}

enum CardDragDirection: Equatable {
    case horizontal
    case vertical
}

struct CardDragDirectionLock {
    private(set) var direction: CardDragDirection?

    mutating func update(translation: CGSize) {
        guard direction == nil else { return }
        direction = CardSwipeGeometry.lockedDirection(
            translation: translation
        )
    }

    mutating func reset() {
        direction = nil
    }
}

struct CardControlFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: [CGRect]] = [:]

    static func reduce(
        value: inout [UUID: [CGRect]],
        nextValue: () -> [UUID: [CGRect]]
    ) {
        for (cardId, frames) in nextValue() {
            value[cardId, default: []].append(contentsOf: frames)
        }
    }
}

struct CardTapFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: [CGRect]] = [:]

    static func reduce(
        value: inout [UUID: [CGRect]],
        nextValue: () -> [UUID: [CGRect]]
    ) {
        for (cardId, frames) in nextValue() {
            value[cardId, default: []].append(contentsOf: frames)
        }
    }
}

enum CardReorderPasteboard {
    static let dropTypes: [UTType] = [
        .utf8PlainText
    ]

    static func item(data: Data) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for type in dropTypes {
            item.setData(
                data,
                forType: NSPasteboard.PasteboardType(type.identifier)
            )
        }
        return item
    }
}

struct CardReorderDragToken: Equatable {
    fileprivate let generation: Int
}

final class CardReorderDragLifecycle: ObservableObject {
    private enum Phase {
        case idle
        case dragging(cardId: UUID, token: CardReorderDragToken)
        case dropCommitPending(
            cardId: UUID,
            token: CardReorderDragToken,
            sessionEnded: Bool
        )
    }

    private var phase = Phase.idle
    private var generation = 0

    var activeCardId: UUID? {
        switch phase {
        case .idle:
            return nil
        case let .dragging(cardId, _),
             let .dropCommitPending(cardId, _, _):
            return cardId
        }
    }

    func begin(cardId: UUID) -> CardReorderDragToken? {
        guard case .idle = phase else { return nil }
        generation += 1
        let token = CardReorderDragToken(generation: generation)
        phase = .dragging(cardId: cardId, token: token)
        return token
    }

    func canAcceptDrop(cardId: UUID) -> Bool {
        guard case let .dragging(activeCardId, _) = phase else {
            return false
        }
        return activeCardId == cardId
    }

    func beginDropCommit(
        cardId: UUID
    ) -> CardReorderDragToken? {
        guard case let .dragging(activeCardId, token) = phase,
              activeCardId == cardId else {
            return nil
        }
        phase = .dropCommitPending(
            cardId: cardId,
            token: token,
            sessionEnded: false
        )
        return token
    }

    func isDropCommitAuthorized(
        _ token: CardReorderDragToken,
        cardId: UUID
    ) -> Bool {
        guard case let .dropCommitPending(activeCardId, activeToken, _) = phase
        else {
            return false
        }
        return activeCardId == cardId && activeToken == token
    }

    @discardableResult
    func sessionEnded(
        cardId: UUID,
        allowsMove: Bool
    ) -> Bool {
        switch phase {
        case .idle:
            return false
        case let .dragging(activeCardId, _):
            guard activeCardId == cardId else { return false }
            reset()
            return true
        case let .dropCommitPending(activeCardId, token, sessionEnded):
            guard activeCardId == cardId, !sessionEnded else {
                return false
            }
            if allowsMove {
                phase = .dropCommitPending(
                    cardId: activeCardId,
                    token: token,
                    sessionEnded: true
                )
                return false
            }
            reset()
            return true
        }
    }

    @discardableResult
    func finishDropCommit(
        _ token: CardReorderDragToken,
        cardId: UUID
    ) -> Bool {
        guard isDropCommitAuthorized(token, cardId: cardId) else {
            return false
        }
        reset()
        return true
    }

    @discardableResult
    func cancelDropCommit(
        _ token: CardReorderDragToken,
        cardId: UUID
    ) -> Bool {
        guard isDropCommitAuthorized(token, cardId: cardId) else {
            return false
        }
        reset()
        return true
    }

    private func reset() {
        phase = .idle
    }
}

private struct CardDropTarget: Equatable {
    let cardId: UUID
    let placeAfter: Bool
}

private struct CardDropDelegate: DropDelegate {
    let targetId: UUID
    let model: BoardViewModel
    let lifecycle: CardReorderDragLifecycle
    @Binding var draggedCardId: UUID?
    @Binding var dropTarget: CardDropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedCardId else { return false }
        return lifecycle.canAcceptDrop(cardId: draggedCardId)
            && info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTarget?.cardId == targetId {
            dropTarget = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedCardId,
              let provider = info.itemProviders(
                  for: [.utf8PlainText]
              ).first,
              let token = lifecycle.beginDropCommit(
                  cardId: draggedCardId
              ) else {
            return false
        }
        let capturedTarget = dropTarget
        let capturedVisibleIds = model.displayedCards.map(\.id)
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier
        ) { data, _ in
            DispatchQueue.main.async {
                guard let data,
                      let payload = try? JSONDecoder().decode(
                          CardReorderPayload.self,
                          from: data
                      ),
                      payload.boardIdentifier
                        == model.reorderBoardIdentifier,
                      payload.cardId == draggedCardId,
                      lifecycle.isDropCommitAuthorized(
                          token,
                          cardId: draggedCardId
                      ) else {
                    if lifecycle.cancelDropCommit(
                        token,
                        cardId: draggedCardId
                    ) {
                        model.endReorderDrag()
                        self.draggedCardId = nil
                        dropTarget = nil
                    }
                    return
                }
                let placeAfter = capturedTarget?.cardId == targetId
                    ? (capturedTarget?.placeAfter ?? true)
                    : true
                model.reorderCard(
                    boardIdentifier: payload.boardIdentifier,
                    payload.cardId,
                    relativeTo: targetId,
                    placeAfterTarget: placeAfter,
                    visibleIds: capturedVisibleIds
                )
                if lifecycle.finishDropCommit(
                    token,
                    cardId: payload.cardId
                ) {
                    model.endReorderDrag()
                    self.draggedCardId = nil
                    dropTarget = nil
                }
            }
        }
        return true
    }

    private func updateTarget(_ info: DropInfo) {
        guard draggedCardId != nil,
              draggedCardId != targetId else {
            dropTarget = nil
            return
        }
        dropTarget = CardDropTarget(
            cardId: targetId,
            placeAfter: info.location.y >= 24
        )
    }
}

private struct CardReorderHandle: NSViewRepresentable {
    let cardId: UUID
    let boardIdentifier: String
    let lifecycle: CardReorderDragLifecycle
    let onBegin: () -> Bool
    let onSessionEnded: (NSDragOperation) -> Void
    let accessibilityLabel: String

    func makeNSView(context: Context) -> ReorderHandleView {
        let view = ReorderHandleView()
        update(view)
        return view
    }

    func updateNSView(_ view: ReorderHandleView, context: Context) {
        update(view)
    }

    private func update(_ view: ReorderHandleView) {
        view.cardId = cardId
        view.boardIdentifier = boardIdentifier
        view.onBegin = onBegin
        view.onSessionEnded = onSessionEnded
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(accessibilityLabel)
        view.toolTip = "드래그하여 카드 순서 변경"
    }
}

final class ReorderHandleView: NSView, NSDraggingSource {
    var cardId: UUID?
    var boardIdentifier: String?
    var onBegin: (() -> Bool)?
    var onSessionEnded: ((NSDragOperation) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var draggingSession: NSDraggingSession?

    override var isOpaque: Bool { false }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingSession == nil,
              let mouseDownPoint,
              let cardId,
              let boardIdentifier else {
            return
        }
        let delta = event.locationInWindow
        let dx = delta.x - mouseDownPoint.x
        let dy = delta.y - mouseDownPoint.y
        guard dx * dx + dy * dy >= 9 else { return }
        let payload = CardReorderPayload(
            boardIdentifier: boardIdentifier,
            cardId: cardId
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        guard onBegin?() == true else { return }
        let pasteboardItem = CardReorderPasteboard.item(data: data)
        let draggingItem = NSDraggingItem(
            pasteboardWriter: pasteboardItem
        )
        draggingItem.setDraggingFrame(
            bounds,
            contents: dragImage()
        )
        let session = beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        draggingSession = session
    }

    override func mouseUp(with event: NSEvent) {
        clearMouseTracking()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        Self.sourceOperationMask(for: context)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard session === draggingSession else { return }
        draggingSession = nil
        clearMouseTracking()
        onSessionEnded?(operation)
    }

    private func clearMouseTracking() {
        mouseDownPoint = nil
    }

    static func sourceOperationMask(
        for context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication:
            return .move
        case .outsideApplication:
            return []
        @unknown default:
            return []
        }
    }

    private func dragImage() -> NSImage {
        NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: rect.height / 2,
                yRadius: rect.height / 2
            ).fill()
            let configuration = NSImage.SymbolConfiguration(
                pointSize: 11,
                weight: .bold
            )
            let image = NSImage(
                systemSymbolName: "line.3.horizontal",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(configuration)
            image?.draw(
                in: rect.insetBy(dx: 5, dy: 4),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.72
            )
            return true
        }
    }
}

private enum CardPointerDragSessionState {
    static var isActive = false
}

private struct CardPointerSurface: NSViewRepresentable {
    let cardId: UUID
    let cardTitle: String
    let boardIdentifier: String
    let isEnabled: Bool
    let excludedFrames: [CGRect]
    let tapFrames: [CGRect]
    let onTap: () -> Void
    let onSwipeChanged: (CGFloat) -> Void
    let onSwipeEnded: (CGSize, CGFloat) -> Void
    let onBeginReorder: () -> Bool
    let onReorderSessionEnded: (NSDragOperation) -> Void

    func makeNSView(context: Context) -> CardPointerSurfaceView {
        let view = CardPointerSurfaceView()
        update(view)
        return view
    }

    func updateNSView(
        _ view: CardPointerSurfaceView,
        context: Context
    ) {
        update(view)
    }

    static func dismantleNSView(
        _ view: CardPointerSurfaceView,
        coordinator: ()
    ) {
        view.cancelInteraction()
    }

    private func update(_ view: CardPointerSurfaceView) {
        view.cardId = cardId
        view.cardTitle = cardTitle
        view.boardIdentifier = boardIdentifier
        view.isEnabled = isEnabled
        view.excludedFrames = excludedFrames
        view.tapFrames = tapFrames
        view.onTap = onTap
        view.onSwipeChanged = onSwipeChanged
        view.onSwipeEnded = onSwipeEnded
        view.onBeginReorder = onBeginReorder
        view.onReorderSessionEnded = onReorderSessionEnded
    }
}

final class CardPointerSurfaceView: NSView, NSDraggingSource {
    var cardId: UUID?
    var cardTitle: String?
    var boardIdentifier: String?
    var isEnabled = true
    var excludedFrames: [CGRect] = []
    var tapFrames: [CGRect] = []
    var onTap: (() -> Void)?
    var onSwipeChanged: ((CGFloat) -> Void)?
    var onSwipeEnded: ((CGSize, CGFloat) -> Void)?
    var onBeginReorder: (() -> Bool)?
    var onReorderSessionEnded: ((NSDragOperation) -> Void)?

    private var dragAnchor: CGPoint?
    private var directionLock = CardDragDirectionLock()
    private var didMove = false
    private var canTap = false
    private var draggingSession: NSDraggingSession?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled,
              !CardPointerDragSessionState.isActive else {
            return nil
        }
        let localPoint = superview.map {
            convert(point, from: $0)
        } ?? point
        guard bounds.contains(localPoint),
              !excludedFrames.contains(where: {
                  $0.contains(localPoint)
              }) else {
            return nil
        }
        return self
    }

    override func scrollWheel(with event: NSEvent) {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                scrollView.scrollWheel(with: event)
                return
            }
            ancestor = current.superview
        }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragAnchor = PanelScreenCoordinates.point(
            for: event,
            in: window
        )
        let localPoint = convert(
            event.locationInWindow,
            from: nil
        )
        canTap = tapFrames.contains {
            $0.contains(localPoint)
        }
        directionLock.reset()
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragAnchor else { return }
        let current = PanelScreenCoordinates.point(
            for: event,
            in: window
        )
        let translation = CGSize(
            width: current.x - dragAnchor.x,
            height: current.y - dragAnchor.y
        )
        if abs(translation.width) >= CardSwipeGeometry.activationDistance
            || abs(translation.height) >= CardSwipeGeometry.activationDistance {
            didMove = true
        }
        directionLock.update(translation: translation)
        switch directionLock.direction {
        case .horizontal:
            onSwipeChanged?(translation.width)
        case .vertical:
            beginReorder(with: event)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let window, let dragAnchor else {
            resetInteraction()
            return
        }
        let current = PanelScreenCoordinates.point(
            for: event,
            in: window
        )
        let translation = CGSize(
            width: current.x - dragAnchor.x,
            height: current.y - dragAnchor.y
        )
        if directionLock.direction == .horizontal {
            onSwipeEnded?(translation, bounds.width)
        } else if !didMove, canTap {
            onTap?()
        }
        if directionLock.direction != .vertical {
            resetInteraction()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if directionLock.direction == .horizontal {
            onSwipeEnded?(.zero, bounds.width)
        }
        resetInteraction()
    }

    func cancelInteraction() {
        if draggingSession == nil {
            resetInteraction()
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication:
            return .move
        case .outsideApplication:
            return []
        @unknown default:
            return []
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard session === draggingSession else { return }
        draggingSession = nil
        CardPointerDragSessionState.isActive = false
        onReorderSessionEnded?(operation)
        resetInteraction()
    }

    private func beginReorder(with event: NSEvent) {
        guard draggingSession == nil,
              let cardId,
              let boardIdentifier else {
            return
        }
        let payload = CardReorderPayload(
            boardIdentifier: boardIdentifier,
            cardId: cardId
        )
        guard let data = try? JSONEncoder().encode(payload),
              onBeginReorder?() == true else {
            return
        }
        let draggingItem = NSDraggingItem(
            pasteboardWriter: CardReorderPasteboard.item(data: data)
        )
        let localPointer = convert(
            event.locationInWindow,
            from: nil
        )
        let previewSize = NSSize(width: 220, height: 34)
        draggingItem.setDraggingFrame(
            NSRect(
                x: localPointer.x + 8,
                y: localPointer.y - previewSize.height / 2,
                width: previewSize.width,
                height: previewSize.height
            ),
            contents: reorderDragImage(
                title: cardTitle ?? "AgentBoard 카드"
            )
        )
        CardPointerDragSessionState.isActive = true
        let session = beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        draggingSession = session
    }

    private func reorderDragImage(title: String) -> NSImage {
        NSImage(size: NSSize(width: 220, height: 34), flipped: false) {
            rect in
            let background = NSBezierPath(
                roundedRect: rect.insetBy(dx: 1, dy: 1),
                xRadius: 10,
                yRadius: 10
            )
            NSColor.controlBackgroundColor
                .withAlphaComponent(0.96)
                .setFill()
            background.fill()
            NSColor.separatorColor.setStroke()
            background.lineWidth = 1
            background.stroke()
            let image = NSImage(
                systemSymbolName: "line.3.horizontal",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 11,
                    weight: .bold
                )
            )
            image?.draw(
                in: NSRect(x: 9, y: 9, width: 16, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.72
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(
                in: NSRect(x: 32, y: 9, width: 178, height: 17),
                withAttributes: [
                    .font: NSFont.systemFont(
                        ofSize: 12,
                        weight: .semibold
                    ),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
            )
            return true
        }
    }

    private func resetInteraction() {
        dragAnchor = nil
        directionLock.reset()
        didMove = false
        canTap = false
    }
}

struct BoardView: View {
    @ObservedObject var model: BoardViewModel
    @StateObject private var reorderLifecycle =
        CardReorderDragLifecycle()
    @State private var expandedPurposeIds: Set<UUID> = []
    @State private var draggedCardId: UUID?
    @State private var dropTarget: CardDropTarget?
    @State private var cardSwipeTranslations: [UUID: CGFloat] = [:]
    @State private var cardWidths: [UUID: CGFloat] = [:]
    @State private var cardControlFrames: [UUID: [CGRect]] = [:]
    @State private var cardTapFrames: [UUID: [CGRect]] = [:]
    let onRenameTitle: (AgentCard) -> Void
    let onHide: () -> Void
    let onTogglePin: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            filterBar
            ScrollView {
                LazyVStack(spacing: 9) {
                    if model.displayedCards.isEmpty {
                        emptyState
                    }
                    ForEach(Array(model.displayedCards.enumerated()), id: \.element.id) { index, card in
                        cardView(card)
                            .padding(.top, index == 0 ? 1 : 0)
                    }
                    archivedSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AgentBoard")
                        .font(.system(size: 15, weight: .bold, design: .default))
                    Text("진행 \(model.runningCount) · 확인 필요 \(model.needsAttentionCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(model.collectorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            model.collectorIsError
                                ? Color(nsColor: .systemRed)
                                : Color.secondary
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            .overlay {
                WindowDragRegion()
                    .contentShape(Rectangle())
            }
            Button(action: onTogglePin) {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(model.pinned ? "항상 위 고정 해제" : "항상 위 고정")
            .accessibilityLabel(model.pinned ? "항상 위 고정 해제" : "항상 위 고정")
            Button(action: onHide) {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("패널 숨기기")
            .accessibilityLabel("AgentBoard 패널 숨기기")
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                ForEach(BoardStatusFilter.allCases) { filter in
                    Button {
                        model.statusFilter = filter
                    } label: {
                        HStack(spacing: 3) {
                            ViewThatFits(in: .horizontal) {
                                Text(filter.title)
                                Text(compactStatusTitle(filter))
                            }
                            .lineLimit(1)
                            Text("\(model.count(for: filter))")
                                .lineLimit(1)
                                .foregroundStyle(
                                    model.statusFilter == filter
                                        ? Color.primary.opacity(0.7)
                                        : Color.secondary
                                )
                            if filter == .completed, model.unreadCompletedCount > 0 {
                                Text("새 \(model.unreadCompletedCount)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(nsColor: .systemGreen))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .allowsTightening(true)
                        .background(
                            Capsule().fill(
                                model.statusFilter == filter
                                    ? Color.primary.opacity(0.1)
                                    : Color.clear
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(filter.title) \(model.count(for: filter))개"
                    )
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    historyScopeButton
                    Spacer(minLength: 6)
                    secondaryFilterActions
                }
                VStack(alignment: .leading, spacing: 6) {
                    historyScopeButton
                    HStack(spacing: 8) {
                        secondaryFilterActions
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.025))
    }

    private var historyScopeButton: some View {
        Button {
            model.setShowAllHistory(!model.showAllHistory)
        } label: {
            Label(
                model.showAllHistory ? "전체 기록" : "최근 7일",
                systemImage: "clock"
            )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(
            model.showAllHistory ? "최근 7일만 표시" : "전체 기록 표시"
        )
    }

    @ViewBuilder
    private var secondaryFilterActions: some View {
        if model.manualOrder != nil {
            Button {
                model.resetManualOrder()
            } label: {
                Label(
                    "자동 정렬",
                    systemImage: "arrow.up.arrow.down"
                )
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("카드 자동 정렬로 복원")
        }

        bulkConfirmButton

        if !model.archivedCards.isEmpty {
            Button {
                model.showArchived.toggle()
            } label: {
                Label(
                    "숨김 \(model.archivedCards.count)",
                    systemImage: model.showArchived
                        ? "eye.slash.fill"
                        : "eye.slash"
                )
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(
                model.showArchived ? "숨긴 카드 닫기" : "숨긴 카드 보기"
            )
        }
    }

    private var bulkConfirmButton: some View {
        let unreadCount = model.unreadCompletedCount
        let scope = model.showAllHistory
            ? "전체 기록 범위"
            : "현재 표시 기록 범위"
        return Button {
            model.confirmVisibleCompletions()
        } label: {
            Label(
                "모두 확인 · \(unreadCount)",
                systemImage: "checkmark.circle"
            )
        }
        .buttonStyle(.plain)
        .disabled(unreadCount == 0)
        .opacity(unreadCount == 0 ? 0.48 : 1)
        .fixedSize(horizontal: true, vertical: false)
        .help(
            "\(scope)에서 숨김을 제외한 미확인 완료 \(unreadCount)개만 읽음 처리합니다. 진행 중 작업은 변경하지 않습니다."
        )
        .accessibilityLabel(
            "\(scope)의 미확인 완료 \(unreadCount)개 일괄 확인"
        )
        .accessibilityHint(
            "숨김 카드와 진행 중 작업은 변경하지 않습니다."
        )
    }

    private func cardView(_ card: AgentCard) -> some View {
        let expanded = model.expandedIds.contains(card.id)
        let swipeTranslation =
            cardSwipeTranslations[card.id] ?? 0
        return ZStack {
            cardSwipeHint(
                translation: swipeTranslation,
                cardWidth: cardWidth(for: card.id)
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 5) {
                    Button {
                        model.toggleExpanded(card.id)
                    } label: {
                        Text(card.displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(cardTapFramePreference(card))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    HStack(spacing: 5) {
                        if card.isCompletionUnread {
                            completionReadButton(card)
                        }

                        providerBadge(card)

                        ZStack {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            CardReorderHandle(
                                cardId: card.id,
                                boardIdentifier:
                                    model.reorderBoardIdentifier,
                                lifecycle: reorderLifecycle,
                                onBegin: {
                                    guard reorderLifecycle.begin(
                                        cardId: card.id
                                    ) != nil else {
                                        return false
                                    }
                                    model.beginReorderDrag()
                                    draggedCardId = card.id
                                    dropTarget = nil
                                    return true
                                },
                                onSessionEnded: { operation in
                                    if reorderLifecycle.sessionEnded(
                                        cardId: card.id,
                                        allowsMove:
                                            operation.contains(.move)
                                    ) {
                                        model.endReorderDrag()
                                        draggedCardId = nil
                                        dropTarget = nil
                                    }
                                },
                                accessibilityLabel:
                                    "\(card.displayTitle) 카드 순서 변경"
                            )
                        }
                        .frame(width: 22, height: 20)
                        .background(
                            Capsule().fill(
                                Color.primary.opacity(0.055)
                            )
                        )
                        .help("드래그하여 카드 순서 변경")
                        .accessibilityHint(
                            "위 또는 아래 카드로 드래그하세요"
                        )

                        cardActionsMenu(card)
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: CardControlFramePreferenceKey.self,
                                value: [
                                    card.id: [
                                        proxy.frame(
                                            in: .named(
                                                cardPointerSpace(card.id)
                                            )
                                        )
                                    ]
                                ]
                            )
                        }
                    }
                }
                Button {
                    model.toggleExpanded(card.id)
                } label: {
                    compactBody(card, showDescription: !expanded)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(cardTapFramePreference(card))
                .padding(.top, 7)

                if expanded {
                    Divider().opacity(0.3).padding(.vertical, 10)
                    expandedCard(card)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        Color(nsColor: .windowBackgroundColor)
                            .opacity(0.42)
                    )
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: 14,
                            style: .continuous
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(
                            expanded ? 0.15 : 0.08
                        )
                    )
            )
            .overlay {
                if dropTarget?.cardId == card.id {
                    VStack(spacing: 0) {
                        if dropTarget?.placeAfter != true {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(height: 3)
                                .padding(.horizontal, 8)
                        }
                        Spacer(minLength: 0)
                        if dropTarget?.placeAfter == true {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(height: 3)
                                .padding(.horizontal, 8)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .offset(x: swipeTranslation)
        }
        .coordinateSpace(name: cardPointerSpace(card.id))
        .onPreferenceChange(
            CardControlFramePreferenceKey.self
        ) { frames in
            cardControlFrames[card.id] = frames[card.id] ?? []
        }
        .onPreferenceChange(
            CardTapFramePreferenceKey.self
        ) { frames in
            cardTapFrames[card.id] = frames[card.id] ?? []
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        cardWidths[card.id] = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { width in
                        cardWidths[card.id] = width
                    }
            }
        }
        .overlay {
            cardPointerOverlay(card)
        }
        .onDrop(
            of: [.utf8PlainText],
            delegate: CardDropDelegate(
                targetId: card.id,
                model: model,
                lifecycle: reorderLifecycle,
                draggedCardId: $draggedCardId,
                dropTarget: $dropTarget
            )
        )
    }

    private func cardPointerOverlay(
        _ card: AgentCard
    ) -> some View {
        CardPointerSurface(
            cardId: card.id,
            cardTitle: card.displayTitle,
            boardIdentifier: model.reorderBoardIdentifier,
            isEnabled: !card.archived,
            excludedFrames: cardControlFrames[card.id] ?? [],
            tapFrames: cardTapFrames[card.id] ?? [],
            onTap: {
                model.toggleExpanded(card.id)
            },
            onSwipeChanged: { translation in
                cardSwipeTranslations[card.id] = translation
            },
            onSwipeEnded: { translation, width in
                finishCardSwipe(
                    card: card,
                    translation: translation,
                    measuredWidth: width
                )
            },
            onBeginReorder: {
                beginCardPointerReorder(card)
            },
            onReorderSessionEnded: { operation in
                finishCardPointerReorder(
                    card: card,
                    operation: operation
                )
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishCardSwipe(
        card: AgentCard,
        translation: CGSize,
        measuredWidth: CGFloat
    ) {
        let width = measuredWidth > 1
            ? measuredWidth
            : cardWidth(for: card.id)
        if CardSwipeGeometry.shouldArchive(
            translation: translation,
            cardWidth: width
        ) {
            model.archive(card.id)
            cardSwipeTranslations[card.id] = nil
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                cardSwipeTranslations[card.id] = 0
            }
        }
    }

    private func beginCardPointerReorder(
        _ card: AgentCard
    ) -> Bool {
        guard reorderLifecycle.begin(cardId: card.id) != nil else {
            return false
        }
        model.beginReorderDrag()
        draggedCardId = card.id
        dropTarget = nil
        return true
    }

    private func finishCardPointerReorder(
        card: AgentCard,
        operation: NSDragOperation
    ) {
        if reorderLifecycle.sessionEnded(
            cardId: card.id,
            allowsMove: operation.contains(.move)
        ) {
            model.endReorderDrag()
            draggedCardId = nil
            dropTarget = nil
        }
    }

    private func cardWidth(for id: UUID) -> CGFloat {
        max(cardWidths[id] ?? 320, 1)
    }

    private func cardPointerSpace(_ id: UUID) -> String {
        "agentboard-card-pointer-\(id.uuidString)"
    }

    private func cardTapFramePreference(
        _ card: AgentCard
    ) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: CardTapFramePreferenceKey.self,
                value: [
                    card.id: [
                        proxy.frame(
                            in: .named(
                                cardPointerSpace(card.id)
                            )
                        )
                    ]
                ]
            )
        }
    }

    @ViewBuilder
    private func cardSwipeHint(
        translation: CGFloat,
        cardWidth: CGFloat
    ) -> some View {
        let threshold = CardSwipeGeometry.threshold(
            cardWidth: cardWidth
        )
        let progress = min(abs(translation) / threshold, 1)
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
            HStack {
                if translation > 0 {
                    swipeHintLabel
                }
                Spacer(minLength: 0)
                if translation < 0 {
                    swipeHintLabel
                }
            }
            .padding(.horizontal, 16)
        }
        .opacity(progress)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var swipeHintLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.slash")
            Text("숨기기")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private func completionReadButton(_ card: AgentCard) -> some View {
        Button {
            model.confirmCompletion(card.id)
        } label: {
            Text("새 완료")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        Color(nsColor: .systemGreen).opacity(0.1)
                    )
                )
                .lineLimit(1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help("\(card.displayTitle) 완료 알림을 읽음 처리")
        .accessibilityLabel(
            "\(card.displayTitle) 새 완료 읽음 확인"
        )
        .accessibilityHint(
            "카드를 펼치거나 순서를 바꾸지 않고 완료 알림만 읽음 처리합니다."
        )
    }

    private func providerBadge(_ card: AgentCard) -> some View {
        Text(card.provider.displayName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.primary.opacity(0.07))
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func compactBody(
        _ card: AgentCard,
        showDescription: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if showDescription {
                let purpose = TaskDescriptionFormatter.presentation(
                    title: card.displayTitle,
                    description: card.description
                )
                if !purpose.isEmpty {
                    Text(purpose.previewLines.prefix(2).joined(separator: " · "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: statusStyle(for: card).symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusStyle(for: card).color)
                Text(statusLine(for: card))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 5)
                Text(relativeTime(card.lastEventAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Image(
                    systemName: model.expandedIds.contains(card.id)
                        ? "chevron.up"
                        : "chevron.down"
                )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func expandedCard(_ card: AgentCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            purposeBlock(card)

            if let request = currentRequestText(card) {
                VStack(alignment: .leading, spacing: 5) {
                    detailLabel("현재 요청")
                    Text(request)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(5)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                detailLabel("현재 진행")
                if card.steps.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 11))
                        Text("계획 미등록")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(card.steps, id: \.id) { step in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: stepSymbol(step.status))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(
                                    step.status == .completed
                                        ? Color(nsColor: .systemGreen)
                                        : Color.secondary
                                )
                                .frame(width: 13)
                            Text(step.title)
                                .font(.system(size: 12))
                                .foregroundStyle(
                                    step.status == .completed ? .secondary : .primary
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    detailLabel("마지막 보고")
                    Spacer()
                    if let reportDate = card.lastReportAt {
                        Text(absoluteTime(reportDate))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(card.summary ?? "보고 요약 없음")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if card.isStaleRunning() {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "clock.badge.exclamationmark")
                    Text("마지막 기록 \(absoluteTime(card.lastEventAt)) · 현재 상태 확인 필요")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemOrange))
            }

            detailRow(
                label: "프로젝트",
                value: card.cwd ?? "작업 폴더 정보 없음"
            )
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CardControlFramePreferenceKey.self,
                        value: [
                            card.id: [
                                proxy.frame(
                                    in: .named(
                                        cardPointerSpace(card.id)
                                    )
                                )
                            ]
                        ]
                    )
                }
            }

            Text("마지막 활동 \(absoluteTime(card.lastEventAt))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func cardActionsMenu(_ card: AgentCard) -> some View {
        Menu {
            Button {
                onRenameTitle(card)
            } label: {
                Label("이름 변경", systemImage: "pencil")
            }

            if card.archived {
                Button {
                    model.restore(card.id)
                } label: {
                    Label(
                        "보드에 다시 표시",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                }
            } else {
                Button {
                    model.archive(card.id)
                } label: {
                    Label("숨기기", systemImage: "eye.slash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help(
            card.archived
                ? "이름 변경 또는 보드에 다시 표시"
                : "이름 변경 또는 보드에서 숨기기"
        )
        .accessibilityLabel("\(card.displayTitle) 카드 도구 메뉴")
        .accessibilityHint(
            card.archived
                ? "이름을 바꾸거나 카드를 보드에 다시 표시합니다."
                : "이름을 바꾸거나 카드를 보드에서 숨깁니다."
        )
    }

    @ViewBuilder
    private func purposeBlock(_ card: AgentCard) -> some View {
        let purpose = TaskDescriptionFormatter.presentation(
            title: card.displayTitle,
            description: card.description
        )
        if !purpose.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                detailLabel("작업 목적")
                let lines = expandedPurposeIds.contains(card.id)
                    ? purpose.allLines
                    : purpose.previewLines
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(
                                expandedPurposeIds.contains(card.id) ? nil : 2
                            )
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if purpose.isTruncated {
                    Button(
                        expandedPurposeIds.contains(card.id) ? "접기" : "더 보기"
                    ) {
                        if expandedPurposeIds.contains(card.id) {
                            expandedPurposeIds.remove(card.id)
                        } else {
                            expandedPurposeIds.insert(card.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        expandedPurposeIds.contains(card.id)
                            ? "작업 목적 전체 접기"
                            : "작업 목적 전체 보기"
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: CardControlFramePreferenceKey.self,
                                value: [
                                    card.id: [
                                        proxy.frame(
                                            in: .named(
                                                cardPointerSpace(card.id)
                                            )
                                        )
                                    ]
                                ]
                            )
                        }
                    }
                }
            }
        }
    }

    private func currentRequestText(_ card: AgentCard) -> String? {
        guard let cleaned = TitleSanitizer.cleanedTaskText(card.currentRequest)
            ?? card.currentRequest?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        let purpose = TitleSanitizer.cleanedTaskText(card.description)
        let normalized = normalizePurpose(cleaned)
        if normalized == normalizePurpose(purpose)
            || normalized == normalizePurpose(card.displayTitle) {
            return nil
        }
        return cleaned
    }

    private func normalizePurpose(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailLabel(label)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var archivedSection: some View {
        if model.showArchived && !model.archivedCards.isEmpty {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "eye.slash")
                    Text("보드에서 숨긴 카드")
                    Text("\(model.archivedCards.count)")
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                ForEach(model.archivedCards) { card in
                    cardView(card)
                }
            }
            .padding(.top, 3)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("표시할 Codex 작업이 없습니다")
                .font(.system(size: 12, weight: .semibold))
            Text("새 CLI 대화가 시작되면 이곳에 카드가 나타납니다.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private var footer: some View {
        HStack {
            Text(model.displayedCards.count == 1
                ? "작업 1개"
                : "작업 \(model.displayedCards.count)개")
            Spacer()
            Button("종료", action: onQuit)
                .buttonStyle(.plain)
                .accessibilityLabel("AgentBoard 종료")
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .medium))
                .accessibilityHidden(true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.025))
    }

    private func statusLine(for card: AgentCard) -> String {
        if card.isStaleRunning() {
            return "현재 상태 확인 필요"
        }
        if let current = card.currentStep {
            return "\(card.displayState()) · \(current.title)"
        }
        return card.displayState()
    }

    private func compactStatusTitle(_ filter: BoardStatusFilter) -> String {
        switch filter {
        case .all: return "전체"
        case .running: return "진행"
        case .attention: return "확인"
        case .completed: return "완료"
        }
    }

    private func statusStyle(for card: AgentCard) -> (color: Color, symbol: String) {
        if card.isStaleRunning() {
            return (Color(nsColor: .systemOrange), "exclamationmark.circle.fill")
        }
        switch card.state {
        case .waiting:
            return (Color(nsColor: .systemOrange), "pause.circle.fill")
        case .running:
            return (Color(nsColor: .systemBlue), "circle.fill")
        case .interrupted:
            return (Color(nsColor: .systemOrange), "stop.circle.fill")
        case .error:
            return (Color(nsColor: .systemRed), "xmark.octagon.fill")
        case .responseEnded:
            return (.secondary, "checkmark.circle")
        case .completed:
            return (Color(nsColor: .systemGreen), "checkmark.circle.fill")
        }
    }

    private func stepSymbol(_ status: StepStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.inset.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
