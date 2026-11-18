import AgentBoardCore
import AppKit
import Darwin
import Foundation

struct NavigationProcessResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
    let launchError: String?

    var isSuccess: Bool {
        launchError == nil && !timedOut && exitCode == 0
    }
}

enum AgentBoardExecutableLocator {
    static func find(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        additionalCandidates: [String] = []
    ) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = additionalCandidates
        switch name {
        case "codex":
            candidates.append(contentsOf: [
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "\(home)/.npm-global/bin/codex",
                "\(home)/.bun/bin/codex"
            ])
        case "cmux":
            candidates.append(contentsOf: [
                "/opt/homebrew/bin/cmux",
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "\(home)/.local/bin/cmux"
            ])
        case "herdr":
            candidates.append(contentsOf: [
                "/opt/homebrew/bin/herdr",
                "\(home)/.local/bin/herdr"
            ])
        default:
            break
        }

        var seen = Set<String>()
        for candidate in candidates {
            guard candidate.hasPrefix("/"),
                  (candidate as NSString).lastPathComponent == name,
                  seen.insert(candidate).inserted,
                  FileManager.default.isExecutableFile(
                      atPath: candidate
                  ) else {
                continue
            }
            return URL(fileURLWithPath: candidate)
                .resolvingSymlinksInPath()
        }
        return nil
    }
}

final class CLIProcessRunner {
    static let maximumCapturedBytes = 256 * 1_024

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 2.5
    ) -> NavigationProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputCapture = BoundedProcessCapture(
            handle: outputPipe.fileHandleForReading
        )
        let errorCapture = BoundedProcessCapture(
            handle: errorPipe.fileHandleForReading
        )
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }
        do {
            try process.run()
        } catch {
            outputCapture.stop()
            errorCapture.stop()
            return NavigationProcessResult(
                exitCode: -1,
                standardOutput: "",
                standardError: "",
                timedOut: false,
                launchError: error.localizedDescription
            )
        }

        let boundedTimeout = max(0.01, timeout)
        var timedOut = termination.wait(
            timeout: .now() + boundedTimeout
        ) == .timedOut
        if timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 0.25) == .timedOut {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                _ = termination.wait(timeout: .now() + 0.25)
            }
        }
        _ = outputCapture.completion.wait(timeout: .now() + 0.15)
        _ = errorCapture.completion.wait(timeout: .now() + 0.15)
        outputCapture.stop()
        errorCapture.stop()
        if process.isRunning {
            timedOut = true
        }
        return NavigationProcessResult(
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            standardOutput: String(
                decoding: outputCapture.data,
                as: UTF8.self
            ),
            standardError: String(
                decoding: errorCapture.data,
                as: UTF8.self
            ),
            timedOut: timedOut,
            launchError: nil
        )
    }
}

private final class BoundedProcessCapture {
    let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var captured = Data()
    private var completed = false
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.finish()
            } else {
                self?.append(data)
            }
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = CLIProcessRunner.maximumCapturedBytes
            - captured.count
        if remaining > 0 {
            captured.append(data.prefix(remaining))
        }
    }

    private func finish() {
        lock.lock()
        let shouldSignal = !completed
        completed = true
        lock.unlock()
        handle.readabilityHandler = nil
        if shouldSignal {
            completion.signal()
        }
    }
}

enum ConversationNavigationResult: Equatable {
    case focused
    case needsTerminal(String)
}

struct TerminalResumePlan: Equatable {
    let fileURL: URL
    let content: String
    let permissions: Int
}

final class ConversationNavigator {
    typealias CommandRunner = (
        URL, [String], [String: String]?, TimeInterval
    ) -> NavigationProcessResult
    typealias ResumeOpener = (
        URL, @escaping (Result<Void, Error>) -> Void
    ) -> Void
    typealias ResumePlanner = (AgentCard) throws -> TerminalResumePlan

    private let runCommand: CommandRunner
    private let openResumeFile: ResumeOpener
    private let createResumePlan: ResumePlanner
    private let presentResumeError: (String) -> Void

    init(
        runCommand: @escaping CommandRunner = { executable, arguments, environment, timeout in
            CLIProcessRunner().run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        },
        openResumeFile: @escaping ResumeOpener = { url, completion in
            guard FileManager.default.fileExists(atPath: TerminalResumeService.terminalApplicationPath)
            else {
                completion(.failure(
                    TerminalResumeError.terminalUnavailable
                ))
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: URL(
                    fileURLWithPath: TerminalResumeService.terminalApplicationPath
                ),
                configuration: configuration,
                completionHandler: { application, error in
                    if let error {
                        completion(.failure(error))
                    } else if application == nil {
                        completion(.failure(
                            TerminalResumeError.launchRejected
                        ))
                    } else {
                        completion(.success(()))
                    }
                }
            )
        },
        createResumePlan: @escaping ResumePlanner = {
            try TerminalResumeService().createPlan(for: $0)
        },
        presentResumeError: @escaping (String) -> Void = {
            ConversationNavigator.showResumeErrorAlert($0)
        }
    ) {
        self.runCommand = runCommand
        self.openResumeFile = openResumeFile
        self.createResumePlan = createResumePlan
        self.presentResumeError = presentResumeError
    }

    func attemptFocus(_ card: AgentCard) -> ConversationNavigationResult {
        guard let origin = card.origin else {
            return .needsTerminal(
                "이 대화의 기존 터미널 위치가 등록되지 않았습니다. 대화가 닫혔다는 의미는 아닙니다."
            )
        }
        switch origin.kind {
        case .herdr:
            return attemptHerdrFocus(card, origin: origin)
        case .cmux:
            guard let workspace = origin.workspaceId,
                  let surface = origin.surfaceId else {
                return .needsTerminal(
                    "cmux workspace 또는 surface 위치가 불완전합니다."
                )
            }
            let environment = cmuxEnvironment(origin: origin)
            let tree = invokeCMUX(
                origin: origin,
                arguments: [
                    "--json", "--id-format", "both", "tree", "--all"
                ],
                environment: environment
            )
            guard tree.isSuccess,
                  let target = cmuxTreeTarget(
                      tree.standardOutput,
                      workspaceId: workspace,
                      surfaceId: surface,
                      expectedWindowId: origin.windowId
                  ) else {
                return .needsTerminal(
                    "cmux에서 정확한 window/workspace/surface 계층을 확인할 수 없습니다: \(processMessage(tree))"
                )
            }

            let resume = invokeCMUX(
                origin: origin,
                arguments: [
                    "--json", "--id-format", "both",
                    "surface", "resume", "show",
                    "--workspace", target.workspaceId,
                    "--surface", target.surfaceId,
                    "--window", target.windowId
                ],
                environment: environment
            )
            guard resume.isSuccess,
                  cmuxResumeBindingMatches(
                      resume.standardOutput,
                      card: card,
                      target: target
                  ) else {
                return .needsTerminal(
                    "cmux의 저장된 resume checkpoint가 현재 Codex thread와 일치하지 않습니다: \(processMessage(resume))"
                )
            }

            let processTree = invokeCMUX(
                origin: origin,
                arguments: [
                    "--json", "--id-format", "both",
                    "top", "--all", "--processes"
                ],
                environment: environment
            )
            guard processTree.isSuccess,
                  cmuxLiveProcessMatches(
                      processTree.standardOutput,
                      card: card,
                      target: target
                  ) else {
                return .needsTerminal(
                    "cmux target surface에서 현재 실행 중인 Codex process를 확인할 수 없습니다: \(processMessage(processTree))"
                )
            }

            let select = invokeCMUX(
                origin: origin,
                arguments: [
                    "--id-format", "both", "select-workspace",
                    "--workspace", target.workspaceId,
                    "--window", target.windowId
                ],
                environment: environment
            )
            guard select.isSuccess else {
                return .needsTerminal(
                    "cmux workspace로 이동하지 못했습니다: \(processMessage(select))"
                )
            }
            let panel = invokeCMUX(
                origin: origin,
                arguments: [
                    "--id-format", "both", "focus-panel",
                    "--panel", target.surfaceId,
                    "--workspace", target.workspaceId,
                    "--window", target.windowId
                ],
                environment: environment
            )
            guard panel.isSuccess else {
                return .needsTerminal(
                    "cmux panel로 이동하지 못했습니다: \(processMessage(panel))"
                )
            }
            let window = invokeCMUX(
                origin: origin,
                arguments: [
                    "--id-format", "both", "focus-window",
                    "--window", target.windowId
                ],
                environment: environment
            )
            guard window.isSuccess else {
                return .needsTerminal(
                    "cmux window focus에 실패했습니다: \(processMessage(window))"
                )
            }
            return .focused
        }
    }

    private func attemptHerdrFocus(
        _ card: AgentCard,
        origin: SessionOrigin
    ) -> ConversationNavigationResult {
        guard let workspace = origin.workspaceId,
              let tab = origin.tabId,
              let pane = origin.paneId else {
            return .needsTerminal(
                "Herdr workspace, tab 또는 pane 위치가 불완전합니다."
            )
        }
        let environment = herdrEnvironment(origin: origin)
        let paneInfo = invokeHerdr(
            arguments: ["pane", "get", pane],
            environment: environment
        )
        guard paneInfo.isSuccess,
              herdrPaneMatchesConversation(
                  paneInfo.standardOutput,
                  card: card,
                  workspaceId: workspace,
                  tabId: tab,
                  paneId: pane
              ) else {
            return .needsTerminal(
                "Herdr pane의 등록된 Codex session을 확인할 수 없습니다: \(processMessage(paneInfo))"
            )
        }

        let agentInfo = invokeHerdr(
            arguments: ["agent", "get", pane],
            environment: environment
        )
        guard agentInfo.isSuccess,
              herdrAgentMatchesConversation(
                  agentInfo.standardOutput,
                  card: card,
                  workspaceId: workspace,
                  tabId: tab,
                  paneId: pane
              ) else {
            return .needsTerminal(
                "Herdr agent의 현재 Codex session이 이 카드와 일치하지 않습니다: \(processMessage(agentInfo))"
            )
        }

        let focus = invokeHerdr(
            arguments: ["agent", "focus", pane],
            environment: environment
        )
        guard focus.isSuccess else {
            return .needsTerminal(
                "Herdr agent pane으로 이동하지 못했습니다: \(processMessage(focus))"
            )
        }
        return .focused
    }

    func presentFallback(_ card: AgentCard, parent: NSWindow?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.attemptFocus(card)
            DispatchQueue.main.async {
                switch result {
                case .focused:
                    return
                case .needsTerminal(let reason):
                    self.showFallbackAlert(reason, card: card, parent: parent)
                }
            }
        }
    }

    func showFallbackAlert(
        _ reason: String,
        card: AgentCard,
        parent: NSWindow?
    ) {
        let previousApplication = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "기존 대화 위치로 이동하지 못했습니다"
        alert.informativeText = reason
        alert.alertStyle = .informational
        alert.addButton(withTitle: "터미널에서 다시 열기")
        alert.addButton(withTitle: "취소")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openTerminalResume(card: card, parent: parent)
        } else if let previousApplication,
                  !previousApplication.isTerminated {
            previousApplication.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func openTerminalResume(card: AgentCard, parent: NSWindow?) {
        do {
            let plan = try createResumePlan(card)
            openResumeFile(plan.fileURL) { [weak self] result in
                guard let self, case .failure(let error) = result else {
                    return
                }
                self.deliverResumeError(
                    "Terminal을 열지 못했습니다: \(error.localizedDescription)"
                )
            }
        } catch {
            deliverResumeError(
                "터미널 재개 파일을 만들 수 없습니다: \(error.localizedDescription)"
            )
        }
    }

    private func invokeCMUX(
        origin: SessionOrigin,
        arguments: [String],
        environment: [String: String]
    ) -> NavigationProcessResult {
        if let cliPath = origin.cliPath,
           FileManager.default.isExecutableFile(atPath: cliPath) {
            return runCommand(
                URL(fileURLWithPath: cliPath),
                arguments,
                environment,
                2.5
            )
        }
        guard let executable = AgentBoardExecutableLocator.find(
            "cmux",
            environment: environment,
            additionalCandidates: origin.cliPath.map { [$0] } ?? []
        ) else {
            return NavigationProcessResult(
                exitCode: -1,
                standardOutput: "",
                standardError: "",
                timedOut: false,
                launchError: "cmux 실행 파일을 찾을 수 없습니다."
            )
        }
        return runCommand(executable, arguments, environment, 2.5)
    }

    private func invokeHerdr(
        arguments: [String],
        environment: [String: String]
    ) -> NavigationProcessResult {
        guard let executable = AgentBoardExecutableLocator.find(
            "herdr",
            environment: environment
        ) else {
            return NavigationProcessResult(
                exitCode: -1,
                standardOutput: "",
                standardError: "",
                timedOut: false,
                launchError: "herdr 실행 파일을 찾을 수 없습니다."
            )
        }
        return runCommand(executable, arguments, environment, 2.5)
    }

    private func cmuxEnvironment(origin: SessionOrigin) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let socket = origin.socketPath {
            environment["CMUX_SOCKET_PATH"] = socket
        }
        return environment
    }

    private func herdrEnvironment(origin: SessionOrigin) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let sessionName = origin.sessionName {
            environment["HERDR_SESSION"] = sessionName
        }
        if let socket = origin.socketPath {
            environment["HERDR_SOCKET_PATH"] = socket
        }
        return environment
    }

    private struct CMUXTarget {
        let windowId: String
        let workspaceId: String
        let surfaceId: String
    }

    private func cmuxTreeTarget(
        _ output: String,
        workspaceId: String,
        surfaceId: String,
        expectedWindowId: String?
    ) -> CMUXTarget? {
        guard let root = jsonObject(from: output) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]],
              UUID(uuidString: workspaceId) != nil,
              UUID(uuidString: surfaceId) != nil else {
            return nil
        }
        for window in windows.prefix(1_000) {
            guard let windowId = window["id"] as? String,
                  UUID(uuidString: windowId) != nil,
                  expectedWindowId == nil || expectedWindowId == windowId,
                  let workspaces = window["workspaces"] as? [[String: Any]]
            else {
                continue
            }
            for workspace in workspaces.prefix(10_000) {
                guard workspace["id"] as? String == workspaceId,
                      let panes = workspace["panes"] as? [[String: Any]]
                else {
                    continue
                }
                for pane in panes.prefix(10_000) {
                    guard let paneId = pane["id"] as? String,
                          UUID(uuidString: paneId) != nil,
                          let surfaces = pane["surfaces"] as? [[String: Any]]
                    else {
                        continue
                    }
                    for surface in surfaces.prefix(10_000) {
                        guard surface["id"] as? String == surfaceId,
                              surface["pane_id"] as? String == paneId
                        else {
                            continue
                        }
                        return CMUXTarget(
                            windowId: windowId,
                            workspaceId: workspaceId,
                            surfaceId: surfaceId
                        )
                    }
                }
            }
        }
        return nil
    }

    private func cmuxResumeBindingMatches(
        _ output: String,
        card: AgentCard,
        target: CMUXTarget
    ) -> Bool {
        guard let object = jsonObject(from: output) as? [String: Any],
              object["window_id"] as? String == target.windowId,
              object["workspace_id"] as? String == target.workspaceId,
              object["surface_id"] as? String == target.surfaceId,
              let binding = object["resume_binding"] as? [String: Any],
              let checkpoint = firstString(
                  in: binding,
                  keys: ["checkpoint_id"]
              ),
              let checkpointId = UUID(uuidString: checkpoint),
              checkpointId == card.id,
              bindingMatchesProvider(binding, card: card) else {
            return false
        }
        return true
    }

    private func cmuxLiveProcessMatches(
        _ output: String,
        card: AgentCard,
        target: CMUXTarget
    ) -> Bool {
        guard let root = jsonObject(from: output) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]]
        else {
            return false
        }
        for window in windows.prefix(1_000) {
            guard window["id"] as? String == target.windowId,
                  let workspaces = window["workspaces"] as? [[String: Any]]
            else {
                continue
            }
            for workspace in workspaces.prefix(10_000) {
                guard workspace["id"] as? String == target.workspaceId,
                      let panes = workspace["panes"] as? [[String: Any]]
                else {
                    continue
                }
                for pane in panes.prefix(10_000) {
                    guard let paneId = pane["id"] as? String,
                          let surfaces = pane["surfaces"] as? [[String: Any]]
                    else {
                        continue
                    }
                    for surface in surfaces.prefix(10_000) {
                        guard surface["id"] as? String == target.surfaceId,
                              surface["pane_id"] as? String == paneId
                        else {
                            continue
                        }
                        return containsRunningCodexProcess(
                            in: surface,
                            card: card
                        )
                    }
                }
            }
        }
        return false
    }

    private func bindingMatchesProvider(
        _ binding: [String: Any],
        card: AgentCard
    ) -> Bool {
        let values = commandStrings(in: binding)
        guard !values.isEmpty else { return false }
        let combined = values.joined(separator: " ").lowercased()
        let hasCodex = combined.contains("codex")
            || combined.contains("openai")
        let hasDeepSeekProfile =
            combined.range(
                of: #"--profile(?:=|\s+)ds(?:\s|$)"#,
                options: .regularExpression
            ) != nil
        switch card.provider {
        case .openai:
            return hasCodex
                && !combined.contains("deepseek")
                && !hasDeepSeekProfile
        case .deepseek:
            return (combined.contains("deepseek") || hasCodex)
                && hasDeepSeekProfile
        }
    }

    private func containsRunningCodexProcess(
        in value: Any,
        card: AgentCard
    ) -> Bool {
        var remainingNodes = 12_000
        return containsRunningCodexProcess(
            in: value,
            card: card,
            depth: 0,
            remainingNodes: &remainingNodes
        )
    }

    private func containsRunningCodexProcess(
        in value: Any,
        card: AgentCard,
        depth: Int,
        remainingNodes: inout Int
    ) -> Bool {
        guard depth <= 12, remainingNodes > 0 else { return false }
        remainingNodes -= 1
        if let array = value as? [Any] {
            for item in array.prefix(10_000) {
                if containsRunningCodexProcess(
                    in: item,
                    card: card,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes
                ) {
                    return true
                }
            }
            return false
        }
        guard let dictionary = value as? [String: Any] else {
            return false
        }
        if dictionaryHasRunningProcess(dictionary, card: card) {
            return true
        }
        for (_, item) in dictionary {
            if containsRunningCodexProcess(
                in: item,
                card: card,
                depth: depth + 1,
                remainingNodes: &remainingNodes
            ) {
                return true
            }
        }
        return false
    }

    private func dictionaryHasRunningProcess(
        _ dictionary: [String: Any],
        card: AgentCard
    ) -> Bool {
        guard let pidValue = dictionary["pid"],
              let pid = positiveInt(pidValue),
              pid > 0 else {
            return false
        }
        for key in ["running", "is_running", "isRunning"] {
            if let running = dictionary[key] as? Bool, !running {
                return false
            }
        }
        for key in ["state", "status"] {
            if let state = dictionary[key] as? String,
               ["exited", "stopped", "done"].contains(state.lowercased()) {
                return false
            }
        }
        return processIsCodex(dictionary)
    }

    private func processIsCodex(_ dictionary: [String: Any]) -> Bool {
        for key in ["executable", "executable_path", "path"] {
            if let executable = dictionary[key] as? String,
               !executable.isEmpty {
                return (
                    executable as NSString
                ).lastPathComponent.lowercased() == "codex"
            }
        }
        if let argv = dictionary["argv"] as? [String],
           let executable = argv.first,
           !executable.isEmpty {
            return (
                executable as NSString
            ).lastPathComponent.lowercased() == "codex"
        }
        if let name = dictionary["name"] as? String,
           !name.isEmpty {
            return (
                name as NSString
            ).lastPathComponent.lowercased() == "codex"
        }
        return false
    }

    private func positiveInt(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.intValue
    }

    private func commandStrings(in value: Any) -> [String] {
        var result: [String] = []
        var remainingNodes = 4_000
        collectCommandStrings(
            value,
            depth: 0,
            remainingNodes: &remainingNodes,
            into: &result
        )
        return result
    }

    private func collectCommandStrings(
        _ value: Any,
        depth: Int,
        remainingNodes: inout Int,
        into result: inout [String]
    ) {
        guard depth <= 8, remainingNodes > 0, result.count < 256 else {
            return
        }
        remainingNodes -= 1
        if let string = value as? String {
            result.append(string)
            return
        }
        if let array = value as? [Any] {
            for item in array.prefix(256) {
                collectCommandStrings(
                    item,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes,
                    into: &result
                )
            }
            return
        }
        guard let dictionary = value as? [String: Any] else { return }
        let commandKeys = Set([
            "kind", "provider", "source", "source_kind",
            "executable", "path", "command", "command_line",
            "commandLine", "cmdline", "name", "args", "argv"
        ])
        for (key, item) in dictionary {
            if commandKeys.contains(key) {
                collectCommandStrings(
                    item,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes,
                    into: &result
                )
            }
        }
    }

    private func herdrPaneMatchesConversation(
        _ output: String,
        card: AgentCard,
        workspaceId: String,
        tabId: String,
        paneId: String
    ) -> Bool {
        guard let object = jsonObject(from: output) else { return false }
        var remainingNodes = 20_000
        return herdrPaneContainsConversation(
            object,
            inheritedWorkspaceId: nil,
            inheritedTabId: nil,
            card: card,
            workspaceId: workspaceId,
            tabId: tabId,
            paneId: paneId,
            depth: 0,
            remainingNodes: &remainingNodes
        )
    }

    private func herdrPaneContainsConversation(
        _ value: Any,
        inheritedWorkspaceId: String?,
        inheritedTabId: String?,
        card: AgentCard,
        workspaceId: String,
        tabId: String,
        paneId: String,
        depth: Int,
        remainingNodes: inout Int
    ) -> Bool {
        guard depth <= 16, remainingNodes > 0 else { return false }
        remainingNodes -= 1
        if let array = value as? [Any] {
            for item in array.prefix(10_000) {
                if herdrPaneContainsConversation(
                    item,
                    inheritedWorkspaceId: inheritedWorkspaceId,
                    inheritedTabId: inheritedTabId,
                    card: card,
                    workspaceId: workspaceId,
                    tabId: tabId,
                    paneId: paneId,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes
                ) {
                    return true
                }
            }
            return false
        }
        guard let dictionary = value as? [String: Any] else {
            return false
        }
        let currentWorkspace = identifier(
            in: dictionary,
            keys: ["workspace_id", "workspaceId", "workspaceID"]
        ) ?? inheritedWorkspaceId
        let currentTab = identifier(
            in: dictionary,
            keys: ["tab_id", "tabId", "tabID"]
        ) ?? inheritedTabId
        let currentPane = identifier(
            in: dictionary,
            keys: ["pane_id", "paneId", "paneID"]
        )
        if currentWorkspace == workspaceId,
           currentTab == tabId,
           currentPane == paneId,
           herdrSessionMatches(in: dictionary, card: card) {
            return true
        }
        for (_, item) in dictionary {
            if herdrPaneContainsConversation(
                item,
                inheritedWorkspaceId: currentWorkspace,
                inheritedTabId: currentTab,
                card: card,
                workspaceId: workspaceId,
                tabId: tabId,
                paneId: paneId,
                depth: depth + 1,
                remainingNodes: &remainingNodes
            ) {
                return true
            }
        }
        return false
    }

    private func herdrAgentMatchesConversation(
        _ output: String,
        card: AgentCard,
        workspaceId: String,
        tabId: String,
        paneId: String
    ) -> Bool {
        guard let object = jsonObject(from: output) else { return false }
        var remainingNodes = 20_000
        return herdrPaneContainsConversation(
            object,
            inheritedWorkspaceId: nil,
            inheritedTabId: nil,
            card: card,
            workspaceId: workspaceId,
            tabId: tabId,
            paneId: paneId,
            depth: 0,
            remainingNodes: &remainingNodes
        )
    }

    private func herdrSessionMatches(
        in dictionary: [String: Any],
        card: AgentCard
    ) -> Bool {
        guard let session = dictionary["agent_session"] as? [String: Any]
        else {
            return false
        }
        return agentSessionBinding(in: session, card: card)
    }

    private func agentSessionBinding(
        in dictionary: [String: Any],
        card: AgentCard
    ) -> Bool {
        guard let source = firstString(in: dictionary, keys: ["source"]),
        !source.isEmpty,
        let agent = firstString(in: dictionary, keys: ["agent"]),
        herdrAgentKindMatches(agent, card: card) else {
            return false
        }
        let kind = firstString(in: dictionary, keys: ["kind"])?.lowercased()
        let value = firstString(
            in: dictionary,
            keys: ["value"]
        )
        guard kind == "id",
              let value,
              let threadId = UUID(uuidString: value),
              threadId == card.id,
              explicitModelProviderMatches(dictionary, card: card) else {
            return false
        }
        return true
    }

    private func explicitModelProviderMatches(
        _ dictionary: [String: Any],
        card: AgentCard
    ) -> Bool {
        guard let declared = firstString(
            in: dictionary,
            keys: ["model_provider"]
        )?.lowercased() else {
            return true
        }
        if declared.contains("deepseek") || declared == "ds" {
            return card.provider == .deepseek
        }
        if declared.contains("openai")
            || declared == "gpt"
            || declared.hasPrefix("gpt-") {
            return card.provider == .openai
        }
        return true
    }

    private func herdrAgentKindMatches(
        _ value: String,
        card: AgentCard
    ) -> Bool {
        let normalized = value.lowercased()
        if normalized == "codex"
            || normalized.hasPrefix("openai-")
            || normalized == "openai" {
            return true
        }
        switch card.provider {
        case .deepseek:
            return normalized == "deepseek"
                || normalized.hasPrefix("deepseek-")
        case .openai:
            return normalized == "gpt"
                || normalized.hasPrefix("gpt-")
        }
    }

    private func identifier(
        in dictionary: [String: Any],
        keys: [String]
    ) -> String? {
        firstString(in: dictionary, keys: keys)
    }

    private func firstString(
        in dictionary: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func jsonObject(from output: String) -> Any? {
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func processMessage(_ result: NavigationProcessResult) -> String {
        if result.timedOut {
            return "시간 초과"
        }
        if let launchError = result.launchError {
            return launchError
        }
        let message = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "exit \(result.exitCode)" : message
    }

    private func deliverResumeError(_ message: String) {
        if Thread.isMainThread {
            presentResumeError(message)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.presentResumeError(message)
            }
        }
    }

    private static func showResumeErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Terminal에서 대화를 다시 열 수 없습니다"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

enum TerminalResumeError: LocalizedError {
    case terminalUnavailable
    case launchRejected
    case codexUnavailable

    var errorDescription: String? {
        switch self {
        case .terminalUnavailable:
            return "Terminal 앱을 찾을 수 없습니다."
        case .launchRejected:
            return "Terminal이 재개 파일 열기를 거부했습니다."
        case .codexUnavailable:
            return "검증된 codex 실행 경로를 찾을 수 없습니다."
        }
    }
}

final class TerminalResumeService {
    static let terminalApplicationPath =
        "/System/Applications/Utilities/Terminal.app"
    private let resolveCodex: () -> URL?
    private let codexHome: URL

    init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        resolveCodex: @escaping () -> URL? = {
            AgentBoardExecutableLocator.find("codex")
        }
    ) {
        self.codexHome = codexHome
        self.resolveCodex = resolveCodex
    }

    func createPlan(for card: AgentCard) throws -> TerminalResumePlan {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBoardResume", isDirectory: true)
            .appendingPathComponent(
                "\(card.id.uuidString)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let fileURL = directory.appendingPathComponent("resume.command")
        let workingDirectory = card.cwd?.isEmpty == false
            ? card.cwd!
            : FileManager.default.homeDirectoryForCurrentUser.path
        let codexArguments: String
        switch card.provider {
        case .openai:
            codexArguments = "resume \(shellQuote(card.id.uuidString))"
        case .deepseek:
            codexArguments =
                "--profile ds resume \(shellQuote(card.id.uuidString))"
        }
        guard let codex = resolveCodex() else {
            throw TerminalResumeError.codexUnavailable
        }
        let content = """
        #!/bin/zsh
        cd -- \(shellQuote(workingDirectory)) || exit 1
        export CODEX_HOME=\(shellQuote(codexHome.path))
        exec \(shellQuote(codex.path)) \(codexArguments)

        """
        try Data(content.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: fileURL.path
        )
        return TerminalResumePlan(
            fileURL: fileURL,
            content: content,
            permissions: 0o700
        )
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
