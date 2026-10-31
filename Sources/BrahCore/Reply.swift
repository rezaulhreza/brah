import Foundation

/// A place on the screenshot that the agent wants to show the user.
public struct Spot: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var label: String

    public init(x: Double, y: Double, label: String) {
        self.x = x
        self.y = y
        self.label = label
    }
}

/// A mark Brah draws on the screen, as a person would on a whiteboard. Points are screenshot pixels.
public struct Mark: Equatable, Sendable {
    public enum Shape: String, CaseIterable, Sendable {
        /// x y w h: an oval around the box.
        case circle
        /// x y w h
        case box
        /// x1 y x2
        case underline
        /// x1 y1 x2 y2, from the tail to the tip.
        case arrow
        /// x1 y1 x2 y2 …: a free-hand line through the points.
        case line
    }

    public var shape: Shape
    public var numbers: [Double]
    public var label: String

    public init(shape: Shape, numbers: [Double], label: String = "") {
        self.shape = shape
        self.numbers = numbers
        self.label = label
    }

    static func parse(_ line: Substring) -> Mark? {
        let parts = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]`"))
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first, let shape = Shape(rawValue: first.lowercased()) else { return nil }
        var numbers: [Double] = []
        var rest = parts.dropFirst()
        while let next = rest.first, let number = Double(next.trimmingCharacters(in: CharacterSet(charactersIn: ","))) {
            numbers.append(number)
            rest = rest.dropFirst()
        }
        switch shape {
        case .circle, .box, .arrow: guard numbers.count == 4 else { return nil }
        case .underline: guard numbers.count == 3 else { return nil }
        case .line: guard numbers.count >= 4, numbers.count.isMultiple(of: 2) else { return nil }
        }
        let label = rest.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return Mark(shape: shape, numbers: numbers, label: label)
    }
}

/// What the agent said, split into the words to show and speak, and the places it means.
public struct Reply: Equatable, Sendable {
    public var text: String
    public var point: Spot?
    /// The agent wants to act on the screen and waits for the user's yes.
    public var needsApproval: Bool
    /// The next step of a "show me" guide: the place the user should click.
    public var step: Spot?
    /// The guided task is complete.
    public var done: Bool
    public var marks: [Mark] = []

    public init(text: String, point: Spot?, needsApproval: Bool = false, step: Spot? = nil, done: Bool = false) {
        self.text = text
        self.point = point
        self.needsApproval = needsApproval
        self.step = step
        self.done = done
    }

    /// The agent ends its answer with `POINT x y label` to point, `STEP x y label` for the next
    /// step of a guide, `ASK` to wait for a yes, or `DONE` when a guide is over. The last line of
    /// each kind wins, and all of them are removed from the text.
    public static func parse(_ raw: String) -> Reply {
        var reply = Reply(text: "", point: nil)
        var kept: [Substring] = []

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let word = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]`")).uppercased()
            if let found = placeLine(line, keyword: "POINT") {
                reply.point = found
            } else if let found = placeLine(line, keyword: "STEP") {
                reply.step = found
            } else if let mark = Mark.parse(line) {
                if reply.marks.count < 6 { reply.marks.append(mark) }
            } else if word == "ASK" {
                reply.needsApproval = true
            } else if word == "DONE" {
                reply.done = true
            } else {
                kept.append(line)
            }
        }

        reply.text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return reply
    }

    private static func placeLine(_ line: Substring, keyword: String) -> Spot? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]`"))
        let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)

        guard parts.count >= 3, parts[0].uppercased() == keyword,
              let x = Double(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ","))),
              let y = Double(parts[2])
        else { return nil }

        let label = parts.count == 4 ? String(parts[3]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) : ""
        return Spot(x: x, y: y, label: label)
    }
}
