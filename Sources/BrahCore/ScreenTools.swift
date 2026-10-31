import Foundation

/// What a screen tool gives back: words for the agent, and a new screenshot after an action.
public struct ToolResult: Sendable {
    public var text: String
    public var jpeg: Data?
    public var isError: Bool

    public init(text: String, jpeg: Data? = nil, isError: Bool = false) {
        self.text = text
        self.jpeg = jpeg
        self.isError = isError
    }
}

/// Runs a screen tool on this Mac. `input` is the tool's JSON object.
public protocol ScreenActing: Sendable {
    func run(_ name: String, input: Data) async -> ToolResult
}

/// Where Brah's MCP server listens, for Claude Code.
public struct ToolServerAddress: Sendable {
    public var url: URL
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    public var mcpConfig: String {
        let config = ["mcpServers": ["brah": ["type": "http", "url": url.absoluteString, "headers": ["Authorization": "Bearer \(token)"]]]]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    public static let allowedTools = ScreenTool.names.map { "mcp__brah__\($0)" }.joined(separator: ",")
}

/// The JSON-RPC side of a minimal MCP server: initialize, tools/list and tools/call.
public enum MCP {
    /// The response body for a request body, or nil for a notification.
    public static func respond(to body: Data, actions: ScreenActing) async -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = request["id"] else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch request["method"] as? String {
        case "initialize":
            response["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                                  "capabilities": ["tools": [String: Any]()],
                                  "serverInfo": ["name": "brah", "version": "1"]]
        case "ping":
            response["result"] = [String: Any]()
        case "tools/list":
            response["result"] = ["tools": ScreenTool.specs.map { spec in
                ["name": spec["name"]!, "description": spec["description"]!, "inputSchema": spec["input_schema"]!]
            }]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let input = (try? JSONSerialization.data(withJSONObject: params["arguments"] ?? [String: Any]())) ?? Data("{}".utf8)
            let result = await actions.run(name, input: input)
            var content: [[String: Any]] = [["type": "text", "text": result.text]]
            if let jpeg = result.jpeg {
                content.append(["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"])
            }
            response["result"] = ["content": content, "isError": result.isError]
        default:
            response["error"] = ["code": -32601, "message": "Method not found"]
        }
        return encode(response)
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }
}

/// The tools an agent gets to work on the screen. Coordinates are pixels of the latest screenshot.
public enum ScreenTool {
    public static let names = ["screenshot", "click", "type", "key", "scroll"]

    private static let label: [String: Any] = ["type": "string", "description": "What this does, in a few words: \"Open the Acquisition tab\"."]
    private static let risky: [String: Any] = ["type": "boolean", "description": "True when it sends, pays, deletes, publishes, submits or signs in."]

    public static let specs: [[String: Any]] = [
        ["name": "screenshot", "description": "See the screen as it is now.",
         "input_schema": ["type": "object", "properties": [String: Any]()]],
        ["name": "click", "description": "Click a point of the latest screenshot. Returns a new screenshot.",
         "input_schema": ["type": "object", "required": ["x", "y", "label"], "properties": [
            "x": ["type": "number"], "y": ["type": "number"], "label": label, "risky": risky,
            "double": ["type": "boolean"], "right": ["type": "boolean"],
         ]]],
        ["name": "type", "description": "Type text where the focus is. Returns a new screenshot.",
         "input_schema": ["type": "object", "required": ["text"], "properties": ["text": ["type": "string"], "risky": risky]]],
        ["name": "key", "description": "Press a key or a shortcut: return, tab, esc, delete, up, cmd+l, shift+tab. Returns a new screenshot.",
         "input_schema": ["type": "object", "required": ["keys", "label"], "properties": ["keys": ["type": "string"], "label": label, "risky": risky]]],
        ["name": "scroll", "description": "Scroll at a point. Returns a new screenshot.",
         "input_schema": ["type": "object", "required": ["x", "y", "direction"], "properties": [
            "x": ["type": "number"], "y": ["type": "number"],
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
            "amount": ["type": "integer", "description": "1 to 10, default 3"],
         ]]],
    ]

    private static let riskyVerbs: Set<String> = ["send", "pay", "purchase", "buy", "delete", "remove", "erase", "publish", "post",
                                                  "submit", "confirm", "transfer", "refund", "launch", "unsubscribe", "share"]

    /// An action needs a yes first when the agent says so, or when its label starts with a risky
    /// verb: "Send invoice" does, "Open send time menu" does not.
    public static func isRisky(label: String, flagged: Bool) -> Bool {
        if flagged { return true }
        let words = Phrases.normalise(label).split(separator: " ").map(String.init)
        guard let verb = words.first else { return false }
        if verb == "sign" || verb == "log" { return words.dropFirst().first == "in" }
        return riskyVerbs.contains(verb)
    }
}
