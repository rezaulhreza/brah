import Foundation

/// Claude through the user's own Claude Code sign-in: `claude -p` with its tools off, so it only
/// answers. Each question resumes the session of the last one.
public actor ClaudeCodeConnection: AgentConnection {
    public nonisolated let name = "Claude"
    public nonisolated let canAct: Bool
    private var choice: ModelChoice
    private let tools: ToolServerAddress?
    private var sessionID: String?

    private let responses: ResponseSettings

    /// With `tools`, Claude Code can click and type through Brah's MCP server.
    public init(choice: ModelChoice, responses: ResponseSettings = ResponseSettings(), tools: ToolServerAddress? = nil) {
        self.choice = choice
        self.responses = responses
        self.tools = tools
        canAct = tools != nil
    }

    public func reset() { sessionID = nil }
    public func setEffort(_ effort: Effort) { choice.effort = effort }

    public static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".claude/local").path,
               "/opt/homebrew/bin", "/usr/local/bin"]
        return folders.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func arguments(choice: ModelChoice, system: String, resume: String?, tools: ToolServerAddress? = nil) -> [String] {
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages", "--verbose",
         "--model", choice.model, "--effort", choice.effort.rawValue, "--tools", "", "--strict-mcp-config",
         "--setting-sources", "", "--disable-slash-commands", "--system-prompt", system]
            + (tools.map { ["--mcp-config", $0.mcpConfig, "--allowedTools", ToolServerAddress.allowedTools] } ?? [])
            + (resume.map { ["--resume", $0] } ?? [])
    }

    static func input(question: String, snapshot: Snapshot) -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": snapshot.jpeg.base64EncodedString()]],
            ["type": "text", "text": question],
        ]]]
        var data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        data.append(0x0A)
        return data
    }

    public func ask(_ question: String, snapshot: Snapshot, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Reply {
        guard let claude = Self.executable() else { throw ProviderError.notInstalled }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brah/claude")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = claude
        process.arguments = Self.arguments(choice: choice, system: Brief.system(for: snapshot, hands: canAct ? .tools : .none, responses: responses),
                                           resume: sessionID, tools: tools)
        process.currentDirectoryURL = folder
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Self.input(question: question, snapshot: snapshot))
        try? stdin.fileHandleForWriting.close()

        var text = ""
        var failure: ProviderError?
        try await withTaskCancellationHandler {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let id = json["session_id"] as? String { sessionID = id }
                switch json["type"] as? String {
                case "stream_event":
                    // A new message after a tool call: keep its words apart from the ones before.
                    if (json["event"] as? [String: Any])?["type"] as? String == "message_start", !text.isEmpty, !text.hasSuffix("\n") {
                        text += "\n"
                        onEvent(.text("\n"))
                    }
                    switch (json["event"] as? [String: Any]).flatMap(ClaudeEvent.parse) {
                    case .text(let piece):
                        text += piece
                        onEvent(.text(piece))
                    case .error(let error): failure = error
                    case .stop("refusal") where text.isEmpty: failure = .refused
                    default: break
                    }
                case "result" where json["is_error"] as? Bool == true:
                    failure = ProviderError.fromClaudeCode(json["result"] as? String ?? json["subtype"] as? String ?? "")
                default: break
                }
            }
        } onCancel: {
            process.terminate()
        }
        process.waitUntilExit()

        if let failure { throw failure }
        if text.isEmpty {
            let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if process.terminationStatus != 0, !error.isEmpty { throw ProviderError.fromClaudeCode(error) }
            throw AgentError.emptyReply
        }
        return Reply.parse(text)
    }
}
