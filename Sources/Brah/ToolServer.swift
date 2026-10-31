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
struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        method = start.first.map(String.init) ?? ""
        path = start.dropFirst().first.map(String.init) ?? ""
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

/// Read-only tour state on a fixed local port, so the benchmark page can show what Brah does.
/// It takes no commands: the page starts and stops the tour with brah:// links.
final class StatusServer: @unchecked Sendable {
    static let port: UInt16 = 47719
    private let listener: NWListener
    private let status: @MainActor @Sendable () -> Data
    private let queue = DispatchQueue(label: "brah.status")

    init(status: @escaping @MainActor @Sendable () -> Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        listener = try NWListener(using: parameters)
        self.status = status
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self, error == nil else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            guard let request = HTTPRequest(buffer) else {
                return complete ? connection.cancel() : self.read(connection, buffer: buffer)
            }
            Task {
                let body = request.method == "GET" && request.path.hasPrefix("/tour") ? await self.status() : nil
                var head = "HTTP/1.1 \(body == nil ? "204 No Content" : "200 OK")\r\nAccess-Control-Allow-Origin: *\r\n"
                    + "Access-Control-Allow-Private-Network: true\r\nCache-Control: no-store\r\nConnection: close\r\n"
                    + "Content-Length: \(body?.count ?? 0)\r\n"
                if body != nil { head += "Content-Type: application/json\r\n" }
                connection.send(content: Data((head + "\r\n").utf8) + (body ?? Data()),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
