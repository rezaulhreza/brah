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

/// What the agent said, split into the words to show and speak, and an optional place to point at.
public struct Reply: Equatable, Sendable {
    public var text: String
    public var point: Spot?

    public init(text: String, point: Spot?) {
        self.text = text
        self.point = point
    }

    /// The agent ends its answer with `POINT x y label` when it wants to point. The last such line
    /// wins, and every such line is removed from the text.
    public static func parse(_ raw: String) -> Reply {
        var point: Spot?
        var kept: [Substring] = []

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if let found = pointLine(line) {
                point = found
            } else {
                kept.append(line)
            }
        }

        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Reply(text: text, point: point)
    }

    private static func pointLine(_ line: Substring) -> Spot? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]`"))
        let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)

        guard parts.count >= 3, parts[0].uppercased() == "POINT",
              let x = Double(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ","))),
              let y = Double(parts[2])
        else { return nil }

        let label = parts.count == 4 ? String(parts[3]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) : ""
        return Spot(x: x, y: y, label: label)
    }
}
