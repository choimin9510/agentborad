import AgentBoardCore
import AppKit
import Darwin
import Foundation

@main
enum AgentBoardMain {
    static func main() {
        let options: LaunchOptions
        do {
            options = try LaunchOptions.parse(CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(
                Data("AgentBoard: \(error.localizedDescription)\n".utf8)
            )
            exit(2)
        }

        if options.ingestOnce {
            runFixtureIngestion(options)
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate(options: options)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    private static func runFixtureIngestion(_ options: LaunchOptions) {
        do {
            let store = try StateStore(path: options.databaseURL().path)
            let collector = SessionCollector(
                codexHomes: options.codexHomes,
                store: store,
                trustPolicy: ReportTrustPolicy(
                    additionalHelperPaths: options.reportHelperPath.map { [$0] } ?? []
                )
            )
            let summary = collector.scanOnceSync()
            print(
                "files=\(summary.filesScanned) records=\(summary.recordsIngested) errors=\(summary.errors.count)"
            )
            for error in summary.errors {
                FileHandle.standardError.write(Data("AgentBoard: \(error)\n".utf8))
            }
            exit(summary.errors.isEmpty ? 0 : 1)
        } catch {
            FileHandle.standardError.write(
                Data("AgentBoard: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private var model: BoardViewModel!
    private var panelController: PanelController!
    private var collector: SessionCollector?
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private let completionSound = NSSound(
        contentsOfFile: "/System/Library/Sounds/Glass.aiff",
        byReference: true
    )

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        let preferences: UserDefaults
        if options.demo {
            preferences = UserDefaults(suiteName: "app.agentboard.demo") ?? .standard
        } else if options.dataDirectory != nil {
            preferences = UserDefaults(suiteName: "app.agentboard.fixture") ?? .standard
        } else {
            preferences = .standard
        }
        if options.demo {
            model = BoardViewModel.demo(defaults: preferences)
        } else {
            do {
                let store = try StateStore(path: options.databaseURL().path)
                model = BoardViewModel(store: store, defaults: preferences)
                let collector = SessionCollector(
                    codexHomes: options.codexHomes,
                    store: store,
                    trustPolicy: ReportTrustPolicy(
                        additionalHelperPaths: options.reportHelperPath.map { [$0] } ?? []
                    )
                )
                self.collector = collector
                collector.onUpdate = { [weak self] update in
                    DispatchQueue.main.async {
                        self?.model.setCollector(update)
                    }
                }
                collector.start()
            } catch {
                model = BoardViewModel(store: nil, defaults: preferences)
                model.setFatalError("저장소 초기화 실패: \(error.localizedDescription)")
            }
        }

        model.onFreshCompletionSound = { [weak self] in
            self?.playCompletionSound()
        }
        panelController = PanelController(
            model: model,
            defaults: preferences,
            onQuit: { NSApp.terminate(nil) },
            pinChanged: { [weak self] pinned in
                self?.model.pinned = pinned
            }
        )
        buildStatusItem()
        panelController.showPanel()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) {
            [weak self] _ in
            self?.model.refresh()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        panelController?.shutdownCursor()
        completionSound?.stop()
        collector?.stop()
    }

    @objc private func screensChanged() {
        panelController.clampToVisibleScreen()
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp {
            statusItem.menu = buildStatusMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            panelController.togglePanel()
        }
    }

    @objc private func togglePanelFromMenu() {
        panelController.togglePanel()
    }

    @objc private func togglePinFromMenu() {
        panelController.applyPin(!model.pinned)
    }

    @objc private func toggleHistoryFromMenu() {
        model.setShowAllHistory(!model.showAllHistory)
    }

    @objc private func toggleArchivedFromMenu() {
        model.showArchived.toggle()
    }

    @objc private func toggleCompletionSoundFromMenu() {
        model.completionSoundEnabled.toggle()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func playCompletionSound() {
        guard model.completionSoundEnabled else { return }
        completionSound?.volume = 0.35
        if Thread.isMainThread {
            completionSound?.play()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.completionSoundEnabled else {
                    return
                }
                self.completionSound?.volume = 0.35
                self.completionSound?.play()
            }
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "AgentBoard 종료",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.stack",
                accessibilityDescription: "AgentBoard"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "AgentBoard"
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(
            withTitle: panelController.panel.isVisible ? "패널 숨기기" : "패널 열기",
            action: #selector(togglePanelFromMenu),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        let pin = menu.addItem(
            withTitle: "항상 위",
            action: #selector(togglePinFromMenu),
            keyEquivalent: ""
        )
        pin.target = self
        pin.state = model.pinned ? .on : .off
        let history = menu.addItem(
            withTitle: "전체 기록",
            action: #selector(toggleHistoryFromMenu),
            keyEquivalent: ""
        )
        history.target = self
        history.state = model.showAllHistory ? .on : .off
        let archived = menu.addItem(
            withTitle: "숨긴 카드 보기",
            action: #selector(toggleArchivedFromMenu),
            keyEquivalent: ""
        )
        archived.target = self
        archived.state = model.showArchived ? .on : .off
        let sound = menu.addItem(
            withTitle: "완료 효과음",
            action: #selector(toggleCompletionSoundFromMenu),
            keyEquivalent: ""
        )
        sound.target = self
        sound.state = model.completionSoundEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "AgentBoard 종료",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        ).target = self
        return menu
    }
}
