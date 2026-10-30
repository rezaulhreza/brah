import Foundation

/// What the listening side reports in a hands-free conversation.
public enum TurnEvent: Equatable, Sendable {
    /// The user started to talk.
    case started
    /// The words of the current turn so far.
    case update(String)
    /// The user finished a turn.
    case ended(String)
}

/// The words Brah listens for. Every match is on the whole utterance, so "stop" inside a longer
/// sentence is a question, not a command.
public enum Phrases {
    private static let stop: Set<String> = [
        "stop", "stop listening", "goodbye", "good bye", "bye", "bye bye", "bye bruh", "bye brah", "bye bra", "bye bro",
        "thats all", "that is all", "end voice chat", "go to sleep", "never mind", "nevermind",
    ]
    private static let approve: Set<String> = [
        "yes", "yeah", "yep", "yes please", "approve", "approved", "go ahead", "yes go ahead", "do it", "yes do it",
        "go on", "ok", "okay", "ok go ahead", "okay go ahead", "sure", "allow", "allow it",
    ]
    private static let deny = try! Regex(#"^(no|nope|no thanks|deny|denied|dont|do not|cancel|stop|reject|wait)\b"#)
    private static let wake = try! Regex(#"\b(hey|hi|ok|okay|yo|a)\s+(bruh|bro|brah|bra|brew|bruv|broh)\b"#)

    /// Lower case, letters, digits and single spaces only.
    public static func normalise(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    public static func isStop(_ text: String) -> Bool {
        stop.contains(normalise(text))
    }

    /// True for a yes, false for a no, nil when the words are neither: then they are a new request.
    public static func approval(_ text: String) -> Bool? {
        let words = normalise(text)
        if approve.contains(words) { return true }
        if words.firstMatch(of: deny) != nil { return false }
        return nil
    }

    /// "Hey Brah", also as speech recognition tends to spell it ("hey bra", "hey bro", "a bruh").
    public static func hasWakeWord(_ text: String) -> Bool {
        normalise(text).firstMatch(of: wake) != nil
    }
}

/// Speakers next to a microphone: the user's words and Brah's own voice arrive together. Echo
/// cancellation removes most of the voice; this catches what is left, by the words. A transcript
/// that is mostly words Brah said in the last 20 seconds is the voice, not the user.
public struct EchoGuard: Sendable {
    private var said: [(at: Date, words: Set<String>)] = []
    public static let memory: TimeInterval = 20
    public static let share = 0.7

    public init() {}

    public mutating func spoke(_ text: String, at now: Date = Date()) {
        said = said.filter { now.timeIntervalSince($0.at) < Self.memory }
        said.append((now, Set(Phrases.normalise(text).split(separator: " ").map(String.init))))
    }

    public func isEcho(_ transcript: String, at now: Date = Date()) -> Bool {
        let words = Phrases.normalise(transcript).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        let recent = said.filter { now.timeIntervalSince($0.at) < Self.memory }.reduce(into: Set<String>()) { $0.formUnion($1.words) }
        let echoed = words.filter { recent.contains($0) }.count
        return Double(echoed) / Double(words.count) >= Self.share
    }
}
