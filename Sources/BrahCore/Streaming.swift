import Foundation

/// The text of one `data:` line of an OpenAI-style chat stream, or nil for any other line.
public enum ChatStream {
    public enum Line: Equatable {
        case text(String)
        /// A tool the agent started, as a short label ("Clicking Save").
        case step(String)
        case done
    }

    /// Reads a stream line by line. Hermes sends tool steps as a named event,
    /// `event: hermes.tool.progress`, before their `data:` line; other named events are skipped.
    public struct Parser {
        private var event: String?

        public init() {}

        public mutating func feed(_ line: String) -> Line? {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                return nil
            }
            guard line.hasPrefix("data:") else {
                if line.isEmpty { event = nil }
                return nil
            }
            // Each named event has one data line here, and some readers drop the blank line after it.
            defer { event = nil }
            switch event {
            case nil, "message":
                return ChatStream.parse(line)
            case "hermes.tool.progress":
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      json["status"] as? String == "running"
                else { return nil }
                let label = (json["label"] as? String ?? json["tool"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return label.isEmpty ? nil : .step(label)
            default:
                return nil
            }
        }
    }

    public static func parse(_ line: String) -> Line? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return .done
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty
        else { return nil }
        return .text(content)
    }
}

/// Decides which part of a growing answer may be spoken now. A POINT line is for the screen,
/// never for the voice, so a line is held back until it cannot be a POINT line.
public struct SpokenText {
    /// Text of the current line not yet given out.
    private var line = ""
    /// Nothing of the current line has been given out yet, so it can still be a POINT line.
    private var atLineStart = true

    public init() {}

    /// Text that can be spoken now.
    public mutating func feed(_ delta: String) -> String {
        var out = ""
        for character in delta {
            if character == "\n" {
                out += take(ended: true) + "\n"
            } else {
                line.append(character)
            }
        }
        return out + take(ended: false)
    }

    /// The rest, when the answer is complete.
    public mutating func finish() -> String {
        take(ended: true)
    }

    enum PointMatch { case yes, maybe, no }

    // "POINT" or "STEP", then x and y. What follows them is the label.
    private static let full = try! Regex(#"^(POINT|STEP|CIRCLE|BOX|UNDERLINE|ARROW|LINE)\s+-?[\d.]+,?\s+-?[\d.]+(\s|\]|$)"#)
    // A line that can still grow into one.
    private static let partial = try! Regex(#"^(POINT|STEP|CIRCLE|BOX|UNDERLINE|ARROW|LINE)(\s+(-?[\d.]*(,?(\s+(-?[\d.]*)?)?)?)?)?$"#)
    private static let keywords = ["POINT", "STEP", "CIRCLE", "BOX", "UNDERLINE", "ARROW", "LINE"]
    /// Lines that are one word for Brah: wait for a yes, or the guide is over.
    private static let words = ["ASK", "DONE"]

    /// Whether a line, from its start, is a POINT or STEP line, can still become one, or cannot.
    static func match(_ line: String) -> PointMatch {
        let start = line.drop(while: { $0 == " " || $0 == "[" || $0 == "`" }).uppercased()
        if start.firstMatch(of: full) != nil { return .yes }
        if keywords.contains(where: { $0.hasPrefix(start) }) || start.wholeMatch(of: partial) != nil { return .maybe }
        return .no
    }

    private mutating func take(ended: Bool) -> String {
        if atLineStart {
            let match = Self.match(line)
            if ended {
                let word = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]`")).uppercased()
                let out = match == .yes || Self.words.contains(word) ? "" : line
                line = ""
                return out
            }
            // "ASK" or "DONE" alone on a line is for Brah, not for the voice: hold it until the line ends.
            let start = line.trimmingCharacters(in: .whitespaces).uppercased()
            if Self.words.contains(where: { $0.hasPrefix(start) }) {
                return ""
            }
            if match != .no {
                return ""
            }
        }

        let out = line
        line = ""
        if ended {
            atLineStart = true
        } else if !out.isEmpty {
            atLineStart = false
        }
        return out
    }
}
