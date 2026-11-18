import AgentBoardCore
import AppKit
import CoreGraphics
import Darwin
import SwiftUI

final class AgentBoardPanel: NSPanel {
    weak var resizeCursorOverlay: PanelResizeOverlay?
    var isInteractiveGeometryMutation = false
    var applyAccessibilityFrame: ((NSRect) -> Void)?

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityFrame(_:)) { return true }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func setAccessibilityFrame(_ frame: NSRect) {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.size.width > 0, frame.size.height > 0 else { return }
        applyAccessibilityFrame?(frame)
    }

    // NSWindow's legacy AXSize bridge otherwise rejects panels without .resizable.
    @available(macOS, introduced: 10.1, deprecated: 10.10)
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        if attribute == .size { return true }
        return super.accessibilityIsAttributeSettable(attribute)
    }

    @available(macOS, introduced: 10.1, deprecated: 10.10)
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        if attribute == .size {
            guard let size = (value as? NSValue)?.sizeValue else { return }
            setAccessibilityFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height))
        } else {
            super.accessibilitySetValue(value, forAttribute: attribute)
            if attribute == .position { applyAccessibilityFrame?(frame) }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard let resizeCursorOverlay else {
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .mouseMoved, .cursorUpdate, .mouseEntered:
            if resizeCursorOverlay.isResizeEdge(
                atWindowPoint: event.locationInWindow
            ) {
                super.sendEvent(event)
                resizeCursorOverlay.claimHoverResizeCursor(
                    atWindowPoint: event.locationInWindow
                )
            } else {
                resizeCursorOverlay.releaseHoverResizeCursor()
                super.sendEvent(event)
            }
        case .mouseExited:
            resizeCursorOverlay.releaseHoverResizeCursor()
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}

final class PanelContentView: NSView {
    override var isFlipped: Bool { false }
}

private final class CollapsedHandlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CollapsedHandleView: NSView {
    var onActivate: (() -> Void)?
    private let pointsLeft: Bool

    init(frame frameRect: NSRect, pointsLeft: Bool) {
        self.pointsLeft = pointsLeft
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("AgentBoard 펼치기")
        setAccessibilityHelp(
            "숨긴 AgentBoard를 기존 크기와 위치로 다시 표시합니다."
        )
        toolTip = "AgentBoard 펼치기"
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        _ = performAccessibilityActivation()
    }

    override func accessibilityPerformPress() -> Bool {
        performAccessibilityActivation()
    }

    @discardableResult
    private func performAccessibilityActivation() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            xRadius: 9,
            yRadius: 9
        )
        NSColor.controlBackgroundColor.withAlphaComponent(0.94).setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.lineWidth = 1
        background.stroke()

        let chevron = NSBezierPath()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let reach: CGFloat = 3.5
        if pointsLeft {
            chevron.move(to: NSPoint(x: center.x + reach, y: center.y + 6))
            chevron.line(to: NSPoint(x: center.x - reach, y: center.y))
            chevron.line(to: NSPoint(x: center.x + reach, y: center.y - 6))
        } else {
            chevron.move(to: NSPoint(x: center.x - reach, y: center.y + 6))
            chevron.line(to: NSPoint(x: center.x + reach, y: center.y))
            chevron.line(to: NSPoint(x: center.x - reach, y: center.y - 6))
        }
        chevron.lineWidth = 2
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.labelColor.setStroke()
        chevron.stroke()
    }
}

enum PanelScreenCoordinates {
    static func point(for event: NSEvent, in window: NSWindow?) -> NSPoint {
        if let cgEvent = event.cgEvent {
            let primaryHeight = primaryDisplayHeight()
            return NSPoint(
                x: cgEvent.location.x,
                y: primaryHeight - cgEvent.location.y
            )
        }
        if let window {
            return window.convertPoint(
                toScreen: event.locationInWindow
            )
        }
        return NSEvent.mouseLocation
    }

    static func appKitPoint(
        fromCoreGraphics point: CGPoint,
        primaryDisplayHeight: CGFloat
    ) -> NSPoint {
        NSPoint(
            x: point.x,
            y: primaryDisplayHeight - point.y
        )
    }

    static func primaryDisplayHeight() -> CGFloat {
        NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?
            .frame.height ?? NSScreen.main?.frame.height ?? 0
    }
}

enum DesktopWindowSnapData {
    static var visibleFrames: [CGRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    static func externalFrames(excludingPID: pid_t) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = PanelScreenCoordinates.primaryDisplayHeight()
        guard primaryHeight > 0 else { return [] }
        return windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?
                .int32Value != excludingPID,
                (window[kCGWindowLayer as String] as? NSNumber)?
                    .intValue == 0,
                (window[kCGWindowAlpha as String] as? NSNumber)?
                    .doubleValue ?? 0 > 0.01,
                let boundsDictionary = window[kCGWindowBounds as String]
                    as? NSDictionary,
                let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                ),
                bounds.width > 40,
                bounds.height > 40 else {
                return nil
            }
            return MagneticSnapCandidates.appKitBounds(
                fromCoreGraphics: bounds,
                primaryDisplayHeight: primaryHeight
            )
        }
    }
}

final class HeaderDragCancellationState {
    private(set) var isActive = false
    private(set) var isCancelled = false

    func begin() {
        isActive = true
        isCancelled = false
    }

    @discardableResult
    func cancel() -> Bool {
        guard isActive, !isCancelled else { return false }
        isCancelled = true
        return true
    }

    @discardableResult
    func finish() -> Bool {
        let wasCancelled = isActive && isCancelled
        isActive = false
        isCancelled = false
        return wasCancelled
    }

    @discardableResult
    func cancelIfKeyInput(
        startedAt startCount: UInt32,
        endedAt endCount: UInt32
    ) -> Bool {
        guard startCount != endCount else { return false }
        return cancel()
    }
}

struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        private var dragAnchor: NSPoint?
        private var initialFrame: CGRect?
        private var fallbackVisibleFrame: CGRect?
        private var visibleFrames: [CGRect] = []
        private var externalFrames: [CGRect] = []
        private var horizontalSnap = MagneticSnapAxis()
        private var verticalSnap = MagneticSnapAxis()
        private var previousRawOrigin: CGPoint?
        private var didDrag = false
        private var dragStartVisibleFrame: CGRect?
        private weak var cancellationController: PanelController?
        var visibleFramesOverrideForTesting: [CGRect]?
        var externalFramesOverrideForTesting: [CGRect]?
        var lastProposedFrameForTesting: CGRect?
        var dragStartVisibleFrameForTesting: CGRect? {
            dragStartVisibleFrame
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityRole(.group)
            setAccessibilityLabel("AgentBoard 패널 이동 영역")
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setAccessibilityRole(.group)
            setAccessibilityLabel("AgentBoard 패널 이동 영역")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = superview.map { convert(point, from: $0) } ?? point
            return bounds.contains(localPoint) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let controller = window.delegate as? PanelController
            cancellationController = controller
            controller?.finishHeaderDragCancellation()
            (window as? AgentBoardPanel)?
                .isInteractiveGeometryMutation = true
            dragAnchor = PanelScreenCoordinates.point(
                for: event,
                in: window
            )
            initialFrame = window.frame
            visibleFrames = visibleFramesOverrideForTesting
                ?? DesktopWindowSnapData.visibleFrames
            fallbackVisibleFrame = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? visibleFrames.first
                ?? window.frame.insetBy(dx: -4_096, dy: -4_096)
            if let dragAnchor, let fallbackVisibleFrame {
                dragStartVisibleFrame =
                    MultiScreenGeometry.targetVisibleFrame(
                        pointer: dragAnchor,
                        proposedFrame: window.frame,
                        visibleFrames: visibleFrames,
                        fallback: fallbackVisibleFrame
                    )
            }
            externalFrames = externalFramesOverrideForTesting
                ?? DesktopWindowSnapData.externalFrames(
                    excludingPID: getpid()
                )
            horizontalSnap = MagneticSnapAxis()
            verticalSnap = MagneticSnapAxis()
            previousRawOrigin = window.frame.origin
            didDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window,
                  let dragAnchor,
                  let initialFrame,
                  let fallbackVisibleFrame else {
                return
            }
            let current = PanelScreenCoordinates.point(
                for: event,
                in: window
            )
            if !didDrag {
                didDrag = true
                cancellationController?.beginHeaderDragCancellation()
            }
            let rawOrigin = PanelMoveGeometry.rawOrigin(
                initialFrame: initialFrame,
                mouseDelta: CGSize(
                    width: current.x - dragAnchor.x,
                    height: current.y - dragAnchor.y
                )
            )
            let proposedFrame = CGRect(
                origin: rawOrigin,
                size: initialFrame.size
            )
            let targetVisibleFrame = MultiScreenGeometry.targetVisibleFrame(
                pointer: current,
                proposedFrame: proposedFrame,
                visibleFrames: visibleFrames,
                fallback: fallbackVisibleFrame
            )
            let targetExternalFrames = externalFrames.filter {
                $0.intersects(targetVisibleFrame)
            }
            let horizontalCandidates = PanelMoveGeometry.originCandidates(
                edgeCandidates: MagneticSnapCandidates.verticalEdges(
                    externalFrames: targetExternalFrames,
                    panelFrame: proposedFrame,
                    visibleFrame: targetVisibleFrame
                ),
                axisSpan: initialFrame.width
            )
            let verticalCandidates = PanelMoveGeometry.originCandidates(
                edgeCandidates: MagneticSnapCandidates.horizontalEdges(
                    externalFrames: targetExternalFrames,
                    panelFrame: proposedFrame,
                    visibleFrame: targetVisibleFrame
                ),
                axisSpan: initialFrame.height
            )
            let movingX = horizontalSnap.update(
                rawEdge: rawOrigin.x,
                previousRawEdge: previousRawOrigin?.x,
                candidates: horizontalCandidates
            )
            let movingY = verticalSnap.update(
                rawEdge: rawOrigin.y,
                previousRawEdge: previousRawOrigin?.y,
                candidates: verticalCandidates
            )
            let frame = PanelMoveGeometry.frame(
                initialFrame: initialFrame,
                rawOrigin: rawOrigin,
                movingX: movingX,
                movingY: movingY,
                visibleFrame: targetVisibleFrame
            )
            lastProposedFrameForTesting = frame
            window.setFrame(frame, display: true)
            previousRawOrigin = rawOrigin
        }

        override func mouseUp(with event: NSEvent) {
            (window as? AgentBoardPanel)?
                .isInteractiveGeometryMutation = false
            if let window,
               didDrag,
               let dragAnchor,
               let initialFrame,
               let fallbackVisibleFrame,
               let dragStartVisibleFrame {
                let current = PanelScreenCoordinates.point(
                    for: event,
                    in: window
                )
                let mouseDelta = CGSize(
                    width: current.x - dragAnchor.x,
                    height: current.y - dragAnchor.y
                )
                let rawOrigin = PanelMoveGeometry.rawOrigin(
                    initialFrame: initialFrame,
                    mouseDelta: mouseDelta
                )
                let rawFrame = CGRect(
                    origin: rawOrigin,
                    size: initialFrame.size
                )
                (window.delegate as? PanelController)?
                    .handleHeaderDragEnded(
                        displayedFrame: window.frame,
                        rawFrame: rawFrame,
                        mouseDelta: mouseDelta,
                        pointer: current,
                        startVisibleFrame: dragStartVisibleFrame,
                        visibleFrames: visibleFrames,
                        fallbackVisibleFrame: fallbackVisibleFrame
                    )
            }
            cancellationController?.finishHeaderDragCancellation()
            cancellationController = nil
            dragAnchor = nil
            initialFrame = nil
            fallbackVisibleFrame = nil
            visibleFrames = []
            externalFrames = []
            previousRawOrigin = nil
            didDrag = false
            dragStartVisibleFrame = nil
        }

        override func cancelOperation(_ sender: Any?) {
            (window as? AgentBoardPanel)?
                .isInteractiveGeometryMutation = false
            cancellationController?.cancelHeaderDragFromEscape()
            cancellationController?.finishHeaderDragCancellation()
            cancellationController = nil
            dragAnchor = nil
            initialFrame = nil
            fallbackVisibleFrame = nil
            visibleFrames = []
            externalFrames = []
            previousRawOrigin = nil
            didDrag = false
            dragStartVisibleFrame = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                cancellationController?.finishHeaderDragCancellation()
                cancellationController = nil
            }
        }

        deinit {
            cancellationController?.finishHeaderDragCancellation()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}
}

private final class BackgroundCursorAuthorization {
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias SetConnectionProperty = @convention(c) (
        UInt32, UInt32, CFString, CFTypeRef
    ) -> Int32

    private static let functions: (
        mainConnectionID: MainConnectionID,
        setConnectionProperty: SetConnectionProperty
    )? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let mainSymbol = dlsym(
            defaultHandle,
            "CGSMainConnectionID"
        ),
        let propertySymbol = dlsym(
            defaultHandle,
            "CGSSetConnectionProperty"
        ) else {
            return nil
        }
        return (
            unsafeBitCast(mainSymbol, to: MainConnectionID.self),
            unsafeBitCast(propertySymbol, to: SetConnectionProperty.self)
        )
    }()

    private var isEnabled = false

    var isAvailable: Bool { Self.functions != nil }
    var isEnabledForTesting: Bool { isEnabled }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard let functions = Self.functions else { return false }
        if enabled == isEnabled { return true }
        let connection = functions.mainConnectionID()
        let status = functions.setConnectionProperty(
            connection,
            connection,
            "SetsCursorInBackground" as CFString,
            (enabled ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        )
        guard status == 0 else { return false }
        isEnabled = enabled
        return true
    }

    deinit {
        _ = setEnabled(false)
    }
}

final class PanelResizeOverlay: NSView {
    private static let resizeEdge: CGFloat = 9
    private static let diagonalNWSE = makeDiagonalCursor(nwse: true)
    private static let diagonalNESW = makeDiagonalCursor(nwse: false)
    private var hoverTrackingArea: NSTrackingArea?
    private var cursorUpdateTrackingArea: NSTrackingArea?
    private var activeHandle: ResizeHandle?
    private var dragAnchor: NSPoint?
    private var initialFrame: CGRect?
    private var resizeVisibleFrame: CGRect?
    private var externalFrames: [CGRect] = []
    private var horizontalSnap = MagneticSnapAxis()
    private var verticalSnap = MagneticSnapAxis()
    private var previousRawX: CGFloat?
    private var previousRawY: CGFloat?
    private var didPushCursor = false
    private var ownsHoverResizeCursor = false
    private let backgroundCursor = BackgroundCursorAuthorization()
    private var backgroundCursorRequested = false
    private var cursorReassertGeneration = 0
    private var pendingCursorReassert: DispatchWorkItem?

    var activeHandleForTesting: ResizeHandle? { activeHandle }
    var isCursorPushedForTesting: Bool { didPushCursor }
    var ownsHoverResizeCursorForTesting: Bool { ownsHoverResizeCursor }
    var backgroundCursorRequestedForTesting: Bool {
        backgroundCursorRequested
    }
    var trackingOptionsForTesting: (
        hover: NSTrackingArea.Options,
        cursorUpdate: NSTrackingArea.Options
    )? {
        guard let hoverTrackingArea, let cursorUpdateTrackingArea else {
            return nil
        }
        return (hoverTrackingArea.options, cursorUpdateTrackingArea.options)
    }
    var lastProposedFrameForTesting: CGRect?
    var resizeVisibleFrameForTesting: CGRect? { resizeVisibleFrame }
    var visibleFrameOverrideForTesting: CGRect?
    var externalFramesOverrideForTesting: [CGRect]?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        return ResizeHandle.at(point: localPoint, in: bounds.size) == nil
            ? nil
            : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        let edge = Self.resizeEdge
        addCursorRect(
            NSRect(x: 0, y: edge, width: edge, height: bounds.height - edge * 2),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: bounds.width - edge, y: edge, width: edge, height: bounds.height - edge * 2),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: edge, y: 0, width: bounds.width - edge * 2, height: edge),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: edge, y: bounds.height - edge, width: bounds.width - edge * 2, height: edge),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: 0, y: 0, width: edge, height: edge),
            cursor: Self.diagonalNESW
        )
        addCursorRect(
            NSRect(x: bounds.width - edge, y: bounds.height - edge, width: edge, height: edge),
            cursor: Self.diagonalNESW
        )
        addCursorRect(
            NSRect(x: bounds.width - edge, y: 0, width: edge, height: edge),
            cursor: Self.diagonalNWSE
        )
        addCursorRect(
            NSRect(x: 0, y: bounds.height - edge, width: edge, height: edge),
            cursor: Self.diagonalNWSE
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        if let cursorUpdateTrackingArea {
            removeTrackingArea(cursorUpdateTrackingArea)
        }
        let hoverTracking = NSTrackingArea(
            rect: bounds,
            options: [
                .activeAlways,
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        let cursorUpdateTracking = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInActiveApp,
                .cursorUpdate,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverTracking)
        addTrackingArea(cursorUpdateTracking)
        hoverTrackingArea = hoverTracking
        cursorUpdateTrackingArea = cursorUpdateTracking
    }

    override func cursorUpdate(with event: NSEvent) {
        if let activeHandle {
            setBackgroundCursor(true)
            cursor(for: activeHandle.cursor).set()
            return
        }
        updateCursor(forWindowPoint: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        guard activeHandle == nil else { return }
        updateCursor(forWindowPoint: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        guard activeHandle == nil else { return }
        updateCursor(forWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        if activeHandle == nil {
            releaseHoverResizeCursor()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if activeHandle != nil || didPushCursor {
            finishResize()
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = ResizeHandle.at(point: point, in: bounds.size) else {
            return
        }
        activeHandle = handle
        (window as? AgentBoardPanel)?
            .isInteractiveGeometryMutation = true
        setBackgroundCursor(true)
        dragAnchor = PanelScreenCoordinates.point(
            for: event,
            in: window
        )
        let fixedVisibleFrame = visibleFrameOverrideForTesting
            ?? window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? window.frame.insetBy(dx: -4_096, dy: -4_096)
        let clampedInitialFrame = NSRect(
            cgRect: BoardPanelGeometry.clamped(
                frame: window.frame,
                visibleFrame: fixedVisibleFrame
            )
        )
        if clampedInitialFrame != window.frame {
            window.setFrame(clampedInitialFrame, display: true)
        }
        initialFrame = clampedInitialFrame
        resizeVisibleFrame = fixedVisibleFrame
        externalFrames = (
            externalFramesOverrideForTesting
                ?? DesktopWindowSnapData.externalFrames(
                    excludingPID: getpid()
                )
        ).filter { $0.intersects(fixedVisibleFrame) }
        horizontalSnap = MagneticSnapAxis()
        verticalSnap = MagneticSnapAxis()
        previousRawX = handle.movesHorizontalEdge
            ? (handle.movesLeft
                ? clampedInitialFrame.minX
                : clampedInitialFrame.maxX)
            : nil
        previousRawY = handle.movesVerticalEdge
            ? (handle.movesBottom
                ? clampedInitialFrame.minY
                : clampedInitialFrame.maxY)
            : nil
        cursor(for: handle.cursor).push()
        didPushCursor = true
        scheduleCursorReassert(expectedHandle: handle)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let handle = activeHandle,
              let dragAnchor,
              let initialFrame,
              let resizeVisibleFrame else {
            return
        }
        let current = PanelScreenCoordinates.point(
            for: event,
            in: window
        )
        let delta = CGSize(
            width: current.x - dragAnchor.x,
            height: current.y - dragAnchor.y
        )
        let rawEdges = PanelResizeGeometry.rawMovingEdges(
            initialFrame: initialFrame,
            handle: handle,
            mouseDelta: delta,
            visibleFrame: resizeVisibleFrame
        )
        let rawFrame = PanelResizeGeometry.frame(
            initialFrame: initialFrame,
            handle: handle,
            movingX: rawEdges.x,
            movingY: rawEdges.y,
            visibleFrame: resizeVisibleFrame
        )
        var movingX = rawEdges.x
        var movingY = rawEdges.y
        if let rawX = rawEdges.x {
            movingX = horizontalSnap.update(
                rawEdge: rawX,
                previousRawEdge: previousRawX,
                candidates: MagneticSnapCandidates.verticalEdges(
                    externalFrames: externalFrames,
                    panelFrame: rawFrame,
                    visibleFrame: resizeVisibleFrame
                )
            )
        }
        if let rawY = rawEdges.y {
            movingY = verticalSnap.update(
                rawEdge: rawY,
                previousRawEdge: previousRawY,
                candidates: MagneticSnapCandidates.horizontalEdges(
                    externalFrames: externalFrames,
                    panelFrame: rawFrame,
                    visibleFrame: resizeVisibleFrame
                )
            )
        }
        let snappedFrame = PanelResizeGeometry.frame(
            initialFrame: initialFrame,
            handle: handle,
            movingX: movingX,
            movingY: movingY,
            visibleFrame: resizeVisibleFrame
        )
        lastProposedFrameForTesting = snappedFrame
        window.setFrame(
            NSRect(cgRect: snappedFrame),
            display: true
        )
        previousRawX = rawEdges.x
        previousRawY = rawEdges.y
        setBackgroundCursor(true)
        cursor(for: handle.cursor).set()
    }

    override func mouseUp(with event: NSEvent) {
        finishResize()
        updateCursor(forWindowPoint: event.locationInWindow)
    }

    override func cancelOperation(_ sender: Any?) {
        finishResize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            finishResize()
        }
    }

    override func removeFromSuperview() {
        finishResize()
        super.removeFromSuperview()
    }

    deinit {
        pendingCursorReassert?.cancel()
        if didPushCursor {
            NSCursor.pop()
        }
        setBackgroundCursor(false)
        NSCursor.arrow.set()
    }

    private func finishResize() {
        pendingCursorReassert?.cancel()
        pendingCursorReassert = nil
        cursorReassertGeneration += 1
        if didPushCursor {
            NSCursor.pop()
        }
        didPushCursor = false
        activeHandle = nil
        (window as? AgentBoardPanel)?
            .isInteractiveGeometryMutation = false
        ownsHoverResizeCursor = false
        setBackgroundCursor(false)
        NSCursor.arrow.set()
        dragAnchor = nil
        initialFrame = nil
        resizeVisibleFrame = nil
        externalFrames = []
        previousRawX = nil
        previousRawY = nil
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    private func updateCursor(forWindowPoint windowPoint: NSPoint) {
        guard let handle = resizeHandle(atWindowPoint: windowPoint) else {
            releaseHoverResizeCursor()
            return
        }
        setBackgroundCursor(true)
        cursor(for: handle.cursor).set()
        ownsHoverResizeCursor = true
        scheduleCursorReassert(expectedHandle: handle)
    }

    func isResizeEdge(atWindowPoint windowPoint: NSPoint) -> Bool {
        resizeHandle(atWindowPoint: windowPoint) != nil
    }

    func claimHoverResizeCursor(atWindowPoint windowPoint: NSPoint) {
        guard activeHandle == nil,
              let handle = resizeHandle(atWindowPoint: windowPoint) else {
            return
        }
        setBackgroundCursor(true)
        cursor(for: handle.cursor).set()
        ownsHoverResizeCursor = true
        scheduleCursorReassert(expectedHandle: handle)
    }

    func routeHoverCursor(atScreenPoint point: NSPoint) {
        guard activeHandle == nil else { return }
        guard let window, window.isVisible, window.frame.contains(point)
        else {
            releaseHoverResizeCursor()
            return
        }
        let topWindowNumber = NSWindow.windowNumber(
            at: point,
            belowWindowWithWindowNumber: 0
        )
        guard topWindowNumber == window.windowNumber else {
            releaseHoverResizeCursor()
            return
        }
        let windowPoint = window.convertPoint(fromScreen: point)
        if isResizeEdge(atWindowPoint: windowPoint) {
            claimHoverResizeCursor(atWindowPoint: windowPoint)
        } else {
            releaseHoverResizeCursor()
        }
    }

    func releaseHoverResizeCursor() {
        pendingCursorReassert?.cancel()
        pendingCursorReassert = nil
        cursorReassertGeneration += 1
        guard ownsHoverResizeCursor else {
            if activeHandle == nil {
                setBackgroundCursor(false)
            }
            return
        }
        ownsHoverResizeCursor = false
        if activeHandle == nil {
            setBackgroundCursor(false)
            NSCursor.arrow.set()
        }
    }

    func shutdownCursor() {
        finishResize()
    }

    private func setBackgroundCursor(_ enabled: Bool) {
        backgroundCursorRequested = enabled
        _ = backgroundCursor.setEnabled(enabled)
    }

    private func scheduleCursorReassert(expectedHandle: ResizeHandle) {
        pendingCursorReassert?.cancel()
        cursorReassertGeneration += 1
        let generation = cursorReassertGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.cursorReassertGeneration,
                  let window = self.window,
                  window.isVisible else {
                return
            }
            if let activeHandle = self.activeHandle {
                self.setBackgroundCursor(true)
                self.cursor(for: activeHandle.cursor).set()
                return
            }
            let mouse = NSEvent.mouseLocation
            guard window.frame.contains(mouse),
                  NSWindow.windowNumber(
                      at: mouse,
                      belowWindowWithWindowNumber: 0
                  ) == window.windowNumber else {
                self.releaseHoverResizeCursor()
                return
            }
            let windowPoint = window.convertPoint(fromScreen: mouse)
            guard let handle = self.resizeHandle(
                atWindowPoint: windowPoint
            ), handle == expectedHandle else {
                self.releaseHoverResizeCursor()
                return
            }
            self.setBackgroundCursor(true)
            self.cursor(for: handle.cursor).set()
            self.ownsHoverResizeCursor = true
        }
        pendingCursorReassert = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.03,
            execute: work
        )
    }

    private func resizeHandle(
        atWindowPoint windowPoint: NSPoint
    ) -> ResizeHandle? {
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point) else { return nil }
        return ResizeHandle.at(point: point, in: bounds.size)
    }

    private func cursor(for direction: ResizeCursorDirection) -> NSCursor {
        switch direction {
        case .diagonalNESW:
            return Self.diagonalNESW
        case .diagonalNWSE:
            return Self.diagonalNWSE
        case .leftRight:
            return .resizeLeftRight
        case .upDown:
            return .resizeUpDown
        case .arrow:
            return .arrow
        }
    }

    private static func makeDiagonalCursor(nwse: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()

        let start = nwse
            ? NSPoint(x: 6, y: 18)
            : NSPoint(x: 18, y: 18)
        let end = nwse
            ? NSPoint(x: 18, y: 6)
            : NSPoint(x: 6, y: 6)
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)

        if nwse {
            path.move(to: NSPoint(x: start.x + 5, y: start.y))
            path.line(to: start)
            path.line(to: NSPoint(x: start.x, y: start.y - 5))
            path.move(to: NSPoint(x: end.x - 5, y: end.y))
            path.line(to: end)
            path.line(to: NSPoint(x: end.x, y: end.y + 5))
        } else {
            path.move(to: NSPoint(x: start.x - 5, y: start.y))
            path.line(to: start)
            path.line(to: NSPoint(x: start.x, y: start.y - 5))
            path.move(to: NSPoint(x: end.x + 5, y: end.y))
            path.line(to: end)
            path.line(to: NSPoint(x: end.x, y: end.y + 5))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 4
        NSColor.white.setStroke()
        path.stroke()
        path.lineWidth = 2
        NSColor.black.setStroke()
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    let panel: AgentBoardPanel
    private(set) var resizeOverlay: PanelResizeOverlay?
    private let model: BoardViewModel
    private let defaults: UserDefaults
    private let pinChanged: (Bool) -> Void
    private let keyDownCounter: () -> UInt32
    private var renameCoordinator: RenameTitleCoordinator?
    private var localCursorMonitor: Any?
    private var globalCursorMonitor: Any?
    private var isNormalizingFrame = false
    private let headerDragCancellation = HeaderDragCancellationState()
    private var headerDragStartKeyDownCount: UInt32?
    private var collapsedHandlePanel: CollapsedHandlePanel?
    private var collapsedEdge: PanelHorizontalEdge?
    private var collapsedReferenceFrame: NSRect?

    init(
        model: BoardViewModel,
        defaults: UserDefaults,
        onQuit: @escaping () -> Void,
        pinChanged: @escaping (Bool) -> Void,
        keyDownCounter: @escaping () -> UInt32 = {
            CGEventSource.counterForEventType(
                .combinedSessionState,
                eventType: .keyDown
            )
        }
    ) {
        self.model = model
        self.defaults = defaults
        self.pinChanged = pinChanged
        self.keyDownCounter = keyDownCounter
        panel = AgentBoardPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: BoardPanelGeometry.defaultSize.width,
                height: BoardPanelGeometry.defaultSize.height
            ),
            styleMask: [
                .nonactivatingPanel,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel(onQuit: onQuit)
    }

    func showPanel() {
        finishHeaderDragCancellation()
        closeCollapsedHandle()
        clampAndRestoreFrame()
        panel.orderFrontRegardless()
    }

    func hidePanel() {
        finishHeaderDragCancellation()
        resizeOverlay?.shutdownCursor()
        panel.orderOut(nil)
        closeCollapsedHandle()
    }

    func shutdownCursor() {
        finishHeaderDragCancellation()
        resizeOverlay?.shutdownCursor()
    }

    func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    deinit {
        resizeOverlay?.shutdownCursor()
        collapsedHandlePanel?.orderOut(nil)
        collapsedHandlePanel?.close()
        if let localCursorMonitor {
            NSEvent.removeMonitor(localCursorMonitor)
        }
        if let globalCursorMonitor {
            NSEvent.removeMonitor(globalCursorMonitor)
        }
    }

    func applyPin(_ pinned: Bool) {
        panel.level = pinned ? .floating : .normal
        collapsedHandlePanel?.level = panel.level
        model.pinned = pinned
    }

    func clampToVisibleScreen() {
        if collapsedHandlePanel?.isVisible == true {
            positionCollapsedHandle()
            return
        }
        clampAndRestoreFrame()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hidePanel()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        normalizePanelFrameIfNeeded()
        if panel.isInteractiveGeometryMutation { saveFrame() }
    }

    func windowDidResize(_ notification: Notification) {
        normalizePanelFrameIfNeeded()
        if panel.isInteractiveGeometryMutation { saveFrame() }
    }

    func beginHeaderDragCancellation() {
        if headerDragCancellation.isActive {
            finishHeaderDragCancellation()
        }
        headerDragCancellation.begin()
        headerDragStartKeyDownCount = keyDownCounter()
    }

    func cancelHeaderDragFromEscape() {
        _ = headerDragCancellation.cancel()
    }

    func finishHeaderDragCancellation() {
        _ = headerDragCancellation.finish()
        headerDragStartKeyDownCount = nil
    }

    func handleHeaderDragEnded(
        displayedFrame: NSRect,
        rawFrame: CGRect,
        mouseDelta: CGSize,
        pointer: CGPoint,
        startVisibleFrame: CGRect,
        visibleFrames: [CGRect],
        fallbackVisibleFrame: CGRect
    ) {
        if let headerDragStartKeyDownCount {
            _ = headerDragCancellation.cancelIfKeyInput(
                startedAt: headerDragStartKeyDownCount,
                endedAt: keyDownCounter()
            )
        }
        guard panel.isVisible,
              !visibleFrames.isEmpty,
              !headerDragCancellation.isCancelled else {
            return
        }
        let targetVisibleFrame =
            MultiScreenGeometry.targetVisibleFrame(
                pointer: pointer,
                proposedFrame: rawFrame,
                visibleFrames: visibleFrames,
                fallback: fallbackVisibleFrame
            )
        guard let edge = PanelEdgeCollapseGeometry.collapseEdge(
            displayedFrame: displayedFrame,
            rawFrame: rawFrame,
            mouseDelta: mouseDelta,
            pointer: pointer,
            startVisibleFrame: startVisibleFrame,
            targetVisibleFrame: targetVisibleFrame
        ) else {
            return
        }
        collapseToHandle(
            edge: edge,
            visibleFrame: targetVisibleFrame,
            referenceFrame: displayedFrame
        )
    }

    private func configurePanel(onQuit: @escaping () -> Void) {
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = model.pinned
        panel.level = model.pinned ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = "AgentBoard"
        panel.setAccessibilityIdentifier("app.agentboard.panel")
        panel.applyAccessibilityFrame = { [weak self] frame in
            guard let self, let visible = self.bestScreen(for: frame)?.visibleFrame else { return }
            // AX requests are explicit edits. Transient system clamps must not replace this preference.
            let normalized = BoardPanelGeometry.clamped(frame: frame, visibleFrame: visible)
            self.panel.setFrame(NSRect(cgRect: normalized), display: true)
            self.saveFrame()
        }
        panel.minSize = NSSize(
            width: BoardPanelGeometry.minimumSize.width,
            height: BoardPanelGeometry.minimumSize.height
        )
        panel.maxSize = NSSize(width: 10_000, height: 10_000)
        panel.delegate = self

        let root = BoardView(
            model: model,
            onRenameTitle: { [weak self] card in
                self?.presentTitleRename(card)
            },
            onHide: { [weak self] in self?.hidePanel() },
            onTogglePin: { [weak self] in
                guard let self else { return }
                let pinned = !self.model.pinned
                self.applyPin(pinned)
                self.pinChanged(pinned)
            },
            onQuit: onQuit
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.autoresizingMask = [.width, .height]
        let contentContainer = PanelContentView(
            frame: NSRect(
                origin: .zero,
                size: panel.contentLayoutRect.size
            )
        )
        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = 16
        contentContainer.layer?.masksToBounds = true
        hostingView.frame = contentContainer.bounds
        contentContainer.addSubview(hostingView)
        let resizeOverlay = PanelResizeOverlay(frame: hostingView.bounds)
        resizeOverlay.autoresizingMask = [.width, .height]
        contentContainer.addSubview(resizeOverlay)
        panel.contentView = contentContainer
        panel.resizeCursorOverlay = resizeOverlay
        self.resizeOverlay = resizeOverlay
        clampAndRestoreFrame()
        installCursorFallbackMonitors()
    }

    private func installCursorFallbackMonitors() {
        localCursorMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate]
        ) { [weak self] event in
            guard self != nil else { return event }
            let screenPoint = PanelScreenCoordinates.point(
                for: event,
                in: nil
            )
            DispatchQueue.main.async { [weak self] in
                self?.routeCursorFallback(atScreenPoint: screenPoint)
            }
            return event
        }
        globalCursorMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved]
        ) { [weak self] event in
            let screenPoint = PanelScreenCoordinates.point(
                for: event,
                in: nil
            )
            if Thread.isMainThread {
                self?.routeCursorFallback(atScreenPoint: screenPoint)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.routeCursorFallback(atScreenPoint: screenPoint)
                }
            }
        }
    }

    private func routeCursorFallback(atScreenPoint point: NSPoint) {
        resizeOverlay?.routeHoverCursor(atScreenPoint: point)
    }

    private func presentTitleRename(_ card: AgentCard) {
        renameCoordinator?.cancel()
        let coordinator = RenameTitleCoordinator(
            model: model,
            card: card,
            parent: panel
        )
        renameCoordinator = coordinator
        coordinator.onFinish = { [weak self] in
            self?.renameCoordinator = nil
        }
        coordinator.present()
    }

    private func collapseToHandle(
        edge: PanelHorizontalEdge,
        visibleFrame: CGRect,
        referenceFrame: NSRect
    ) {
        renameCoordinator?.cancel()
        renameCoordinator = nil
        resizeOverlay?.shutdownCursor()
        saveFrame()
        collapsedEdge = edge
        collapsedReferenceFrame = referenceFrame
        panel.orderOut(nil)
        showCollapsedHandle(
            edge: edge,
            visibleFrame: visibleFrame,
            referenceFrame: referenceFrame
        )
    }

    private func showCollapsedHandle(
        edge: PanelHorizontalEdge,
        visibleFrame: CGRect,
        referenceFrame: NSRect
    ) {
        closeCollapsedHandle(clearPlacement: false)
        let size = PanelEdgeCollapseGeometry.handleSize
        let handle = CollapsedHandlePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let view = CollapsedHandleView(
            frame: NSRect(origin: .zero, size: size),
            pointsLeft: edge == .right
        )
        view.onActivate = { [weak self] in
            self?.restoreCollapsedPanel()
        }
        handle.contentView = view
        handle.isReleasedWhenClosed = false
        handle.isOpaque = false
        handle.backgroundColor = .clear
        handle.hasShadow = true
        handle.hidesOnDeactivate = false
        handle.animationBehavior = .none
        handle.level = panel.level
        handle.collectionBehavior = panel.collectionBehavior
        handle.title = "AgentBoard 펼치기"
        let frame = PanelEdgeCollapseGeometry.handleFrame(
            edge: edge,
            visibleFrame: visibleFrame,
            referenceFrame: referenceFrame,
            size: size
        )
        handle.setFrame(NSRect(cgRect: frame), display: true)
        collapsedHandlePanel = handle
        handle.orderFrontRegardless()
        view.window?.invalidateCursorRects(for: view)
    }

    private func restoreCollapsedPanel() {
        showPanel()
    }

    private func positionCollapsedHandle() {
        guard let handle = collapsedHandlePanel,
              let edge = collapsedEdge else {
            return
        }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let reference = collapsedReferenceFrame ?? panel.frame
        let fallback = NSScreen.main?.visibleFrame
            ?? visibleFrames.first
            ?? defaultFrame()
        let target = MultiScreenGeometry.visibleFrame(
            containing: CGPoint(x: reference.midX, y: reference.midY),
            in: visibleFrames,
            fallback: fallback
        )
        let frame = PanelEdgeCollapseGeometry.handleFrame(
            edge: edge,
            visibleFrame: target,
            referenceFrame: reference
        )
        handle.setFrame(NSRect(cgRect: frame), display: true)
        handle.level = panel.level
    }

    private func closeCollapsedHandle(
        clearPlacement: Bool = true
    ) {
        if let handle = collapsedHandlePanel {
            handle.orderOut(nil)
            handle.close()
        }
        collapsedHandlePanel = nil
        if clearPlacement {
            collapsedEdge = nil
            collapsedReferenceFrame = nil
        }
    }

    private func clampAndRestoreFrame() {
        let stored = defaults.string(forKey: "AgentBoard.panelFrame")
            .map(NSRectFromString)
        var frame = stored ?? defaultFrame()
        let screen = bestScreen(for: frame)
        guard let visible = screen?.visibleFrame else { return }
        frame = NSRect(
            cgRect: BoardPanelGeometry.clamped(
                frame: frame,
                visibleFrame: visible
            )
        )
        panel.setFrame(frame, display: true)
    }

    private func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        return NSRect(
            x: visible.maxX - BoardPanelGeometry.defaultSize.width - 18,
            y: visible.maxY - BoardPanelGeometry.defaultSize.height - 26,
            width: BoardPanelGeometry.defaultSize.width,
            height: BoardPanelGeometry.defaultSize.height
        )
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        let largestIntersection = screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area
                < rhs.visibleFrame.intersection(frame).area
        }
        if let largestIntersection,
           largestIntersection.visibleFrame.intersection(frame).area > 0 {
            return largestIntersection
        }
        return screens.min {
            distance(from: $0.visibleFrame, to: frame)
                < distance(from: $1.visibleFrame, to: frame)
        }
    }

    private func distance(from rect: NSRect, to frame: NSRect) -> CGFloat {
        abs(rect.midX - frame.midX) + abs(rect.midY - frame.midY)
    }

    private func saveFrame() {
        let frame = panel.frame
        defaults.set(
            NSStringFromRect(frame),
            forKey: "AgentBoard.panelFrame"
        )
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let visible = bestScreen(for: sender.frame)?.visibleFrame
            ?? sender.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        guard let visible else { return frameSize }
        let constrained = NSSize(
            from: BoardPanelGeometry.constrainedResize(
                proposed: frameSize,
                visibleFrame: visible
            )
        )
        let maxWidth = max(
            BoardPanelGeometry.minimumSize.width,
            visible.maxX - sender.frame.minX
        )
        let maxHeight = max(
            BoardPanelGeometry.minimumSize.height,
            visible.maxY - sender.frame.minY
        )
        return NSSize(
            width: min(constrained.width, maxWidth),
            height: min(constrained.height, maxHeight)
        )
    }

    private func normalizePanelFrameIfNeeded() {
        guard !panel.isInteractiveGeometryMutation,
              !isNormalizingFrame,
              let visible = bestScreen(for: panel.frame)?.visibleFrame
        else {
            return
        }
        let normalized = NSRect(
            cgRect: BoardPanelGeometry.clamped(
                frame: panel.frame,
                visibleFrame: visible
            )
        )
        guard normalized != panel.frame else { return }
        isNormalizingFrame = true
        panel.setFrame(normalized, display: true)
        isNormalizingFrame = false
    }
}

private extension NSSize {
    init(from size: CGSize) {
        self.init(width: size.width, height: size.height)
    }
}

private extension NSRect {
    init(cgRect: CGRect) {
        self.init(
            x: cgRect.origin.x,
            y: cgRect.origin.y,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
