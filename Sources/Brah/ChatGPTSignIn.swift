import AppKit
import BrahCore
import Foundation
import Network

/// The browser sign-in to ChatGPT. Brah opens the sign-in page, listens on 127.0.0.1 for the
/// redirect that ends it, and trades the code for tokens. The Codex app is not involved.
@MainActor
enum ChatGPTSignIn {
    static func run() async throws -> ChatGPTTokens {
        let pkce = ChatGPTAuth.PKCE()
        let server = OAuthCallbackServer(state: ChatGPTAuth.randomState())
        let port = try await server.start()
        defer { server.stop() }

        let redirect = ChatGPTAuth.redirectURI(port: port)
        NSWorkspace.shared.open(ChatGPTAuth.authorizeURL(redirectURI: redirect, challenge: pkce.challenge, state: server.state))
        let code = try await withTaskCancellationHandler {
            try await server.code()
        } onCancel: {
            server.stop()
        }
        return try await ChatGPTAuth.exchange(code: code, verifier: pkce.verifier, redirectURI: redirect)
    }
}

/// A one-shot web server for the redirect of an OAuth sign-in. Every property belongs to `queue`.
final class OAuthCallbackServer: @unchecked Sendable {
    let state: String
    private let queue = DispatchQueue(label: "brah.oauth")
    private var listener: NWListener?
    private var waiter: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(state: String) {
        self.state = state
    }

    /// Opens the first free port of the sign-in and returns it.
    func start() async throws -> UInt16 {
        for port in ChatGPTAuth.ports {
            if let listener = try? await open(port) {
                queue.sync {
                    self.listener = listener
                    // A sign-in that nobody finishes ends by itself.
                    queue.asyncAfter(deadline: .now() + 300) { [weak self] in self?.finish(.failure(ChatGPTLoginError.timedOut)) }
                }
                return port
            }
        }
        throw ChatGPTLoginError.portBusy
    }

    func code() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result {
                    continuation.resume(with: result)
                } else {
                    self.waiter = continuation
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.finish(.failure(CancellationError()))
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func finish(_ outcome: Result<String, Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
    }

    private func open(_ port: UInt16) async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            // The state handler runs on `queue`, one call at a time.
            final class Flag: @unchecked Sendable { var settled = false }
            let flag = Flag()
            listener.stateUpdateHandler = { state in
                guard !flag.settled else { return }
                switch state {
                case .ready:
                    flag.settled = true
                    continuation.resume(returning: listener)
                case .failed(let error):
                    flag.settled = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self, error == nil else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            guard let request = HTTPRequest(buffer) else {
                return complete ? connection.cancel() : self.read(connection, buffer: buffer)
            }
            let (status, page) = self.answer(request)
            let body = Data(page.utf8)
            let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func answer(_ request: HTTPRequest) -> (Int, String) {
        guard request.method == "GET" else { return (404, "") }
        switch ChatGPTAuth.callback(path: request.path, state: state) {
        case .code(let code):
            finish(.success(code))
            return (200, Self.page("You are signed in", "Go back to Brah. You can close this tab."))
        case .failed(let error):
            finish(.failure(error))
            return (200, Self.page("Sign-in stopped", "Go back to Brah and try again."))
        case .ignore:
            return (404, "")
        }
    }

    private static func page(_ title: String, _ text: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Brah</title>
        <body style="font:16px -apple-system,sans-serif;text-align:center;margin-top:20vh">
        <h2>\(title)</h2><p>\(text)</p></body>
        """
    }
}
