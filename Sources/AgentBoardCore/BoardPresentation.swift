import CoreGraphics
import Foundation

public enum BoardStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case running
    case attention
    case completed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "전체"
        case .running: return "진행 중"
        case .attention: return "확인 필요"
        case .completed: return "완료"
        }
    }

    public func includes(_ card: AgentCard, now: Date = Date()) -> Bool {
        switch self {
        case .all:
            return true
        case .running:
            return card.state == .running && !card.isStaleRunning(now: now)
        case .attention:
            return card.state == .waiting
                || card.state == .interrupted
                || card.state == .error
                || card.isStaleRunning(now: now)
        case .completed:
            return card.isTerminal
        }
    }
}

public enum BoardVisibilityPolicy {
    public static func isVisible(
        _ card: AgentCard,
        now: Date = Date(),
        showAllHistory: Bool = false
    ) -> Bool {
        if showAllHistory {
            return true
        }
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)
        if card.isTerminal {
            return card.lastEventAt >= thirtyDaysAgo
        }
        if card.hasExplicitReport {
            return true
        }
        return card.lastEventAt >= sevenDaysAgo
    }
}

public enum FrozenCardOrder {
    public static func merged(
        frozen: [UUID],
        currentSorted: [AgentCard]
    ) -> [UUID] {
        var result = frozen
        let existing = Set(result)
        for card in currentSorted where !existing.contains(card.id) {
            result.append(card.id)
        }
        return result
    }
}

public struct BoardPanelGeometry {
    public static let defaultSize = CGSize(width: 360, height: 480)
    public static let minimumSize = CGSize(width: 320, height: 260)

    public static func clamped(
        frame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        var result = frame
        result.size.width = min(
            max(result.width, minimumSize.width),
            visibleFrame.width
        )
        result.size.height = min(
            max(result.height, minimumSize.height),
            visibleFrame.height
        )
        result.origin.x = min(
            max(result.origin.x, visibleFrame.minX),
            visibleFrame.maxX - result.width
        )
        result.origin.y = min(
            max(result.origin.y, visibleFrame.minY),
            visibleFrame.maxY - result.height
        )
        return result
    }

    public static func constrainedResize(
        proposed: CGSize,
        visibleFrame: CGRect
    ) -> CGSize {
        CGSize(
            width: min(
                max(proposed.width, minimumSize.width),
                visibleFrame.width
            ),
            height: min(
                max(proposed.height, minimumSize.height),
                visibleFrame.height
            )
        )
    }
}

public enum ResizeCursorDirection: Equatable, Sendable {
    case arrow
    case leftRight
    case upDown
    case diagonalNWSE
    case diagonalNESW

    public static func at(
        point: CGPoint,
        in size: CGSize,
        edge: CGFloat = 9
    ) -> ResizeCursorDirection {
        ResizeHandle.at(point: point, in: size, edge: edge)?.cursor ?? .arrow
    }
}

public enum ResizeHandle: CaseIterable, Equatable, Sendable {
    case left
    case right
    case bottom
    case top
    case bottomLeft
    case bottomRight
    case topLeft
    case topRight

    public static func at(
        point: CGPoint,
        in size: CGSize,
        edge: CGFloat = 9
    ) -> ResizeHandle? {
        let left = point.x <= edge
        let right = point.x >= size.width - edge
        let bottom = point.y <= edge
        let top = point.y >= size.height - edge
        if bottom && left { return .bottomLeft }
        if bottom && right { return .bottomRight }
        if top && left { return .topLeft }
        if top && right { return .topRight }
        if left { return .left }
        if right { return .right }
        if bottom { return .bottom }
        if top { return .top }
        return nil
    }

    public var cursor: ResizeCursorDirection {
        switch self {
        case .left, .right: return .leftRight
        case .bottom, .top: return .upDown
        case .bottomLeft, .topRight: return .diagonalNESW
        case .bottomRight, .topLeft: return .diagonalNWSE
        }
    }

    public var movesHorizontalEdge: Bool {
        switch self {
        case .left, .right, .bottomLeft, .bottomRight, .topLeft, .topRight:
            return true
        case .bottom, .top:
            return false
        }
    }

    public var movesVerticalEdge: Bool {
        switch self {
        case .bottom, .top, .bottomLeft, .bottomRight, .topLeft, .topRight:
            return true
        case .left, .right:
            return false
        }
    }

    public var movesLeft: Bool {
        self == .left || self == .bottomLeft || self == .topLeft
    }

    public var movesBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
}

public struct MagneticSnapAxis: Sendable {
    public var acquireThreshold: CGFloat
    public var releaseThreshold: CGFloat
    public private(set) var lockedValue: CGFloat?

    public init(
        acquireThreshold: CGFloat = 8,
        releaseThreshold: CGFloat = 20
    ) {
        self.acquireThreshold = acquireThreshold
        self.releaseThreshold = releaseThreshold
        lockedValue = nil
    }

    public mutating func update(
        rawEdge: CGFloat,
        candidates: [CGFloat]
    ) -> CGFloat {
        update(
            rawEdge: rawEdge,
            previousRawEdge: nil,
            candidates: candidates
        )
    }

    public mutating func update(
        rawEdge: CGFloat,
        previousRawEdge: CGFloat?,
        candidates: [CGFloat]
    ) -> CGFloat {
        if let lockedValue {
            if candidates.contains(lockedValue),
               abs(rawEdge - lockedValue) <= releaseThreshold {
                return lockedValue
            }
            self.lockedValue = nil
        }
        if let nearest = candidates.min(by: {
            abs($0 - rawEdge) < abs($1 - rawEdge)
        }), abs(nearest - rawEdge) <= acquireThreshold {
            lockedValue = nearest
            return nearest
        }
        if let previousRawEdge {
            let lower = min(previousRawEdge, rawEdge)
            let upper = max(previousRawEdge, rawEdge)
            let crossed = candidates.filter {
                $0 >= lower && $0 <= upper
            }
            if let nearest = crossed.min(by: {
                abs($0 - rawEdge) < abs($1 - rawEdge)
            }) {
                lockedValue = nearest
                return nearest
            }
        }
        return rawEdge
    }
}

public enum PanelMoveGeometry {
    public static func rawOrigin(
        initialFrame: CGRect,
        mouseDelta: CGSize
    ) -> CGPoint {
        CGPoint(
            x: initialFrame.minX + mouseDelta.width,
            y: initialFrame.minY + mouseDelta.height
        )
    }

    public static func originCandidates(
        edgeCandidates: [CGFloat],
        axisSpan: CGFloat
    ) -> [CGFloat] {
        Array(Set(
            edgeCandidates + edgeCandidates.map { $0 - axisSpan }
        )).sorted()
    }

    public static func frame(
        initialFrame: CGRect,
        rawOrigin: CGPoint,
        movingX: CGFloat,
        movingY: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        BoardPanelGeometry.clamped(
            frame: CGRect(
                origin: CGPoint(x: movingX, y: movingY),
                size: initialFrame.size
            ),
            visibleFrame: visibleFrame
        )
    }
}

public enum PanelHorizontalEdge: Equatable, Sendable {
    case left
    case right
}

public enum PanelEdgeCollapseGeometry {
    public static let outwardThreshold: CGFloat = 32
    public static let edgeTolerance: CGFloat = 1
    public static let handleSize = CGSize(width: 22, height: 72)

    public static func collapseEdge(
        displayedFrame: CGRect,
        rawFrame: CGRect,
        mouseDelta: CGSize,
        pointer: CGPoint,
        startVisibleFrame: CGRect,
        targetVisibleFrame: CGRect
    ) -> PanelHorizontalEdge? {
        guard startVisibleFrame == targetVisibleFrame,
              targetVisibleFrame.contains(pointer),
              abs(mouseDelta.width) >= abs(mouseDelta.height) else {
            return nil
        }
        let leftOverflow =
            targetVisibleFrame.minX - rawFrame.minX
        let rightOverflow =
            rawFrame.maxX - targetVisibleFrame.maxX
        let leftAttached = abs(
            displayedFrame.minX - targetVisibleFrame.minX
        ) <= edgeTolerance
        let rightAttached = abs(
            displayedFrame.maxX - targetVisibleFrame.maxX
        ) <= edgeTolerance

        if mouseDelta.width <= -outwardThreshold,
           leftOverflow >= outwardThreshold,
           leftAttached {
            return .left
        }
        if mouseDelta.width >= outwardThreshold,
           rightOverflow >= outwardThreshold,
           rightAttached {
            return .right
        }
        return nil
    }

    public static func handleFrame(
        edge: PanelHorizontalEdge,
        visibleFrame: CGRect,
        referenceFrame: CGRect,
        size: CGSize = handleSize
    ) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let proposedY = referenceFrame.midY - height / 2
        let y = min(
            max(proposedY, visibleFrame.minY),
            visibleFrame.maxY - height
        )
        return CGRect(
            x: edge == .left
                ? visibleFrame.minX
                : visibleFrame.maxX - width,
            y: y,
            width: width,
            height: height
        )
    }

}

public enum MultiScreenGeometry {
    public static func visibleFrame(
        containing point: CGPoint,
        in visibleFrames: [CGRect],
        fallback: CGRect
    ) -> CGRect {
        visibleFrames.first(where: { $0.contains(point) })
            ?? closestVisibleFrame(to: point, visibleFrames: visibleFrames)
            ?? fallback
    }

    public static func targetVisibleFrame(
        pointer: CGPoint,
        proposedFrame: CGRect,
        visibleFrames: [CGRect],
        fallback: CGRect
    ) -> CGRect {
        if let containing = visibleFrames.first(where: {
            $0.contains(pointer)
        }) {
            return containing
        }
        let intersecting = visibleFrames.max { lhs, rhs in
            lhs.intersection(proposedFrame).area
                < rhs.intersection(proposedFrame).area
        }
        if let intersecting,
           intersecting.intersection(proposedFrame).area > 0 {
            return intersecting
        }
        return closestVisibleFrame(
            to: pointer,
            visibleFrames: visibleFrames
        ) ?? fallback
    }

    private static func closestVisibleFrame(
        to point: CGPoint,
        visibleFrames: [CGRect]
    ) -> CGRect? {
        visibleFrames.min {
            distance(from: $0, to: point) < distance(from: $1, to: point)
        }
    }

    private static func distance(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

public enum MagneticSnapCandidates {
    public static func verticalEdges(
        externalFrames: [CGRect],
        panelFrame: CGRect,
        visibleFrame: CGRect
    ) -> [CGFloat] {
        var edges = [visibleFrame.minX, visibleFrame.maxX]
        for frame in externalFrames
        where intervalsOverlap(
            frame.minY,
            frame.maxY,
            panelFrame.minY,
            panelFrame.maxY
        ) {
            edges.append(frame.minX)
            edges.append(frame.maxX)
        }
        return Array(Set(edges)).sorted()
    }

    public static func horizontalEdges(
        externalFrames: [CGRect],
        panelFrame: CGRect,
        visibleFrame: CGRect
    ) -> [CGFloat] {
        var edges = [visibleFrame.minY, visibleFrame.maxY]
        for frame in externalFrames
        where intervalsOverlap(
            frame.minX,
            frame.maxX,
            panelFrame.minX,
            panelFrame.maxX
        ) {
            edges.append(frame.minY)
            edges.append(frame.maxY)
        }
        return Array(Set(edges)).sorted()
    }

    private static func intervalsOverlap(
        _ firstMin: CGFloat,
        _ firstMax: CGFloat,
        _ secondMin: CGFloat,
        _ secondMax: CGFloat
    ) -> Bool {
        min(firstMax, secondMax) > max(firstMin, secondMin)
    }

    public static func appKitBounds(
        fromCoreGraphics bounds: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: primaryDisplayHeight - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }
}

public enum PanelResizeGeometry {
    public static func rawMovingEdges(
        initialFrame: CGRect,
        handle: ResizeHandle,
        mouseDelta: CGSize,
        visibleFrame: CGRect
    ) -> (x: CGFloat?, y: CGFloat?) {
        var x: CGFloat?
        var y: CGFloat?
        if handle.movesHorizontalEdge {
            if handle.movesLeft {
                x = min(
                    max(initialFrame.minX + mouseDelta.width, visibleFrame.minX),
                    initialFrame.maxX - BoardPanelGeometry.minimumSize.width
                )
            } else {
                x = min(
                    max(initialFrame.maxX + mouseDelta.width, initialFrame.minX + BoardPanelGeometry.minimumSize.width),
                    visibleFrame.maxX
                )
            }
        }
        if handle.movesVerticalEdge {
            if handle.movesBottom {
                y = min(
                    max(initialFrame.minY + mouseDelta.height, visibleFrame.minY),
                    initialFrame.maxY - BoardPanelGeometry.minimumSize.height
                )
            } else {
                y = min(
                    max(initialFrame.maxY + mouseDelta.height, initialFrame.minY + BoardPanelGeometry.minimumSize.height),
                    visibleFrame.maxY
                )
            }
        }
        return (x, y)
    }

    public static func frame(
        initialFrame: CGRect,
        handle: ResizeHandle,
        movingX: CGFloat?,
        movingY: CGFloat?,
        visibleFrame: CGRect
    ) -> CGRect {
        var frame = initialFrame
        if handle.movesLeft, let movingX {
            let right = initialFrame.maxX
            let clampedX = min(
                max(movingX, visibleFrame.minX),
                right - BoardPanelGeometry.minimumSize.width
            )
            frame.origin.x = clampedX
            frame.size.width = right - clampedX
        } else if handle.movesHorizontalEdge, let movingX {
            let clampedX = min(
                max(movingX, initialFrame.minX + BoardPanelGeometry.minimumSize.width),
                visibleFrame.maxX
            )
            frame.size.width = clampedX - initialFrame.minX
        }
        if handle.movesBottom, let movingY {
            let top = initialFrame.maxY
            let clampedY = min(
                max(movingY, visibleFrame.minY),
                top - BoardPanelGeometry.minimumSize.height
            )
            frame.origin.y = clampedY
            frame.size.height = top - clampedY
        } else if handle.movesVerticalEdge, let movingY {
            let clampedY = min(
                max(movingY, initialFrame.minY + BoardPanelGeometry.minimumSize.height),
                visibleFrame.maxY
            )
            frame.size.height = clampedY - initialFrame.minY
        }
        return frame
    }
}
