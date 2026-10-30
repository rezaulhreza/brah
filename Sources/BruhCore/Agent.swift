import Foundation

/// What arrives while the agent works: a piece of the answer, or a step it takes (a tool call,
/// such as "Clicking Save").
public enum AgentEvent: Equatable, Sendable {
    case text(String)
    case step(String)
}

/// An agent that Bruh can ask about the screen. Hermes is the first; Claude and OpenClaw follow
/// the same shape. The agent does any clicking itself. Bruh only sees, talks and points.
public protocol AgentConnection: Sendable {
    var name: String { get }
    /// `onEvent` gets each piece of the answer and each step as it arrives, so speech can start
    /// before the end and the user sees what the agent does.
    func ask(_ question: String, snapshot: Snapshot, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Reply
    /// Forget the conversation, so the next question starts a new one.
    func reset() async
}

public enum Brief {
    /// The instructions every agent gets with a question. Short, because it rides on every turn.
    /// `canAct` is false for an agent that is not on the user's Mac: its screen tools would act
    /// on another computer.
    public static func system(for snapshot: Snapshot, canAct: Bool = true) -> String {
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
        with x and y in screenshot pixels.

        \(canAct ? acting : notActing)
        """
    }

    static let acting = """
    You can work on the screen with computer_use, but only when the user asks you to do \
    something on it. Before your first screen action in a request, say in one short sentence \
    what you will do, end your answer with a line that is exactly
    ASK
    and stop. The screen stays locked until the user says yes; then do the work and say in \
    one short sentence what you did.
    """

    static let notActing = """
    You run on another computer, not on the user's Mac, so do not use computer_use or browser \
    tools for this screen: they would act on your computer. Tell the user where to click instead, \
    and point at it.
    """
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
