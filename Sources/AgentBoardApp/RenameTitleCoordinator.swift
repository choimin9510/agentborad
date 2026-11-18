import AgentBoardCore
import AppKit

final class RenameTitlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class RenameTitleCoordinator: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    let dialog: RenameTitlePanel
    let titleField: NSTextField
    var onFinish: (() -> Void)?

    private let model: BoardViewModel
    private let cardId: UUID
    private let sourceTitle: String
    private let hasOverride: Bool
    let errorLabel = NSTextField(labelWithString: "")
    let saveButton = NSButton(title: "저장", target: nil, action: nil)
    let resetButton = NSButton(
        title: "자동 제목으로",
        target: nil,
        action: nil
    )
    let cancelButton = NSButton(title: "취소", target: nil, action: nil)
    private var previousApplication: NSRunningApplication?
    private var didFinish = false

    var isFinishedForTesting: Bool { didFinish }

    init(model: BoardViewModel, card: AgentCard, parent: NSWindow?) {
        self.model = model
        cardId = card.id
        sourceTitle = card.title
        hasOverride = card.customTitle != nil
        titleField = NSTextField(string: card.displayTitle)
        dialog = RenameTitlePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 174),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configure(card: card, parent: parent)
    }

    func present() {
        previousApplication = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        dialog.makeKeyAndOrderFront(nil)
        dialog.makeFirstResponder(titleField)
        titleField.selectText(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dialog.makeKey()
            self.dialog.makeFirstResponder(self.titleField)
            self.titleField.selectText(nil)
        }
    }

    func cancel() {
        finish()
    }

    func controlTextDidChange(_ notification: Notification) {
        updateValidation()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard !textView.hasMarkedText() else {
            return false
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            saveTitle()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func configure(card: AgentCard, parent: NSWindow?) {
        dialog.title = "작업 제목 변경"
        dialog.isReleasedWhenClosed = false
        dialog.level = .floating
        dialog.hidesOnDeactivate = false
        dialog.delegate = self
        dialog.collectionBehavior = [.moveToActiveSpace]

        let content = NSView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 174)
        )
        dialog.contentView = content

        let label = NSTextField(labelWithString: "카드에 표시할 작업 제목")
        label.frame = NSRect(x: 20, y: 137, width: 320, height: 18)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        content.addSubview(label)

        titleField.frame = NSRect(x: 20, y: 101, width: 320, height: 27)
        titleField.font = .systemFont(ofSize: 14)
        titleField.delegate = self
        titleField.placeholderString = card.title
        titleField.maximumNumberOfLines = 1
        content.addSubview(titleField)

        errorLabel.frame = NSRect(x: 20, y: 80, width: 320, height: 17)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .secondaryLabelColor
        content.addSubview(errorLabel)

        resetButton.frame = NSRect(x: 20, y: 24, width: 108, height: 28)
        resetButton.target = self
        resetButton.action = #selector(resetTitle)
        resetButton.bezelStyle = .rounded
        resetButton.isHidden = !hasOverride
        content.addSubview(resetButton)

        cancelButton.target = self
        cancelButton.action = #selector(cancelTitle)
        cancelButton.frame = NSRect(x: 188, y: 24, width: 72, height: 28)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        content.addSubview(cancelButton)

        saveButton.frame = NSRect(x: 268, y: 24, width: 72, height: 28)
        saveButton.target = self
        saveButton.action = #selector(saveTitle)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        content.addSubview(saveButton)
        dialog.defaultButtonCell = saveButton.cell as? NSButtonCell
        dialog.initialFirstResponder = titleField

        if let parent {
            let screenFrame = parent.screen?.visibleFrame ?? parent.frame
            let size = dialog.frame.size
            dialog.setFrameOrigin(
                NSPoint(
                    x: min(
                        max(parent.frame.midX - size.width / 2, screenFrame.minX),
                        screenFrame.maxX - size.width
                    ),
                    y: min(
                        max(parent.frame.midY - size.height / 2, screenFrame.minY),
                        screenFrame.maxY - size.height
                    )
                )
            )
        } else {
            dialog.center()
        }
        updateValidation()
    }

    private func updateValidation() {
        let value = titleField.stringValue
        do {
            let normalized = try AgentTitleOverride.normalized(value)
            errorLabel.stringValue = "\(normalized.count)/80"
            errorLabel.textColor = .secondaryLabelColor
            saveButton.isEnabled = true
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.textColor = .systemRed
            saveButton.isEnabled = false
        }
    }

    @objc private func saveTitle() {
        do {
            try model.setCustomTitle(titleField.stringValue, for: cardId)
            finish()
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.textColor = .systemRed
            dialog.makeFirstResponder(titleField)
        }
    }

    @objc private func resetTitle() {
        do {
            try model.setCustomTitle(nil, for: cardId)
            finish()
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.textColor = .systemRed
        }
    }

    @objc private func cancelTitle() {
        cancel()
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        dialog.orderOut(nil)
        if let previousApplication,
           !previousApplication.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier
            != previousApplication.processIdentifier {
            previousApplication.activate(options: [.activateIgnoringOtherApps])
        }
        onFinish?()
    }

    var sourceTitleForTesting: String { sourceTitle }
}
