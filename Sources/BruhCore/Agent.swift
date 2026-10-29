import Foundation

/// An agent that Bruh can ask about the screen. Hermes is the first; Claude and OpenClaw follow
/// the same shape. The agent does any clicking itself. Bruh only sees, talks and points.
public protocol AgentConnection: Sendable {
    var name: String { get }
    /// `onText` gets each piece of the answer as it arrives, so speech can start before the end.
    func ask(_ question: String, snapshot: Snapshot, onText: @escaping @Sendable (String) -> Void) async throws -> Reply
    /// Forget the conversation, so the next question starts a new one.
    func reset() async
}

public enum Brief {
    /// The instructions every agent gets with a question. Short, because it rides on every turn.
    public static func system(for snapshot: Snapshot) -> String {
        let width = Int(snapshot.imageSize.width)
        let height = Int(snapshot.imageSize.height)
        let cx = Int(snapshot.cursor.x)
        let cy = Int(snapshot.cursor.y)
        var place = ""
        if let app = snapshot.appName {
            place = " The front app is \(app)"
            if let title = snapshot.windowTitle, !title.isEmpty {
                place += ", window \"\(title)\""
            }
            place += "."
        }

        return """
        You are Bruh, a helper that sits next to the user's mouse cursor on their Mac. They pressed \
        a hotkey and asked you something about their screen. The image is a screenshot of the display \
        they use, \(width)x\(height) pixels, origin top-left. A red ring marks their cursor at \
        (\(cx), \(cy)).\(place)

        Answer in at most three short sentences. Your words are spoken aloud: no markdown, no lists, \
        no code blocks. If showing a place on the screen helps, end with one line exactly like \
        POINT 412 230 Save button
        with x and y in screenshot pixels. Do not click or type on the computer unless the user asks.
        """
    }
}

public enum AgentError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let why): return why
        case .http(let status, let body): return "The agent answered \(status). \(body.prefix(200))"
        case .emptyReply: return "The agent sent an empty answer."
        }
    }
}
