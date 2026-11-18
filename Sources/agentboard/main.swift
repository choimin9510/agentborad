import AgentBoardCore
import Darwin
import Foundation

private func fail(_ message: String, exitCode: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("agentboard: \(message)\n".utf8))
    exit(exitCode)
}

private func arguments() -> [String] {
    Array(CommandLine.arguments.dropFirst())
}

let args = arguments()
if args.first == "agents-install" {
    guard let filePath = flagValue("--file", in: args) else {
        fail("--file 인자가 필요합니다.")
    }
    guard let blockPath = flagValue("--block", in: args) else {
        fail("--block 인자가 필요합니다.")
    }
    do {
        let existing = (try? Data(contentsOf: URL(fileURLWithPath: filePath))) ?? Data()
        let block = try Data(contentsOf: URL(fileURLWithPath: blockPath))
        let result = try AgentsIntegration.install(existing: existing, block: block)
        try AgentsIntegration.writeFile(
            result.data,
            to: URL(fileURLWithPath: filePath),
            createPermissions: NSNumber(value: 0o644)
        )
        print("separator=\(result.usedLeadingSeparator ? 1 : 0)")
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}
if args.first == "agents-remove" {
    guard let filePath = flagValue("--file", in: args) else {
        fail("--file 인자가 필요합니다.")
    }
    let removeSeparator = flagValue("--leading-separator", in: args) == "1"
    do {
        let url = URL(fileURLWithPath: filePath)
        let existing = try Data(contentsOf: url)
        let updated = try AgentsIntegration.remove(
            existing: existing,
            removeLeadingSeparator: removeSeparator
        )
        try AgentsIntegration.writeFile(updated, to: url)
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}
if args.first == "agents-validate" {
    guard let filePath = flagValue("--file", in: args) else {
        fail("--file 인자가 필요합니다.")
    }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        try AgentsIntegration.validate(data)
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}
guard args.first == "report" else {
    fail("사용법: agentboard report --json '<report-json>'")
}
guard let jsonFlag = args.firstIndex(of: "--json"),
      args.indices.contains(jsonFlag + 1) else {
    fail("--json 인자가 필요합니다.")
}
let json = args[jsonFlag + 1]
guard let jsonData = json.data(using: .utf8) else {
    fail("JSON을 UTF-8로 읽을 수 없습니다.")
}

let payload: ReportPayload
do {
    payload = try ReportValidator.decodePayload(jsonData)
} catch {
    fail(error.localizedDescription)
}

private func flagValue(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

guard let threadString = ProcessInfo.processInfo.environment["CODEX_THREAD_ID"],
      let threadId = UUID(uuidString: threadString) else {
    fail("CODEX_THREAD_ID 환경 변수가 필요합니다.")
}

let envelope = ReportEnvelope(
    eventId: UUID(),
    threadId: threadId,
    timestamp: Date(),
    payload: payload,
    origin: SessionOrigin.fromEnvironment()
)
do {
    let encoded = try ReportValidator.encodeEnvelope(envelope)
    guard let text = String(data: encoded, encoding: .utf8) else {
        fail("보고서 인코딩에 실패했습니다.")
    }
    print("\(SessionLineParser.reportMarker)\(text)")
} catch {
    fail(error.localizedDescription)
}
