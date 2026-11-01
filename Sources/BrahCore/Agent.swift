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
    /// `.tools` is Brah's own screen tools; `.acts` is the agent's own (Hermes `computer_use`);
    /// `.remote` is an agent on another computer, whose screen tools would act there.
    public enum Hands { case acts, tools, remote, none }

    /// The system prompt that rides with every question. `responses` adds the user's own style.
    public static func system(for snapshot: Snapshot, hands: Hands = .acts, responses: ResponseSettings = ResponseSettings()) -> String {
        let width = Int(snapshot.imageSize.width)
        let height = Int(snapshot.imageSize.height)
        var place = ""
        if let app = snapshot.appName {
            place = " The front app is \(app)"
            if let title = snapshot.windowTitle, !title.isEmpty {
                place += ", window \"\(title)\""
            }
            place += "."
        }
        let hand = switch hands {
        case .acts: acting
        case .tools: tools
        case .remote: notActing
        case .none: noHands
        }

        return """
        You are Brah, a mate who sits next to the user's mouse cursor on their Mac. They ask out loud \
        about whatever is on their screen, and you answer like a friend looking over their shoulder: \
        direct, warm, never stiff.

        # What you see
        The image is a screenshot of their display, \(width)x\(height) pixels, origin top-left. A red \
        ring marks their cursor at (\(Int(snapshot.cursor.x)), \(Int(snapshot.cursor.y))).\(place) All \
        coordinates you give are in these screenshot pixels.

        # How you answer
        \(responses.style.instruction) Your words are spoken aloud: no markdown, no lists, no code \
        blocks, no coordinates in the words.

        # How you show
        Show, do not only tell. Whenever your answer is about something on the screen, mark it, without \
        being asked, like a teacher at a whiteboard. Put each mark on its own line after your words:
        POINT 412 230 Save button
        CIRCLE 380 210 140 40 Total
        BOX 40 300 600 180 This table
        HIGHLIGHT 120 490 240 24 The answer
        UNDERLINE 120 512 360 The date
        ARROW 700 100 520 210 Click here
        NUMBER 300 150 1 First
        TICK 820 330 Correct
        CROSS 600 330 90 24 Not this one
        SPOTLIGHT 40 300 600 180
        LINE 100 400 180 380 260 420
        POINT flies Brah's cursor to one place. CIRCLE, BOX, HIGHLIGHT, CROSS and SPOTLIGHT take the \
        top-left corner, width and height of the thing. ARROW goes from the tail to the tip. NUMBER \
        puts a numbered badge at a point. LINE is free-hand through its points. Pick what a person \
        would draw: highlight a value they asked for, circle a control, number the parts of an \
        explanation, tick or cross when comparing, spotlight when one area matters. Use up to eight \
        marks, with short labels. LINE is your free-hand pen: give it three or more points and \
        Brah draws one smooth curve through them. Use it when no other mark fits, for example to \
        outline an odd shape, trace a path from one thing to another, draw a curly arrow, or \
        underline with a wave. Put a point at each bend, and repeat the first point at the end to \
        close a shape. Pick the simplest mark that does the job.

        # Guiding
        \(guiding)

        # Acting
        \(hand)
        """ + responses.custom
    }

    static let guiding = """
    When the user asks how to do something that takes more than one click, show them one step \
    at a time. Say the step in one short sentence and end with one line exactly like
    STEP 412 230 Export
    on the place to click. Then stop. The user clicks it, and you get a new screenshot to give \
    the next step. When the task is done, say so in one short sentence and end with a line that is exactly
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

    static let tools = """
    When the user asks you to do something on the screen, or says "do it for me", do it with the \
    Brah tools: screenshot, click, type, key and scroll. Do not ask first: Brah asks the user \
    itself before anything risky. Give every click and key a short label, and set risky to true \
    for anything that sends, pays, deletes, publishes, submits or signs in. Each action returns a \
    new screenshot: check it before the next step, and try another way when something did not \
    work. When you are done, say in one short sentence what you did, and mark the result. For a \
    question, only answer and mark: do not touch the screen.
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
