import AgentBoardCore
import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

private var checks = 0
private var failures: [String] = []

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() {
        failures.append(message)
    }
}

private func mouseEvent(
    _ type: NSEvent.EventType,
    locationInWindow: NSPoint,
    window: NSWindow
) -> NSEvent {
    NSEvent.mouseEvent(
        with: type,
        location: locationInWindow,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseDown ? 1 : 0
    ) ?? NSEvent.otherEvent(
        with: .appKitDefined,
        location: locationInWindow,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        subtype: 0,
        data1: 0,
        data2: 0
    )!
}

_ = NSApplication.shared

let launchHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentBoardLaunchHome-\(UUID().uuidString)")
let defaultCodex = launchHome.appendingPathComponent(".codex")
let defaultDS = launchHome.appendingPathComponent(".codex-ds")
let environmentCodex = launchHome.appendingPathComponent("custom env")
try FileManager.default.createDirectory(at: defaultCodex, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: defaultDS, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: environmentCodex, withIntermediateDirectories: true)
let automaticOptions = try LaunchOptions.parse(
    ["AgentBoard"],
    environment: ["CODEX_HOME": environmentCodex.path],
    homeDirectory: launchHome
)
check(
    automaticOptions.codexHomes == [
        defaultCodex.resolvingSymlinksInPath(),
        defaultDS.resolvingSymlinksInPath(),
        environmentCodex.resolvingSymlinksInPath()
    ],
    "automatic Codex homes should include .codex, .codex-ds, and CODEX_HOME"
)

let explicitA = launchHome.appendingPathComponent("home A")
let explicitB = launchHome.appendingPathComponent("home B")
try FileManager.default.createDirectory(at: explicitA, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: explicitB, withIntermediateDirectories: true)
let explicitLink = launchHome.appendingPathComponent("home B link")
try FileManager.default.createSymbolicLink(
    at: explicitLink,
    withDestinationURL: explicitB
)
let explicitOptions = try LaunchOptions.parse(
    [
        "AgentBoard",
        "--codex-home", explicitA.path,
        "--codex-home=\(explicitB.path)",
        "--codex-home", explicitLink.path
    ],
    environment: ["CODEX_HOME": environmentCodex.path],
    homeDirectory: launchHome
)
check(
    explicitOptions.codexHomes == [
        explicitA.resolvingSymlinksInPath(),
        explicitB.resolvingSymlinksInPath()
    ],
    "explicit repeated homes should replace automatic homes and deduplicate symlinks"
)
check(
    explicitOptions.codexHome == explicitA.resolvingSymlinksInPath(),
    "legacy single codexHome accessor should return the first explicit home"
)

let reorderPayload = CardReorderPayload(
    boardIdentifier: "board-only",
    cardId: UUID(uuidString: "12345678-1234-4234-8234-123456789ABC")!
)
let reorderPayloadData = try JSONEncoder().encode(reorderPayload)
let decodedReorderPayload = try JSONDecoder().decode(
    CardReorderPayload.self,
    from: reorderPayloadData
)
check(
    decodedReorderPayload == reorderPayload,
    "card reorder payload should round-trip as strict JSON"
)
check(
    CardReorderPasteboard.dropTypes.map(\.identifier)
        == [UTType.utf8PlainText.identifier],
    "reorder drag should use the standard UTF-8 text bridge type"
)
let reorderPasteboardItem = CardReorderPasteboard.item(
    data: reorderPayloadData
)
check(
    reorderPasteboardItem.types.contains(
        NSPasteboard.PasteboardType(
            UTType.utf8PlainText.identifier
        )
    ),
    "native drag should publish standard UTF-8 text"
)
check(
    CardSwipeGeometry.threshold(cardWidth: 320) == 96,
    "card swipe threshold should cap at 96pt for a 320pt card"
)
check(
    abs(CardSwipeGeometry.threshold(cardWidth: 240) - 72) < 0.01,
    "card swipe threshold should use 30 percent of narrower cards"
)
check(
    CardSwipeGeometry.hasHorizontalIntent(
        CGSize(width: -60, height: 20)
    ),
    "clearly horizontal card drags should be recognized as swipe intent"
)
check(
    !CardSwipeGeometry.hasHorizontalIntent(
        CGSize(width: 40, height: 40)
    ),
    "diagonal card drags without horizontal dominance should defer to scrolling and clicks"
)
check(
    CardSwipeGeometry.shouldArchive(
        translation: CGSize(width: 96, height: 8),
        cardWidth: 320
    ),
    "a rightward threshold swipe should request card archive"
)
check(
    CardSwipeGeometry.shouldArchive(
        translation: CGSize(width: -90, height: 5),
        cardWidth: 240
    ),
    "leftward swipes should archive using the same width-aware threshold"
)
check(
    !CardSwipeGeometry.shouldArchive(
        translation: CGSize(width: 60, height: 4),
        cardWidth: 320
    ),
    "small card drags should restore without archiving"
)
var cardDirectionLock = CardDragDirectionLock()
cardDirectionLock.update(
    translation: CGSize(width: 12, height: 2)
)
check(
    cardDirectionLock.direction == .horizontal,
    "card drag should lock horizontal once horizontal intent is clear"
)
cardDirectionLock.update(
    translation: CGSize(width: 12, height: 120)
)
check(
    cardDirectionLock.direction == .horizontal,
    "card drag direction should not switch after it has been locked"
)
cardDirectionLock.reset()
cardDirectionLock.update(
    translation: CGSize(width: 2, height: 12)
)
check(
    cardDirectionLock.direction == .vertical,
    "card drag should lock vertical for native reorder"
)
cardDirectionLock.reset()
cardDirectionLock.update(
    translation: CGSize(width: 8, height: 8)
)
check(
    cardDirectionLock.direction == nil,
    "ambiguous movement before direction lock should preserve normal click semantics"
)

let cardPointerWindow = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 320, height: 140),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
cardPointerWindow.isReleasedWhenClosed = false
let cardPointerHost = NSView(
    frame: NSRect(x: 0, y: 0, width: 320, height: 140)
)
cardPointerWindow.contentView = cardPointerHost
let cardPointerSurface = CardPointerSurfaceView(
    frame: NSRect(x: 0, y: 10, width: 300, height: 110)
)
cardPointerSurface.cardId = UUID()
cardPointerSurface.boardIdentifier = "board"
cardPointerSurface.excludedFrames = [
    CGRect(x: 220, y: 0, width: 70, height: 50)
]
cardPointerSurface.tapFrames = [
    CGRect(x: 0, y: 0, width: 200, height: 40)
]
cardPointerHost.addSubview(cardPointerSurface)
check(
    cardPointerSurface.acceptsFirstMouse(for: nil),
    "card pointer surface should accept the first mouse in a nonactivating panel"
)
check(
    cardPointerSurface.hitTest(NSPoint(x: 40, y: 40))
        === cardPointerSurface,
    "card safe area should be owned by the native pointer surface"
)
check(
    cardPointerSurface.hitTest(NSPoint(x: 230, y: 80)) == nil,
    "menu and completed-read control frames should pass through the native surface"
)
var cardPointerSwipes: [CGFloat] = []
var cardPointerTapCount = 0
cardPointerSurface.onTap = {
    cardPointerTapCount += 1
}
cardPointerSurface.onSwipeChanged = {
    cardPointerSwipes.append($0)
}
cardPointerSurface.onSwipeEnded = { translation, _ in
    cardPointerSwipes.append(translation.width)
}
cardPointerSurface.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 40, y: 80),
        window: cardPointerWindow
    )
)
cardPointerSurface.mouseDragged(
    with: mouseEvent(
        .leftMouseDragged,
        locationInWindow: NSPoint(x: 170, y: 83),
        window: cardPointerWindow
    )
)
cardPointerSurface.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 170, y: 83),
        window: cardPointerWindow
    )
)
check(
    cardPointerSwipes.contains(130),
    "native card body drag should report horizontal swipe translation"
)
check(
    cardPointerTapCount == 0,
    "a completed horizontal swipe must not also toggle the card"
)
cardPointerSurface.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 40, y: 100),
        window: cardPointerWindow
    )
)
cardPointerSurface.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 40, y: 100),
        window: cardPointerWindow
    )
)
check(
    cardPointerTapCount == 1,
    "a short native card click should preserve the existing toggle action"
)
cardPointerSurface.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 40, y: 50),
        window: cardPointerWindow
    )
)
cardPointerSurface.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 40, y: 50),
        window: cardPointerWindow
    )
)
check(
    cardPointerTapCount == 1,
    "a short click in expanded body area should not collapse the card"
)
cardPointerWindow.close()

let reorderCardA = UUID(
    uuidString: "11111111-2222-4333-8444-555555555555"
)!
let reorderCardB = UUID(
    uuidString: "66666666-7777-4888-8999-AAAAAAAAAAAA"
)!
let reorderLifecycle = CardReorderDragLifecycle()
let firstDragToken = reorderLifecycle.begin(cardId: reorderCardA)
check(firstDragToken != nil,
      "a new native drag session should acquire the reorder lifecycle")
check(reorderLifecycle.begin(cardId: reorderCardB) == nil,
      "one source card should own the reorder lifecycle at a time")
let firstDropToken = reorderLifecycle.beginDropCommit(cardId: reorderCardA)
check(firstDropToken == firstDragToken,
      "drop commit should retain the native session token")
check(!reorderLifecycle.sessionEnded(
    cardId: reorderCardA,
    allowsMove: true
), "a move session ending before async data should wait for its commit")
check(reorderLifecycle.isDropCommitAuthorized(
    firstDropToken!,
    cardId: reorderCardA
), "session-ended move should not invalidate a pending async commit")
check(reorderLifecycle.finishDropCommit(
    firstDropToken!,
    cardId: reorderCardA
), "the delayed commit should finish after the native session ended")
check(reorderLifecycle.activeCardId == nil,
      "a completed delayed commit should release drag ownership")
check(reorderLifecycle.begin(cardId: reorderCardB) != nil,
      "another drag should begin after a normal native drop")

let cancelToken = reorderLifecycle.beginDropCommit(cardId: reorderCardB)
check(cancelToken != nil,
      "the second drag should be able to enter drop commit")
check(reorderLifecycle.sessionEnded(
    cardId: reorderCardB,
    allowsMove: false
), "an outside-drop or Escape cancellation should clean up immediately")
check(!reorderLifecycle.isDropCommitAuthorized(
    cancelToken!,
    cardId: reorderCardB
), "a canceled session must reject its stale async payload")
check(!reorderLifecycle.finishDropCommit(
    cancelToken!,
    cardId: reorderCardB
), "a stale payload must not finish after cancellation")
check(reorderLifecycle.begin(cardId: reorderCardA) != nil,
      "a canceled drag should permit a fresh drag")

let retryToken = reorderLifecycle.beginDropCommit(cardId: reorderCardA)
check(retryToken != nil,
      "the fresh drag should be able to start its own drop commit")
check(reorderLifecycle.finishDropCommit(
    retryToken!,
    cardId: reorderCardA
), "commit before native session end should succeed")
check(!reorderLifecycle.sessionEnded(
    cardId: reorderCardA,
    allowsMove: true
), "a late session-ended callback should be stale after cleanup")

let accessibilityHandle = ReorderHandleView(
    frame: NSRect(x: 0, y: 0, width: 22, height: 20)
)
accessibilityHandle.setAccessibilityLabel("카드 순서 변경")
check(accessibilityHandle.isAccessibilityElement(),
      "the native reorder handle should be an accessibility element")
check(accessibilityHandle.accessibilityLabel() == "카드 순서 변경",
      "the native reorder handle should expose its drag label")
check(accessibilityHandle.acceptsFirstMouse(for: nil),
      "the reorder handle should accept the first mouse in an inactive panel")
check(
    ReorderHandleView.sourceOperationMask(
        for: .withinApplication
    ) == .move,
    "reorder drag should permit moves inside AgentBoard"
)
check(
    ReorderHandleView.sourceOperationMask(
        for: .outsideApplication
    ).isEmpty,
    "reorder drag must expose no pasteboard operation outside AgentBoard"
)

let headerCancellation = HeaderDragCancellationState()
headerCancellation.begin()
check(
    headerCancellation.isActive && !headerCancellation.isCancelled,
    "header drag cancellation should begin in an uncancelled state"
)
check(
    headerCancellation.cancel(),
    "Escape should be able to cancel an active header drag once"
)
check(
    !headerCancellation.cancel(),
    "duplicate Escape delivery should not restart or toggle cancellation"
)
check(
    headerCancellation.finish(),
    "mouseUp after Escape should observe cancellation and release the drag state"
)
check(
    !headerCancellation.isActive && !headerCancellation.isCancelled,
    "ending a cancelled header drag should fully reset lifecycle state"
)
headerCancellation.begin()
check(
    !headerCancellation.isCancelled,
    "a fresh drag should start without inherited Escape cancellation"
)
check(
    !headerCancellation.finish(),
    "a normal header drag should finish without a collapse cancellation"
)
let keyInputCancellation = HeaderDragCancellationState()
keyInputCancellation.begin()
check(
    !keyInputCancellation.cancelIfKeyInput(
        startedAt: 512_882,
        endedAt: 512_882
    ),
    "an unchanged keyDown counter should allow normal drag completion"
)
check(
    keyInputCancellation.cancelIfKeyInput(
        startedAt: 512_882,
        endedAt: 512_883
    ),
    "a completed Escape down/up should cancel collapse through the keyDown counter"
)
check(
    keyInputCancellation.finish(),
    "keyDown-counter cancellation should survive until mouseUp finishes the drag"
)

let collapsedHandleHost = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 22, height: 72),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
collapsedHandleHost.isReleasedWhenClosed = false
let collapsedHandleView = CollapsedHandleView(
    frame: NSRect(x: 0, y: 0, width: 22, height: 72),
    pointsLeft: false
)
collapsedHandleHost.contentView = collapsedHandleView
var collapsedHandleActivated = false
collapsedHandleView.onActivate = {
    collapsedHandleActivated = true
}
check(
    collapsedHandleView.acceptsFirstMouse(for: nil),
    "collapsed AgentBoard handle should accept its first click in a nonactivating panel"
)
check(
    collapsedHandleView.accessibilityLabel() == "AgentBoard 펼치기",
    "collapsed AgentBoard handle should expose its restore accessibility label"
)
check(
    collapsedHandleView.accessibilityPerformPress(),
    "collapsed AgentBoard handle should support an accessibility press action"
)
check(
    collapsedHandleActivated,
    "accessibility press should trigger collapsed board restoration"
)
collapsedHandleActivated = false
collapsedHandleView.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 11, y: 36),
        window: collapsedHandleHost
    )
)
check(
    collapsedHandleActivated,
    "collapsed AgentBoard handle should request board restoration on first click"
)
collapsedHandleHost.close()

let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))

let dragView = WindowDragRegion.DragView(
    frame: NSRect(x: 40, y: 30, width: 240, height: 44)
)
container.addSubview(dragView)
check(
    dragView.hitTest(NSPoint(x: 50, y: 40)) === dragView,
    "header hit-test should convert superview point to local coordinates"
)
check(
    dragView.hitTest(NSPoint(x: 10, y: 10)) == nil,
    "header hit-test should reject point outside nonzero-origin frame"
)

let resizeOverlay = PanelResizeOverlay(
    frame: NSRect(x: 35, y: 25, width: 320, height: 260)
)
container.addSubview(resizeOverlay)
check(
    resizeOverlay.hitTest(NSPoint(x: 35, y: 35)) === resizeOverlay,
    "resize border hit-test should work with nonzero superview origin"
)
check(
    resizeOverlay.hitTest(NSPoint(x: 135, y: 135)) == nil,
    "resize overlay interior should pass through"
)

let convertedCG = PanelScreenCoordinates.appKitPoint(
    fromCoreGraphics: CGPoint(x: 120, y: 80),
    primaryDisplayHeight: 900
)
check(
    convertedCG == NSPoint(x: 120, y: 820),
    "event-stamped CG location should convert to AppKit coordinates"
)
let stampedCGEvent = CGEvent(
    mouseEventSource: nil,
    mouseType: .leftMouseDragged,
    mouseCursorPosition: CGPoint(x: 500, y: 300),
    mouseButton: .left
)!
let stampedNSEvent = NSEvent(cgEvent: stampedCGEvent)!
let stampedPoint = PanelScreenCoordinates.point(
    for: stampedNSEvent,
    in: nil
)
check(
    stampedPoint == NSPoint(
        x: 500,
        y: PanelScreenCoordinates.primaryDisplayHeight() - 300
    ),
    "handler location helper should prefer event-stamped CG coordinates"
)

let dragWindow = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 360, height: 480),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
dragWindow.isReleasedWhenClosed = false
let dragContent = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 480))
dragWindow.contentView = dragContent
let eventDragView = WindowDragRegion.DragView(
    frame: NSRect(x: 20, y: 400, width: 240, height: 44)
)
eventDragView.visibleFramesOverrideForTesting = [
    CGRect(x: 0, y: 0, width: 2_000, height: 2_000)
]
eventDragView.externalFramesOverrideForTesting = []
dragContent.addSubview(eventDragView)
let dragStartScreen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
eventDragView.visibleFramesOverrideForTesting = [
    dragStartScreen,
    CGRect(x: 1_200, y: 0, width: 1_200, height: 800)
]
eventDragView.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 50, y: 420),
        window: dragWindow
    )
)
check(
    eventDragView.dragStartVisibleFrameForTesting == dragStartScreen,
    "header drag event should capture the mouseDown screen before movement"
)
eventDragView.cancelOperation(nil)
eventDragView.visibleFramesOverrideForTesting = [
    CGRect(x: 0, y: 0, width: 2_000, height: 2_000)
]
let dragStart = dragWindow.frame.origin
eventDragView.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 50, y: 420),
        window: dragWindow
    )
)
eventDragView.mouseDragged(
    with: mouseEvent(
        .leftMouseDragged,
        locationInWindow: NSPoint(x: 50, y: 520),
        window: dragWindow
    )
)
eventDragView.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 50, y: 520),
        window: dragWindow
    )
)
check(
    abs(dragWindow.frame.origin.y - (dragStart.y + 100)) < 0.5,
    "constructed header events should move the offscreen window upward: frame=\(dragWindow.frame) proposed=\(String(describing: eventDragView.lastProposedFrameForTesting))"
)

let snapMoveWindow = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 360, height: 480),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
snapMoveWindow.isReleasedWhenClosed = false
let snapMoveContent = NSView(
    frame: NSRect(x: 0, y: 0, width: 360, height: 480)
)
snapMoveWindow.contentView = snapMoveContent
let snapDragView = WindowDragRegion.DragView(
    frame: NSRect(x: 20, y: 400, width: 240, height: 44)
)
snapDragView.visibleFramesOverrideForTesting = [
    CGRect(x: 0, y: 0, width: 1_200, height: 800)
]
snapDragView.externalFramesOverrideForTesting = [
    CGRect(x: 600, y: 200, width: 500, height: 200)
]
snapMoveContent.addSubview(snapDragView)
snapDragView.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 50, y: 420),
        window: snapMoveWindow
    )
)
snapDragView.mouseDragged(
    with: mouseEvent(
        .leftMouseDragged,
        locationInWindow: NSPoint(x: 200, y: 420),
        window: snapMoveWindow
    )
)
check(
    abs((snapDragView.lastProposedFrameForTesting?.minX ?? -1) - 240) < 0.5,
    "fast header drag crossing an external edge should latch the moving panel: frame=\(String(describing: snapDragView.lastProposedFrameForTesting))"
)
snapDragView.mouseDragged(
    with: mouseEvent(
        .leftMouseDragged,
        locationInWindow: NSPoint(x: 350, y: 420),
        window: snapMoveWindow
    )
)
check(
    abs((snapDragView.lastProposedFrameForTesting?.minX ?? -1) - 400) < 0.5,
    "moving more than 20pt from the latched edge should break out: frame=\(String(describing: snapDragView.lastProposedFrameForTesting))"
)
snapDragView.mouseDragged(
    with: mouseEvent(
        .leftMouseDragged,
        locationInWindow: NSPoint(x: 1_250, y: 420),
        window: snapMoveWindow
    )
)
check(
    (snapDragView.lastProposedFrameForTesting?.maxX ?? .infinity) <= 1_200,
    "move should clamp the full panel inside the target visible screen: frame=\(String(describing: snapDragView.lastProposedFrameForTesting))"
)
snapDragView.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 1_250, y: 420),
        window: snapMoveWindow
    )
)

let resizeVisible = CGRect(x: 0, y: 0, width: 1_000, height: 700)
let offscreenResizeWindow = NSWindow(
    contentRect: NSRect(x: 900, y: 650, width: 500, height: 500),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
offscreenResizeWindow.isReleasedWhenClosed = false
let offscreenResizeContent = NSView(
    frame: NSRect(x: 0, y: 0, width: 500, height: 500)
)
offscreenResizeWindow.contentView = offscreenResizeContent
let offscreenResizeOverlay = PanelResizeOverlay(
    frame: offscreenResizeContent.bounds
)
offscreenResizeOverlay.visibleFrameOverrideForTesting = resizeVisible
offscreenResizeContent.addSubview(offscreenResizeOverlay)
offscreenResizeOverlay.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 498, y: 250),
        window: offscreenResizeWindow
    )
)
check(
    resizeVisible.contains(offscreenResizeWindow.frame),
    "resize start should clamp an initially offscreen panel into the fixed window screen"
)
check(
    offscreenResizeOverlay.resizeVisibleFrameForTesting == resizeVisible,
    "resize should retain the mousedown screen instead of following pointer screens"
)
offscreenResizeOverlay.mouseDragged(
    with: mouseEvent(
        .leftMouseDragged,
        locationInWindow: NSPoint(x: 548, y: 250),
        window: offscreenResizeWindow
    )
)
check(
    resizeVisible.contains(offscreenResizeWindow.frame),
    "resize delta should remain clamped to the mousedown screen"
)
offscreenResizeOverlay.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 548, y: 250),
        window: offscreenResizeWindow
    )
)

let fastResizeWindow = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 360, height: 480),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
fastResizeWindow.isReleasedWhenClosed = false
let fastResizeContent = NSView(
    frame: NSRect(x: 0, y: 0, width: 360, height: 480)
)
fastResizeWindow.contentView = fastResizeContent
let fastResizeOverlay = PanelResizeOverlay(
    frame: fastResizeContent.bounds
)
fastResizeOverlay.visibleFrameOverrideForTesting = CGRect(
    x: 0,
    y: 0,
    width: 1_200,
    height: 800
)
fastResizeOverlay.externalFramesOverrideForTesting = [
    CGRect(x: 500, y: 100, width: 100, height: 200)
]
fastResizeContent.addSubview(fastResizeOverlay)
fastResizeOverlay.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 358, y: 200),
        window: fastResizeWindow
    )
)
fastResizeOverlay.mouseDragged(
    with: mouseEvent(
        .leftMouseDragged,
        locationInWindow: NSPoint(x: 418, y: 200),
        window: fastResizeWindow
    )
)
check(
    fastResizeOverlay.lastProposedFrameForTesting?.width == 400,
    "first fast resize drag should acquire a crossed edge using seeded raw edge: \(String(describing: fastResizeOverlay.lastProposedFrameForTesting))"
)
fastResizeOverlay.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 418, y: 200),
        window: fastResizeWindow
    )
)

let smallScreenWindow = NSWindow(
    contentRect: NSRect(x: 50, y: 50, width: 360, height: 480),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
smallScreenWindow.isReleasedWhenClosed = false
let smallScreenContent = NSView(
    frame: NSRect(x: 0, y: 0, width: 360, height: 480)
)
smallScreenWindow.contentView = smallScreenContent
let smallScreenDragView = WindowDragRegion.DragView(
    frame: NSRect(x: 20, y: 400, width: 240, height: 44)
)
smallScreenDragView.visibleFramesOverrideForTesting = [
    CGRect(x: 0, y: 0, width: 330, height: 400)
]
smallScreenDragView.externalFramesOverrideForTesting = []
smallScreenContent.addSubview(smallScreenDragView)
smallScreenDragView.mouseDown(
    with: mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 50, y: 420),
        window: smallScreenWindow
    )
)
smallScreenDragView.mouseDragged(
    with: mouseEvent(
        .leftMouseDragged,
        locationInWindow: NSPoint(x: 60, y: 420),
        window: smallScreenWindow
    )
)
check(
    smallScreenWindow.frame.width <= 330
        && smallScreenWindow.frame.height <= 400,
    "move should apply clamped size when the target screen is smaller than the panel"
)
smallScreenDragView.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 60, y: 420),
        window: smallScreenWindow
    )
)

let resizeWindow = NSWindow(
    contentRect: NSRect(x: 300, y: 200, width: 360, height: 480),
    styleMask: [.borderless, .resizable],
    backing: .buffered,
    defer: false
)
resizeWindow.isReleasedWhenClosed = false
let resizeContent = NSView(
    frame: NSRect(x: 0, y: 0, width: 360, height: 480)
)
resizeWindow.contentView = resizeContent
let eventResizeOverlay = PanelResizeOverlay(
    frame: resizeContent.bounds
)
resizeContent.addSubview(eventResizeOverlay)
let resizeDownEvent = mouseEvent(
        .leftMouseDown,
        locationInWindow: NSPoint(x: 358, y: 200),
        window: resizeWindow
)
let resizeDragEvent = mouseEvent(
    .leftMouseDragged,
    locationInWindow: NSPoint(x: 408, y: 200),
    window: resizeWindow
)
let resizeDownPoint = PanelScreenCoordinates.point(
    for: resizeDownEvent,
    in: resizeWindow
)
let resizeDragPoint = PanelScreenCoordinates.point(
    for: resizeDragEvent,
    in: resizeWindow
)
check(
    abs(resizeDragPoint.x - resizeDownPoint.x - 50) < 0.5,
    "constructed resize events should expose a 50pt stamped delta"
)
eventResizeOverlay.mouseDown(with: resizeDownEvent)
check(
    eventResizeOverlay.activeHandleForTesting == .right,
    "resize handler should capture the initial right edge"
)
check(
    eventResizeOverlay.isCursorPushedForTesting,
    "resize drag should push its cursor"
)
eventResizeOverlay.mouseDragged(with: resizeDragEvent)
check(
    eventResizeOverlay.lastProposedFrameForTesting?.width == 410,
    "resize handler should compute a 410pt proposed frame: \(String(describing: eventResizeOverlay.lastProposedFrameForTesting))"
)
check(
    eventResizeOverlay.activeHandleForTesting == .right,
    "resize cursorUpdate state should retain the initial drag edge"
)
check(
    abs(resizeWindow.frame.width - 410) < 0.5,
    "constructed resize events should change the offscreen frame width: \(resizeWindow.frame)"
)
eventResizeOverlay.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 408, y: 200),
        window: resizeWindow
    )
)
check(
    eventResizeOverlay.activeHandleForTesting == nil,
    "mouseUp should clear the active resize handle"
)
check(
    !eventResizeOverlay.isCursorPushedForTesting,
    "mouseUp should balance the cursor push"
)

let routingSuite = "app.agentboard.hit-routing.\(UUID().uuidString)"
let routingDefaults = UserDefaults(suiteName: routingSuite)!
defer { routingDefaults.removePersistentDomain(forName: routingSuite) }
let routingModel = BoardViewModel.demo(defaults: routingDefaults)
let routingController = PanelController(
    model: routingModel,
    defaults: routingDefaults,
    onQuit: {},
    pinChanged: { _ in }
)
if let visible = NSScreen.screens.first?.visibleFrame {
    let requested = NSRect(x: visible.maxX - 448, y: visible.minY, width: 448, height: visible.height)
    routingController.panel.setAccessibilityFrame(requested)
    check(routingController.panel.frame == requested, "AX frame setter should allow full-height utility panels")
    check(routingController.panel.isAccessibilitySelectorAllowed(#selector(NSWindow.setAccessibilityFrame(_:))), "AX frame setter must be writable")
    check(routingController.panel.accessibilityIdentifier() == "app.agentboard.panel", "main panel must expose its stable AX identifier")
    let remembered = routingDefaults.string(forKey: "AgentBoard.panelFrame")
    routingController.panel.setFrame(NSRect(x: requested.minX, y: requested.minY, width: 448, height: 600), display: false)
    routingController.windowDidResize(Notification(name: NSWindow.didResizeNotification))
    check(routingDefaults.string(forKey: "AgentBoard.panelFrame") == remembered, "system resize must not overwrite the preferred full height")
    routingController.clampToVisibleScreen()
    check(routingController.panel.frame == requested, "screen restoration should recover preferred full height")
    routingController.panel.setAccessibilityFrame(NSRect(x: 0, y: 0, width: -10, height: 100))
    check(routingController.panel.frame == requested, "invalid external dimensions must be ignored")
}
routingController.panel.setContentSize(NSSize(width: 360, height: 620))
let routingRoot = routingController.panel.contentView!
routingRoot.layoutSubtreeIfNeeded()
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
routingRoot.layoutSubtreeIfNeeded()

func rootHit(_ point: NSPoint) -> NSView? {
    routingRoot.hitTest(
        routingRoot.superview.map {
            routingRoot.convert(point, to: $0)
        } ?? point
    )
}

check(
    routingRoot is PanelContentView,
    "actual panel root should be an AppKit container"
)
check(
    !routingController.panel.styleMask.contains(.resizable),
    "panel should use the custom resize overlay instead of OS native border resizing"
)
check(
    rootHit(NSPoint(x: 2, y: 100)) is PanelResizeOverlay,
    "actual PanelController left border should route to resize overlay"
)
check(
    rootHit(NSPoint(x: 358, y: 100)) is PanelResizeOverlay,
    "actual PanelController right border should route to resize overlay"
)
check(
    rootHit(NSPoint(x: 180, y: 2)) is PanelResizeOverlay,
    "actual PanelController bottom border should route to resize overlay"
)
check(
    rootHit(NSPoint(x: 180, y: 618)) is PanelResizeOverlay,
    "actual PanelController top border should route to resize overlay"
)
let centerHit = rootHit(NSPoint(x: 180, y: 300))
check(
    centerHit != nil && !(centerHit is PanelResizeOverlay),
    "actual PanelController center should pass through to SwiftUI"
)
if !NSScreen.screens.isEmpty {
    routingController.panel.setFrame(
        NSRect(x: 20_000, y: 20_000, width: 360, height: 480),
        display: false
    )
    routingController.windowDidMove(
        Notification(name: NSWindow.didMoveNotification)
    )
    check(
        NSScreen.screens.contains {
            $0.visibleFrame.contains(routingController.panel.frame)
        },
        "window move callback should clamp the complete panel into a visible screen"
    )
    let hugeSize = routingController.windowWillResize(
        routingController.panel,
        to: NSSize(width: 10_000, height: 10_000)
    )
    check(
        hugeSize.width <= (NSScreen.screens.map(\.visibleFrame.width).max() ?? 0)
            && hugeSize.height
                <= (NSScreen.screens.map(\.visibleFrame.height).max() ?? 0),
        "native resize callback safeguard should cap frame size to a visible screen"
    )
}
routingController.panel.setContentSize(NSSize(width: 360, height: 620))
routingController.panel.setFrame(
    NSRect(x: 300, y: 200, width: 360, height: 620),
    display: false
)
routingRoot.layoutSubtreeIfNeeded()

guard let actualResizeOverlay = routingController.resizeOverlay else {
    fatalError("actual resize overlay missing")
}
check(
    !routingController.panel.canBecomeKey
        && !routingController.panel.isKeyWindow,
    "hover cursor verification should run on the actual non-key nonactivating panel"
)
guard let trackingOptions = actualResizeOverlay.trackingOptionsForTesting else {
    fatalError("split hover/cursorUpdate tracking areas missing")
}
check(
    trackingOptions.hover.contains(.activeAlways)
        && trackingOptions.hover.contains(.mouseMoved)
        && trackingOptions.hover.contains(.mouseEnteredAndExited)
        && !trackingOptions.hover.contains(.cursorUpdate),
    "always-active tracking should deliver hover movement without unsupported cursorUpdate"
)
check(
    trackingOptions.cursorUpdate.contains(.activeInActiveApp)
        && trackingOptions.cursorUpdate.contains(.cursorUpdate)
        && !trackingOptions.cursorUpdate.contains(.activeAlways),
    "cursorUpdate should use its own activeInActiveApp tracking area"
)
let hoverRightEvent = mouseEvent(
    .mouseMoved,
    locationInWindow: NSPoint(x: 358, y: 240),
    window: routingController.panel
)
routingController.panel.sendEvent(hoverRightEvent)
check(
    NSCursor.current == NSCursor.resizeLeftRight,
    "inactive nonactivating panel right-edge hover should own the horizontal resize cursor"
)
check(
    actualResizeOverlay.ownsHoverResizeCursorForTesting,
    "panel sendEvent should retain resize cursor ownership on an edge"
)
check(
    actualResizeOverlay.backgroundCursorRequestedForTesting,
    "edge hover should enable optional background cursor ownership"
)

let hoverTopEvent = mouseEvent(
    .mouseMoved,
    locationInWindow: NSPoint(x: 180, y: 618),
    window: routingController.panel
)
routingController.panel.sendEvent(hoverTopEvent)
check(
    NSCursor.current == NSCursor.resizeUpDown,
    "inactive nonactivating panel top-edge hover should own the vertical resize cursor"
)

let hoverCornerEvent = mouseEvent(
    .mouseMoved,
    locationInWindow: NSPoint(x: 358, y: 618),
    window: routingController.panel
)
routingController.panel.sendEvent(hoverCornerEvent)
check(
    NSCursor.current != NSCursor.arrow
        && NSCursor.current != NSCursor.resizeLeftRight
        && NSCursor.current != NSCursor.resizeUpDown,
    "inactive nonactivating panel corner hover should own a diagonal resize cursor"
)

let hoverCenterEvent = mouseEvent(
    .mouseMoved,
    locationInWindow: NSPoint(x: 180, y: 240),
    window: routingController.panel
)
routingController.panel.sendEvent(hoverCenterEvent)
check(
    !actualResizeOverlay.ownsHoverResizeCursorForTesting,
    "moving from a resize edge into content should release cursor ownership"
)
check(
    !actualResizeOverlay.backgroundCursorRequestedForTesting,
    "content hover should disable background cursor ownership"
)
check(
    NSCursor.current != NSCursor.resizeLeftRight
        && NSCursor.current != NSCursor.resizeUpDown,
    "content hover must not retain a resize cursor"
)
let hoverOutsideEvent = mouseEvent(
    .mouseMoved,
    locationInWindow: NSPoint(x: 420, y: 240),
    window: routingController.panel
)
routingController.panel.sendEvent(hoverOutsideEvent)
check(
    NSCursor.current == NSCursor.arrow,
    "leaving the panel should restore the arrow cursor immediately: current=\(NSCursor.current), owns=\(actualResizeOverlay.ownsHoverResizeCursorForTesting)"
)
check(
    !actualResizeOverlay.ownsHoverResizeCursorForTesting,
    "leaving the panel should clear resize cursor ownership: current=\(NSCursor.current), owns=\(actualResizeOverlay.ownsHoverResizeCursorForTesting), frame=\(actualResizeOverlay.frame), bounds=\(actualResizeOverlay.bounds), edge=\(actualResizeOverlay.isResizeEdge(atWindowPoint: NSPoint(x: 420, y: 240)))"
)
check(
    !actualResizeOverlay.backgroundCursorRequestedForTesting,
    "leaving the panel should disable background cursor ownership"
)

routingController.panel.setFrame(
    NSRect(x: 300, y: 200, width: 360, height: 480),
    display: false
)
let actualDown = mouseEvent(
    .leftMouseDown,
    locationInWindow: NSPoint(x: 358, y: 200),
    window: routingController.panel
)
let actualDrag = mouseEvent(
    .leftMouseDragged,
    locationInWindow: NSPoint(x: 408, y: 200),
    window: routingController.panel
)
actualResizeOverlay.mouseDown(with: actualDown)
check(
    actualResizeOverlay.backgroundCursorRequestedForTesting,
    "resize drag should enable background cursor ownership"
)
actualResizeOverlay.mouseDragged(with: actualDrag)
check(
    abs(routingController.panel.frame.width - 410) < 0.5,
    "actual PanelController border event should change its frame width"
)
actualResizeOverlay.mouseUp(
    with: mouseEvent(
        .leftMouseUp,
        locationInWindow: NSPoint(x: 408, y: 200),
        window: routingController.panel
    )
)
check(
    !actualResizeOverlay.isCursorPushedForTesting,
    "actual PanelController resize should balance cursor state"
)
routingController.panel.sendEvent(
    mouseEvent(
        .mouseMoved,
        locationInWindow: NSPoint(x: 180, y: 240),
        window: routingController.panel
    )
)
check(
    !actualResizeOverlay.backgroundCursorRequestedForTesting,
    "content movement after resize should disable background cursor ownership"
)

let renameCard = routingModel.displayedCards.first!
let renameCoordinator = RenameTitleCoordinator(
    model: routingModel,
    card: renameCard,
    parent: routingController.panel
)
check(
    renameCoordinator.dialog.canBecomeKey,
    "rename dialog should be key-capable despite nonactivating parent panel"
)
check(
    renameCoordinator.titleField.isEditable
        && renameCoordinator.titleField.acceptsFirstResponder,
    "rename field should be an editable AppKit first responder"
)
check(
    renameCoordinator.dialog.initialFirstResponder === renameCoordinator.titleField,
    "rename dialog should configure editable title field as initial first responder"
)
check(
    renameCoordinator.sourceTitleForTesting == renameCard.title,
    "rename dialog should carry source-derived title separately from override"
)

let markedTextView = NSTextView(
    frame: NSRect(x: 0, y: 0, width: 200, height: 30)
)
markedTextView.setMarkedText(
    "한",
    selectedRange: NSRange(location: 1, length: 0),
    replacementRange: NSRange(location: 0, length: 0)
)
check(markedTextView.hasMarkedText(),
      "test text view should contain Korean marked text")
check(
    !renameCoordinator.control(
        renameCoordinator.titleField,
        textView: markedTextView,
        doCommandBy: #selector(NSResponder.insertNewline(_:))
    ) && !renameCoordinator.isFinishedForTesting,
    "Enter during marked Korean text should remain with the input method"
)
check(
    !renameCoordinator.control(
        renameCoordinator.titleField,
        textView: markedTextView,
        doCommandBy: #selector(NSResponder.cancelOperation(_:))
    ) && !renameCoordinator.isFinishedForTesting,
    "Escape during marked Korean text should remain with the input method"
)

let normalized80 = String(repeating: "가", count: 80)
renameCoordinator.titleField.stringValue = "   \(normalized80)   "
renameCoordinator.controlTextDidChange(
    Notification(
        name: NSControl.textDidChangeNotification,
        object: renameCoordinator.titleField
    )
)
check(renameCoordinator.saveButton.isEnabled,
      "normalized 80-character title should be saveable despite raw spaces")
check(renameCoordinator.errorLabel.stringValue == "80/80",
      "validation count should use normalized title")
renameCoordinator.saveButton.performClick(nil)
check(renameCoordinator.isFinishedForTesting,
      "save button action should finish rename dialog")
check(
    routingModel.cards.first(where: { $0.id == renameCard.id })?.displayTitle
        == normalized80,
    "save button action should persist normalized custom title"
)

let cancelCard = routingModel.cards.first(where: { $0.id == renameCard.id })!
let cancelCoordinator = RenameTitleCoordinator(
    model: routingModel,
    card: cancelCard,
    parent: routingController.panel
)
cancelCoordinator.titleField.stringValue = "취소될 제목"
cancelCoordinator.cancelButton.performClick(nil)
check(cancelCoordinator.isFinishedForTesting,
      "cancel button action should finish rename dialog")
check(
    routingModel.cards.first(where: { $0.id == renameCard.id })?.displayTitle
        == normalized80,
    "cancel action should not save edited title"
)

let resetCoordinator = RenameTitleCoordinator(
    model: routingModel,
    card: routingModel.cards.first(where: { $0.id == renameCard.id })!,
    parent: routingController.panel
)
check(!resetCoordinator.resetButton.isHidden,
      "reset button should be visible for custom override")
resetCoordinator.resetButton.performClick(nil)
check(resetCoordinator.isFinishedForTesting,
      "automatic title reset action should finish rename dialog")
check(
    routingModel.cards.first(where: { $0.id == renameCard.id })?.displayTitle
        == renameCard.title,
    "automatic title reset should restore latest source title"
)

let navigationWindowID = UUID(
    uuidString: "10000000-0000-4000-8000-000000000001"
)!
let navigationWorkspaceID = UUID(
    uuidString: "20000000-0000-4000-8000-000000000002"
)!
let navigationSurfaceID = UUID(
    uuidString: "30000000-0000-4000-8000-000000000003"
)!
let navigationPaneID = UUID(
    uuidString: "40000000-0000-4000-8000-000000000004"
)!
let navigationOrigin = SessionOrigin(
    kind: .cmux,
    windowId: navigationWindowID.uuidString,
    workspaceId: navigationWorkspaceID.uuidString,
    surfaceId: navigationSurfaceID.uuidString,
    socketPath: "/tmp/cmux.sock"
)
let navigationCard = AgentCard(
    id: UUID(uuidString: "12345678-1234-4234-8234-123456789ABC")!,
    provider: .openai,
    title: "Navigation card",
    cwd: "/tmp/nav",
    state: .running,
    responseLifecycle: .running,
    origin: navigationOrigin
)
let navigationTreeJSON = """
{"windows":[{"kind":"window","id":"\(navigationWindowID.uuidString)","workspaces":[{"kind":"workspace","id":"\(navigationWorkspaceID.uuidString)","panes":[{"kind":"pane","id":"\(navigationPaneID.uuidString)","surfaces":[{"kind":"surface","id":"\(navigationSurfaceID.uuidString)","type":"terminal","pane_id":"\(navigationPaneID.uuidString)","tty":"ttys001"}]}]}]}]}
"""
let navigationResumeJSON = """
{"window_id":"\(navigationWindowID.uuidString)","workspace_id":"\(navigationWorkspaceID.uuidString)","surface_id":"\(navigationSurfaceID.uuidString)","resume_binding":{"kind":"codex","checkpoint_id":"\(navigationCard.id.uuidString)","command":"codex resume \(navigationCard.id.uuidString)"}}
"""
let navigationProcessJSON = """
{"windows":[{"kind":"window","id":"\(navigationWindowID.uuidString)","workspaces":[{"kind":"workspace","id":"\(navigationWorkspaceID.uuidString)","panes":[{"kind":"pane","id":"\(navigationPaneID.uuidString)","surfaces":[{"kind":"surface","id":"\(navigationSurfaceID.uuidString)","type":"terminal","pane_id":"\(navigationPaneID.uuidString)","processes":[{"pid":4242,"name":"codex","cpu_percent":0.1,"memory_bytes":1024,"process_count":0}]}]}]}]}]}
"""
var navigationCalls: [(URL, [String], [String: String]?)] = []
let focusedNavigator = ConversationNavigator(
    runCommand: { executable, arguments, environment, _ in
        navigationCalls.append((executable, arguments, environment))
        let output: String
        if arguments.contains("tree") {
            output = navigationTreeJSON
        } else if arguments.contains("resume") {
            output = navigationResumeJSON
        } else if arguments.contains("top") {
            output = navigationProcessJSON
        } else {
            output = ""
        }
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
check(
    focusedNavigator.attemptFocus(navigationCard) == .focused,
    "exact cmux hierarchy, checkpoint, and live process should focus"
)
check(
    navigationCalls.map { $0.1 } == [
        ["--json", "--id-format", "both", "tree", "--all"],
        [
            "--json", "--id-format", "both", "surface", "resume", "show",
            "--workspace", navigationWorkspaceID.uuidString,
            "--surface", navigationSurfaceID.uuidString,
            "--window", navigationWindowID.uuidString
        ],
        ["--json", "--id-format", "both", "top", "--all", "--processes"],
        [
            "--id-format", "both", "select-workspace",
            "--workspace", navigationWorkspaceID.uuidString,
            "--window", navigationWindowID.uuidString
        ],
        [
            "--id-format", "both", "focus-panel",
            "--panel", navigationSurfaceID.uuidString,
            "--workspace", navigationWorkspaceID.uuidString,
            "--window", navigationWindowID.uuidString
        ],
        [
            "--id-format", "both", "focus-window",
            "--window", navigationWindowID.uuidString
        ]
    ],
    "cmux focus should verify hierarchy/binding/process then focus explicit UUIDs"
)
check(
    navigationCalls.allSatisfy {
        $0.1.contains("--id-format")
            || $0.1.first == "focus-window"
    },
    "cmux resolution commands should request both refs and UUIDs"
)
check(
    navigationCalls.allSatisfy {
        $0.2?["CMUX_SOCKET_PATH"] == "/tmp/cmux.sock"
    },
    "cmux focus should use the registered socket path"
)

var staleCalls = 0
let staleNavigator = ConversationNavigator(
    runCommand: { _, _, _, _ in
        staleCalls += 1
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: #"{"windows":[]}"#,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal(let reason) = staleNavigator.attemptFocus(navigationCard) {
    check(reason.contains("정확한 window/workspace/surface"),
          "stale cmux hierarchy should honestly report failure")
} else {
    check(false, "missing tree hierarchy must not focus a guessed panel")
}
check(staleCalls == 1,
      "failed tree verification should not run focus commands")

var samePanelOtherThreadCalls = 0
let samePanelOtherThreadNavigator = ConversationNavigator(
    runCommand: { _, arguments, _, _ in
        samePanelOtherThreadCalls += 1
        if arguments.contains("tree") {
            return NavigationProcessResult(
                exitCode: 0,
                standardOutput: navigationTreeJSON,
                standardError: "",
                timedOut: false,
                launchError: nil
            )
        }
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: """
            {"window_id":"\(navigationWindowID.uuidString)","workspace_id":"\(navigationWorkspaceID.uuidString)","surface_id":"\(navigationSurfaceID.uuidString)","resume_binding":{"kind":"codex","checkpoint_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","command":"codex resume AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"}}
            """,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal(let reason) =
    samePanelOtherThreadNavigator.attemptFocus(navigationCard) {
    check(reason.contains("resume checkpoint"),
          "same cmux surface with another thread must require fallback")
} else {
    check(false, "surface UUID alone must never focus a different thread")
}
check(samePanelOtherThreadCalls == 2,
      "different-thread verification must not run focus commands")

var providerMismatchCalls = 0
let providerMismatchNavigator = ConversationNavigator(
    runCommand: { _, arguments, _, _ in
        providerMismatchCalls += 1
        let output = arguments.contains("tree")
            ? navigationTreeJSON
            : """
              {"window_id":"\(navigationWindowID.uuidString)","workspace_id":"\(navigationWorkspaceID.uuidString)","surface_id":"\(navigationSurfaceID.uuidString)","resume_binding":{"kind":"deepseek","checkpoint_id":"\(navigationCard.id.uuidString)","command":"codex --profile ds resume \(navigationCard.id.uuidString)"}}
              """
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = providerMismatchNavigator.attemptFocus(navigationCard) {
    check(providerMismatchCalls == 2,
          "provider mismatch must stop before cmux focus commands")
} else {
    check(false, "provider mismatch must not focus the registered panel")
}

var staleProcessCalls = 0
let staleProcessNavigator = ConversationNavigator(
    runCommand: { _, arguments, _, _ in
        staleProcessCalls += 1
        let output: String
        if arguments.contains("tree") {
            output = navigationTreeJSON
        } else if arguments.contains("resume") {
            output = navigationResumeJSON
        } else {
            output = """
            {"windows":[{"kind":"window","id":"\(navigationWindowID.uuidString)","workspaces":[{"kind":"workspace","id":"\(navigationWorkspaceID.uuidString)","panes":[{"kind":"pane","id":"\(navigationPaneID.uuidString)","surfaces":[{"kind":"surface","id":"\(navigationSurfaceID.uuidString)","pane_id":"\(navigationPaneID.uuidString)","processes":[]}]}]}]}]}
            """
        }
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = staleProcessNavigator.attemptFocus(navigationCard) {
    check(staleProcessCalls == 3,
          "stale checkpoint without a live target process must stop before focus")
} else {
    check(false, "stored checkpoint alone must not authorize focus")
}

var codexArgumentCalls = 0
let codexArgumentNavigator = ConversationNavigator(
    runCommand: { _, arguments, _, _ in
        codexArgumentCalls += 1
        let output: String
        if arguments.contains("tree") {
            output = navigationTreeJSON
        } else if arguments.contains("resume") {
            output = navigationResumeJSON
        } else {
            output = """
            {"windows":[{"kind":"window","id":"\(navigationWindowID.uuidString)","workspaces":[{"kind":"workspace","id":"\(navigationWorkspaceID.uuidString)","panes":[{"kind":"pane","id":"\(navigationPaneID.uuidString)","surfaces":[{"kind":"surface","id":"\(navigationSurfaceID.uuidString)","pane_id":"\(navigationPaneID.uuidString)","processes":[{"pid":4242,"name":"rg","cpu_percent":0.1,"memory_bytes":1024,"process_count":0}]}]}]}]}]}
            """
        }
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = codexArgumentNavigator.attemptFocus(navigationCard) {
    check(codexArgumentCalls == 3,
          "a process argument mentioning codex must not authorize focus")
} else {
    check(false, "only a live codex executable should satisfy process verification")
}

var wrongResumeTargetCalls = 0
let wrongResumeTargetNavigator = ConversationNavigator(
    runCommand: { _, arguments, _, _ in
        wrongResumeTargetCalls += 1
        let output: String
        if arguments.contains("tree") {
            output = navigationTreeJSON
        } else {
            output = """
            {"window_id":"\(navigationWindowID.uuidString)","workspace_id":"\(navigationWorkspaceID.uuidString)","surface_id":"AAAAAAAA-0000-4000-8000-000000000000","resume_binding":{"kind":"codex","checkpoint_id":"\(navigationCard.id.uuidString)","command":"codex resume \(navigationCard.id.uuidString)"}}
            """
        }
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = wrongResumeTargetNavigator.attemptFocus(navigationCard) {
    check(wrongResumeTargetCalls == 2,
          "resume metadata for another surface must not authorize focus")
} else {
    check(false, "resume response target identifiers must match the tree target")
}

var metadataMissingCalls = 0
let metadataMissingNavigator = ConversationNavigator(
    runCommand: { _, arguments, _, _ in
        metadataMissingCalls += 1
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: arguments.contains("tree")
                ? navigationTreeJSON
                : """
                  {"window_id":"\(navigationWindowID.uuidString)","workspace_id":"\(navigationWorkspaceID.uuidString)","surface_id":"\(navigationSurfaceID.uuidString)","resume_binding":null}
                  """,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = metadataMissingNavigator.attemptFocus(navigationCard) {
    check(metadataMissingCalls == 2,
          "surface without checkpoint metadata must require fallback")
} else {
    check(false, "surface without live session metadata must not focus")
}

var otherSurfaceSessionCalls = 0
let otherSurfaceSessionNavigator = ConversationNavigator(
    runCommand: { _, _, _, _ in
        otherSurfaceSessionCalls += 1
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: """
            {"windows":[{"kind":"window","id":"\(navigationWindowID.uuidString)","workspaces":[{"kind":"workspace","id":"AAAAAAAA-0000-4000-8000-000000000000","panes":[{"kind":"pane","id":"\(navigationPaneID.uuidString)","surfaces":[{"kind":"surface","id":"\(navigationSurfaceID.uuidString)","pane_id":"\(navigationPaneID.uuidString)","type":"terminal"}]}]}]}]}
            """,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal =
    otherSurfaceSessionNavigator.attemptFocus(navigationCard) {
    check(otherSurfaceSessionCalls == 1,
          "a surface under another workspace must not authorize focus")
} else {
    check(false, "tree hierarchy must match window, workspace, and surface")
}

var noOriginCalls = 0
let noOriginNavigator = ConversationNavigator(
    runCommand: { _, _, _, _ in
        noOriginCalls += 1
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: "",
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
let noOriginCard = AgentCard(
    id: UUID(),
    provider: .deepseek,
    title: "No origin",
    cwd: "/tmp/no-origin",
    origin: nil
)
if case .needsTerminal(let reason) = noOriginNavigator.attemptFocus(noOriginCard) {
    check(reason.contains("닫혔다는 의미는 아닙니다"),
          "missing location should not imply the conversation is closed")
} else {
    check(false, "missing origin should require terminal fallback")
}
check(noOriginCalls == 0, "missing origin must not invoke any CLI")

let herdrSessionID = UUID(
    uuidString: "11111111-2222-4333-8444-555555555555"
)!
let herdrCard = AgentCard(
    id: herdrSessionID,
    provider: .openai,
    title: "Herdr card",
    cwd: "/tmp/herdr",
    origin: SessionOrigin(
        kind: .herdr,
        workspaceId: "w1",
        tabId: "w1:t1",
        paneId: "w1:p1",
        sessionName: "agentboard-test",
        socketPath: "/tmp/herdr.sock"
    )
)
let herdrSessionJSON = """
{"source":"herdr:codex","agent":"codex","kind":"id","value":"\(herdrSessionID.uuidString)"}
"""
var herdrCalls: [(URL, [String], [String: String]?)] = []
let exactHerdrNavigator = ConversationNavigator(
    runCommand: { executable, arguments, environment, _ in
        herdrCalls.append((executable, arguments, environment))
        let output: String
        if arguments == ["pane", "get", "w1:p1"] {
            output = """
            {"result":{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_id":"terminal-1","focused":false,"agent_status":"idle","revision":1,"agent_session":\(herdrSessionJSON)}}}
            """
        } else if arguments == ["agent", "get", "w1:p1"] {
            output = """
            {"result":{"type":"agent_info","agent":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"codex","agent_session":\(herdrSessionJSON)}}}
            """
        } else {
            output = #"{"result":"ok"}"#
        }
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
check(exactHerdrNavigator.attemptFocus(herdrCard) == .focused,
      "exact Herdr pane and agent session should focus")
check(
    herdrCalls.map { $0.1 } == [
        ["pane", "get", "w1:p1"],
        ["agent", "get", "w1:p1"],
        ["agent", "focus", "w1:p1"]
    ],
    "Herdr focus should use pane/agent gets then positional agent focus"
)
check(
    herdrCalls.allSatisfy {
        $0.2?["HERDR_SESSION"] == "agentboard-test"
            && $0.2?["HERDR_SOCKET_PATH"] == "/tmp/herdr.sock"
    },
    "Herdr commands should use captured session and socket"
)
herdrCalls = []
let deepSeekHerdrCard = AgentCard(
    id: herdrCard.id,
    provider: .deepseek,
    title: "Herdr DeepSeek card",
    cwd: "/tmp/herdr",
    origin: herdrCard.origin
)
check(
    exactHerdrNavigator.attemptFocus(deepSeekHerdrCard) == .focused,
    "Herdr codex agent kind should support an exact DeepSeek provider thread"
)
check(
    !herdrCalls.contains(where: {
        $0.1.contains("focus") && $0.1.contains(where: {
            ["left", "right", "up", "down"].contains($0)
        })
    }),
    "Herdr must not turn pane focus directions into positional commands"
)

let otherHerdrJSON = """
{"source":"herdr:codex","agent":"codex","kind":"id","value":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"}
"""
var mismatchedHerdrCalls = 0
let mismatchedHerdrNavigator = ConversationNavigator(
    runCommand: { _, _, _, _ in
        mismatchedHerdrCalls += 1
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: """
            {"result":{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_id":"terminal-1","focused":false,"agent_status":"idle","revision":1,"agent_session":\(otherHerdrJSON)}}}
            """,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = mismatchedHerdrNavigator.attemptFocus(herdrCard) {
    check(mismatchedHerdrCalls == 1,
          "Herdr pane with another thread must stop before agent focus")
} else {
    check(false, "Herdr pane existence alone must not authorize focus")
}

let pathHerdrSessionJSON = """
{"source":"herdr:codex","agent":"codex","kind":"path","value":"\(herdrSessionID.uuidString)"}
"""
var pathBindingCalls = 0
let pathBindingNavigator = ConversationNavigator(
    runCommand: { _, _, _, _ in
        pathBindingCalls += 1
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: """
            {"result":{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_id":"terminal-1","focused":false,"agent_status":"idle","revision":1,"agent_session":\(pathHerdrSessionJSON)}}}
            """,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = pathBindingNavigator.attemptFocus(herdrCard) {
    check(pathBindingCalls == 1,
          "Herdr path session references must not authorize live focus")
} else {
    check(false, "Herdr agent_session kind must be exactly id")
}

let missingSourceJSON = """
{"agent":"codex","kind":"id","value":"\(herdrSessionID.uuidString)"}
"""
var missingSourceCalls = 0
let missingSourceNavigator = ConversationNavigator(
    runCommand: { _, _, _, _ in
        missingSourceCalls += 1
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: """
            {"result":{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_id":"terminal-1","focused":false,"agent_status":"idle","revision":1,"agent_session":\(missingSourceJSON)}}}
            """,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = missingSourceNavigator.attemptFocus(herdrCard) {
    check(missingSourceCalls == 1,
          "Herdr agent_session without source must not authorize focus")
} else {
    check(false, "Herdr agent_session source is required")
}

let conflictingModelJSON = """
{"source":"herdr:codex","agent":"codex","kind":"id","value":"\(herdrSessionID.uuidString)","model_provider":"deepseek"}
"""
var conflictingModelCalls = 0
let conflictingModelNavigator = ConversationNavigator(
    runCommand: { _, _, _, _ in
        conflictingModelCalls += 1
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: """
            {"result":{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_id":"terminal-1","focused":false,"agent_status":"idle","revision":1,"agent_session":\(conflictingModelJSON)}}}
            """,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = conflictingModelNavigator.attemptFocus(herdrCard) {
    check(conflictingModelCalls == 1,
          "explicit model_provider conflict must not authorize focus")
} else {
    check(false, "explicit Herdr model provider must match the card")
}

var mismatchedAgentTabCalls = 0
let mismatchedAgentTabNavigator = ConversationNavigator(
    runCommand: { _, arguments, _, _ in
        mismatchedAgentTabCalls += 1
        if arguments == ["pane", "get", "w1:p1"] {
            return NavigationProcessResult(
                exitCode: 0,
                standardOutput: """
                {"result":{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_id":"terminal-1","focused":false,"agent_status":"idle","revision":1,"agent_session":\(herdrSessionJSON)}}}
                """,
                standardError: "",
                timedOut: false,
                launchError: nil
            )
        }
        return NavigationProcessResult(
            exitCode: 0,
            standardOutput: """
            {"result":{"type":"agent_info","agent":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t2","agent":"codex","agent_session":\(herdrSessionJSON)}}}
            """,
            standardError: "",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = mismatchedAgentTabNavigator.attemptFocus(herdrCard) {
    check(mismatchedAgentTabCalls == 2,
          "Herdr AgentInfo tab mismatch must stop before focus")
} else {
    check(false, "Herdr PaneInfo and AgentInfo identities must both match")
}

var inactiveAgentCalls = 0
let inactiveAgentNavigator = ConversationNavigator(
    runCommand: { _, arguments, _, _ in
        inactiveAgentCalls += 1
        if arguments == ["pane", "get", "w1:p1"] {
            return NavigationProcessResult(
                exitCode: 0,
                standardOutput: """
                {"result":{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_id":"terminal-1","focused":false,"agent_status":"idle","revision":1,"agent_session":\(herdrSessionJSON)}}}
                """,
                standardError: "",
                timedOut: false,
                launchError: nil
            )
        }
        return NavigationProcessResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "agent_not_running",
            timedOut: false,
            launchError: nil
        )
    },
    openResumeFile: { _, completion in
        completion(.success(()))
    }
)
if case .needsTerminal = inactiveAgentNavigator.attemptFocus(herdrCard) {
    check(inactiveAgentCalls == 2,
          "Herdr registered session without a live agent must require fallback")
} else {
    check(false, "Herdr registered pane metadata alone must not authorize focus")
}

let resumeDirectory = "/tmp/project with ' quote; touch /tmp/injected"
try FileManager.default.createDirectory(
    atPath: resumeDirectory,
    withIntermediateDirectories: true
)
let resumeCard = AgentCard(
    id: UUID(uuidString: "87654321-4321-4321-8321-CBA987654321")!,
    provider: .deepseek,
    title: "Resume card",
    cwd: resumeDirectory,
    origin: nil
)
let resumeFixtureDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentBoardResumeFixture-\(UUID().uuidString)")
try FileManager.default.createDirectory(
    at: resumeFixtureDirectory,
    withIntermediateDirectories: true
)
let fakeCodex = resumeFixtureDirectory.appendingPathComponent("codex")
try Data(
    "#!/bin/sh\nprintf '%s\\n' \"$CODEX_HOME\" \"$PWD\" \"$@\"\n".utf8
).write(to: fakeCodex)
try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o700)],
    ofItemAtPath: fakeCodex.path
)
check(
    AgentBoardExecutableLocator.find(
        "codex",
        environment: ["PATH": ""],
        additionalCandidates: [fakeCodex.path]
    ) == fakeCodex,
    "GUI PATH fallback should use a verified executable candidate"
)
let customCodexHome = resumeFixtureDirectory.appendingPathComponent(
    "codex home ' $(touch INJECTION)"
)
let resumeService = TerminalResumeService(
    codexHome: customCodexHome,
    resolveCodex: { fakeCodex }
)
let resumePlan = try resumeService.createPlan(for: resumeCard)
let resumePermissions = try FileManager.default.attributesOfItem(
    atPath: resumePlan.fileURL.path
)[.posixPermissions] as! NSNumber
check(resumePermissions.intValue == 0o700,
      "Terminal resume file should be mode 0700")
check(resumePlan.content.contains("cd -- '/tmp/project with '\\'' quote; touch /tmp/injected'"),
      "Terminal resume cwd should be safely shell-quoted")
check(resumePlan.content.contains("|| exit 1"),
      "Terminal resume must stop when the working directory is unavailable")
check(
    resumePlan.content.contains(
        "export CODEX_HOME='\(customCodexHome.path.replacingOccurrences(of: "'", with: "'\\''"))'"
    ),
    "Terminal resume must export the app codexHome with shell quoting"
)
check(
    resumePlan.content.contains(
        "exec '\(fakeCodex.path)' --profile ds resume '\(resumeCard.id.uuidString)'"
    ),
    "DeepSeek resume should use a resolved codex path, ds profile, and UUID"
)
let openaiPlan = try resumeService.createPlan(for: navigationCard)
check(
    openaiPlan.content.contains(
        "exec '\(fakeCodex.path)' resume '\(navigationCard.id.uuidString)'"
    ),
    "GPT resume should use a resolved codex path and explicit UUID"
)
let resumeExecution = CLIProcessRunner().run(
    executable: URL(fileURLWithPath: "/bin/zsh"),
    arguments: [resumePlan.fileURL.path],
    timeout: 1.0
)
check(
    resumeExecution.standardOutput.split(separator: "\n").map(String.init)
        == [
            customCodexHome.path,
            resumeDirectory,
            "--profile",
            "ds",
            "resume",
            resumeCard.id.uuidString
        ],
    "resume script should execute with the injected CODEX_HOME and literal cwd: \(resumeExecution.standardOutput) stderr=\(resumeExecution.standardError)"
)
var openedResumeURL: URL?
let mockOpenNavigator = ConversationNavigator(
    runCommand: { _, _, _, _ in
        NavigationProcessResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "",
            timedOut: false,
            launchError: "unused"
        )
    },
    openResumeFile: { url, completion in
        openedResumeURL = url
        completion(.success(()))
    },
    createResumePlan: { _ in resumePlan },
    presentResumeError: { _ in }
)
mockOpenNavigator.openTerminalResume(card: resumeCard, parent: nil)
check(openedResumeURL != nil,
      "explicit Terminal resume action should pass the command file to opener")

enum ExpectedResumeFailure: Error { case launchFailed }
var resumeFailureMessage: String?
let failedResumeNavigator = ConversationNavigator(
    runCommand: { _, _, _, _ in
        NavigationProcessResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "",
            timedOut: false,
            launchError: "unused"
        )
    },
    openResumeFile: { _, completion in
        completion(.failure(ExpectedResumeFailure.launchFailed))
    },
    createResumePlan: { _ in resumePlan },
    presentResumeError: { resumeFailureMessage = $0 }
)
failedResumeNavigator.openTerminalResume(card: resumeCard, parent: nil)
check(resumeFailureMessage?.contains("Terminal을 열지 못했습니다") == true,
      "asynchronous NSWorkspace failure must not be treated as success")

let timeoutStarted = CFAbsoluteTimeGetCurrent()
let timeoutResult = CLIProcessRunner().run(
    executable: URL(fileURLWithPath: "/bin/sh"),
    arguments: [
        "-c",
        "trap '' TERM; while :; do sleep 1; done"
    ],
    timeout: 0.1
)
check(timeoutResult.timedOut,
      "CLIProcessRunner should kill a TERM-ignoring timed-out command")
check(CFAbsoluteTimeGetCurrent() - timeoutStarted < 1.5,
      "timed-out command should be bounded despite ignored SIGTERM")

let inheritedPipeStarted = CFAbsoluteTimeGetCurrent()
let inheritedPipeResult = CLIProcessRunner().run(
    executable: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "sleep 2 & echo started; exit 0"],
    timeout: 1.0
)
check(inheritedPipeResult.isSuccess,
      "direct child exit should succeed even if a grandchild inherits stdout")
check(inheritedPipeResult.standardOutput.contains("started"),
      "bounded pipe capture should retain completed child output")
check(CFAbsoluteTimeGetCurrent() - inheritedPipeStarted < 1.0,
      "inherited pipe handles must not block completion")

let outputLimitResult = CLIProcessRunner().run(
    executable: URL(fileURLWithPath: "/bin/sh"),
    arguments: [
        "-c",
        "head -c 1000000 /dev/zero | tr '\\000' x"
    ],
    timeout: 2.0
)
check(outputLimitResult.isSuccess,
      "large-output fixture should still complete")
check(
    outputLimitResult.standardOutput.utf8.count
        <= CLIProcessRunner.maximumCapturedBytes,
    "process output must be capped while still being drained"
)

print(checks)
if failures.isEmpty {
    print("PASS AppHitTests \(checks) checks")
    exit(0)
} else {
    for failure in failures {
        print("FAIL \(failure)")
    }
    exit(1)
}
