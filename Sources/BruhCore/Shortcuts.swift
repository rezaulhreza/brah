import Foundation

/// One global key combination, such as `ctrl+option+space`.
public struct Shortcut: Equatable, Sendable {
    /// A macOS virtual key code (the `kVK_` values of Carbon).
    public var keyCode: Int
    /// Carbon modifier flags: `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    public var modifiers: Int
    /// For people: "⌃⌥Space".
    public var display: String

    public static let command = 1 << 8
    public static let shift = 1 << 9
    public static let option = 1 << 11
    public static let control = 1 << 12

    public init(keyCode: Int, modifiers: Int, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    private static let modifierNames: [String: (flag: Int, symbol: String)] = [
        "ctrl": (control, "⌃"), "control": (control, "⌃"), "⌃": (control, "⌃"),
        "option": (option, "⌥"), "opt": (option, "⌥"), "alt": (option, "⌥"), "⌥": (option, "⌥"),
        "shift": (shift, "⇧"), "⇧": (shift, "⇧"),
        "cmd": (command, "⌘"), "command": (command, "⌘"), "⌘": (command, "⌘"),
    ]

    // ANSI layout key codes. They name the key's place, not its letter.
    private static let keys: [String: (code: Int, label: String)] = {
        var keys: [String: (Int, String)] = [
            "space": (49, "Space"), "return": (36, "Return"), "enter": (36, "Return"), "tab": (48, "Tab"),
            "escape": (53, "Esc"), "esc": (53, "Esc"), "delete": (51, "Delete"),
            ".": (47, "."), "period": (47, "."), ",": (43, ","), "comma": (43, ","), "/": (44, "/"), "slash": (44, "/"),
            ";": (41, ";"), "'": (39, "'"), "[": (33, "["), "]": (30, "]"), "-": (27, "-"), "=": (24, "="), "`": (50, "`"),
            "left": (123, "←"), "right": (124, "→"), "down": (125, "↓"), "up": (126, "↑"),
        ]
        let letters: [(String, Int)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (letter, code) in letters { keys[letter] = (code, letter.uppercased()) }
        let digits = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (digit, code) in digits.enumerated() { keys[String(digit)] = (code, String(digit)) }
        let functionKeys = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() { keys["f\(index + 1)"] = (code, "F\(index + 1)") }
        return keys
    }()

    /// `ctrl+option+space`, `cmd+shift+.`, `f5`. Nil for an unknown key, or for a plain key with
    /// no modifier, which would take that key from every app. Function keys alone are allowed.
    public static func parse(_ text: String) -> Shortcut? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // "ctrl++" means the "+" key, which has no ANSI code of its own here: refuse it.
        guard let keyName = parts.last, !keyName.isEmpty, let key = keys[keyName] else { return nil }

        var modifiers = 0
        for name in parts.dropLast() {
            guard let modifier = modifierNames[name] else { return nil }
            modifiers |= modifier.flag
        }
        guard modifiers != 0 || keyName.hasPrefix("f") && keyName.count > 1 else { return nil }

        // Apple's order: ⌃⌥⇧⌘.
        let symbols = [(control, "⌃"), (option, "⌥"), (shift, "⇧"), (command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        return Shortcut(keyCode: key.code, modifiers: modifiers, display: symbols + key.label)
    }
}

/// Bruh's global shortcuts. Each one can be changed in `~/.config/bruh/config.json`:
/// `{"shortcuts": {"talk": "ctrl+option+space", "stop": "ctrl+option+.", "mute": "ctrl+option+m", "hide": "ctrl+option+h"}}`
public struct Shortcuts: Equatable, Sendable {
    public var talk: Shortcut
    public var stop: Shortcut
    public var mute: Shortcut
    public var hide: Shortcut

    public static let defaults = Shortcuts(
        talk: Shortcut.parse("ctrl+option+space")!,
        stop: Shortcut.parse("ctrl+option+.")!,
        mute: Shortcut.parse("ctrl+option+m")!,
        hide: Shortcut.parse("ctrl+option+h")!
    )

    /// The shortcuts from the config file, with the default for each one that is missing or
    /// wrong, and a line for the user about each one that was wrong.
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (Shortcuts, [String]) {
        let section = Config.json(home: home)?["shortcuts"] as? [String: Any] ?? [:]
        return resolve(section.compactMapValues { $0 as? String })
    }

    static func resolve(_ texts: [String: String]) -> (Shortcuts, [String]) {
        var result = defaults
        var problems: [String] = []
        var custom: Set<String> = []
        let slots: [(String, WritableKeyPath<Shortcuts, Shortcut>)] = [("talk", \.talk), ("stop", \.stop), ("mute", \.mute), ("hide", \.hide)]
        let paths = Dictionary(uniqueKeysWithValues: slots)

        for (name, path) in slots {
            guard let text = texts[name] else { continue }
            guard let shortcut = Shortcut.parse(text) else {
                problems.append("Shortcut \"\(text)\" for \(name) is not valid. Using \(result[keyPath: path].display).")
                continue
            }
            result[keyPath: path] = shortcut
            custom.insert(name)
        }

        // Two actions on one key: a setting of the user goes back to its default (the later one
        // when both are). Each pass reverts one setting, so this ends.
        var clash = true
        while clash {
            clash = false
            var used: [String: String] = [:]
            for (name, path) in slots {
                let shortcut = result[keyPath: path]
                let key = "\(shortcut.keyCode)/\(shortcut.modifiers)"
                guard let other = used[key] else {
                    used[key] = name
                    continue
                }
                let revert = custom.contains(name) ? name : other
                let revertPath = paths[revert]!
                result[keyPath: revertPath] = defaults[keyPath: revertPath]
                custom.remove(revert)
                problems.append("\(shortcut.display) is set for both \(other) and \(name). Using \(defaults[keyPath: revertPath].display) for \(revert).")
                clash = true
                break
            }
        }
        for unknown in texts.keys.sorted() where !slots.contains(where: { $0.0 == unknown }) {
            problems.append("Unknown shortcut name \"\(unknown)\". The names are talk, stop, mute and hide.")
        }
        return (result, problems)
    }
}

/// `~/.config/bruh/config.json`.
public enum Config {
    public static func json(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: Any]? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".config/bruh/config.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
