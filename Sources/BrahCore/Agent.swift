import Foundation

/// What arrives while the agent works: a piece of the answer, or a step it takes (a tool call,
/// such as "Clicking Save").
public enum AgentEvent: Equatable, Sendable {
    case text(String)
    case step(String)
}

/// An agent that Brah can ask about the screen. Hermes is the first; Claude and OpenClaw follow
/// the same shape. The agent does any clicking itself. Brah only sees, talks and points.
public protocol AgentConnection: Sendable {
    var name: String { get }
    /// True when the agent can click and type on this Mac.
    var canAct: Bool { get }
    /// `onEvent` gets each piece of the answer and each step as it arrives, so speech can start
    /// before the end and the user sees what the agent does.
    func ask(_ question: String, snapshot: Snapshot, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Reply
    /// Forget the conversation, so the next question starts a new one.
    func reset() async
    /// Applies from the next question, in the same conversation.
    func setEffort(_ effort: Effort) async
}

extension AgentConnection {
    public func setEffort(_ effort: Effort) async {}
}

public enum Brief {
    public enum Hands { case acts, remote, none }

    /// The instructions every agent gets with a question. Short, because it rides on every turn.
    /// `.remote` is an agent on another computer: its screen tools would act there.
    public static func system(for snapshot: Snapshot, hands: Hands = .acts) -> String {
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
        You are Brah, a helper that sits next to the user's mouse cursor on their Mac. They pressed \
        a hotkey and asked you something about their screen. The image is a screenshot of the display \
        they use, \(width)x\(height) pixels, origin top-left. A red ring marks their cursor at \
        (\(cx), \(cy)).\(place)

        Answer in at most three short sentences. Your words are spoken aloud: no markdown, no lists, \
        no code blocks. If showing a place on the screen helps, end with one line exactly like \
        POINT 412 230 Save button
        with x and y in screenshot pixels.

        To mark things up as on a whiteboard, add up to four lines like these, in screenshot pixels:
        CIRCLE 380 210 140 40 Total
        BOX 40 300 600 180 This table
        UNDERLINE 120 512 360 The date
        ARROW 700 100 520 210 Click here
        LINE 100 400 180 380 260 420
        CIRCLE and BOX take the top-left corner, width and height of the thing. ARROW goes from the \
        tail to the tip. LINE is free-hand through its points. Mark only when it helps.

        \(guiding)

        \(hands == .acts ? acting : hands == .remote ? notActing : noHands)
        """
    }

    static let guiding = """
    When the user asks how to do something that takes more than one click, show them one step \
    at a time. Say the step in one short sentence and end with one line exactly like
    STEP 412 230 Export
    with x and y in screenshot pixels, on the place to click. Then stop. The user clicks it, and \
    you get a new screenshot to give the next step. When the task is done, say so in one short \
    sentence and end with a line that is exactly
    DONE
    If the user says "do it for me", finish the remaining steps yourself.
    """

    static let acting = """
    You can work on the screen with computer_use, but only when the user asks you to do \
    something on it. Before your first screen action in a request, say in one short sentence \
    what you will do, end your answer with a line that is exactly
    ASK
    and stop. The screen stays locked until the user says yes; then do the work and say in \
    one short sentence what you did.
    """

    /// The user's answer to an ASK that is not a plain yes or no. The screen is open for this one
    /// request, and the agent decides from the words whether it may act.
    public static func replyToAsk(_ words: String) -> String {
        """
        The user answered your question about the screen action: "\(words)". \
        If these words tell you to go ahead with that action, do it now. \
        If they do not, do not touch the screen: answer them, and end with a line that is exactly
        ASK
        if you still need a yes.
        """
    }

    static let noHands = """
    You cannot click or type on this screen. Tell the user where to click instead, and point at it.
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
