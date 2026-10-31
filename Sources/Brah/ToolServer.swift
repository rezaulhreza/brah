import BrahCore
import Foundation
import Network

/// A tiny MCP server on 127.0.0.1 that gives Claude Code Brah's screen tools. The token is new on
/// each run, so other programs on the Mac cannot use the tools.
final class ToolServer: @unchecked Sendable {
    private let listener: NWListener
    private let actions: ScreenActing
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "brah.tools")

    init(actions: ScreenActing) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.actions = actions
    }

    /// Starts listening and returns the address, or nil when the port does not open in time.
    func start() -> ToolServerAddress? {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let port = listener.port?.rawValue else { return nil }
        return ToolServerAddress(url: URL(string: "http://127.0.0.1:\(port)/mcp")!, token: token)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self, error == nil else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            guard let request = HTTPRequest(buffer) else {
                return complete ? connection.cancel() : self.read(connection, buffer: buffer)
            }
            Task { await self.answer(request, on: connection) }
        }
    }

    private func answer(_ request: HTTPRequest, on connection: NWConnection) async {
        guard request.headers["authorization"] == "Bearer \(token)" else { return send(401, nil, on: connection) }
        guard request.method == "POST" else { return send(405, nil, on: connection) }
        let body = await MCP.respond(to: request.body, actions: actions)
        send(body == nil ? 202 : 200, body, on: connection)
    }

    private func send(_ status: Int, _ body: Data?, on connection: NWConnection) {
        let reason = [200: "OK", 202: "Accepted", 401: "Unauthorized", 405: "Method Not Allowed"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + (body ?? Data()), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// One HTTP request, once the headers and the whole body have arrived.
private struct HTTPRequest {
    var method: String
    var headers: [String: String]
    var body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
        headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { $1 })
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        self.body = Data(body.prefix(length))
    }
}
