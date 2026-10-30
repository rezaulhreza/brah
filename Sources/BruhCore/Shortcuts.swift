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

    /// One entry per key: the name that `configText` writes, the ANSI layout key code and the
    /// label for people. The codes name the key's place, not its letter.
    static let keyList: [(name: String, code: Int, label: String)] = {
        var list: [(name: String, code: Int, label: String)] = [
            ("space", 49, "Space"), ("return", 36, "Return"), ("tab", 48, "Tab"), ("esc", 53, "Esc"), ("delete", 51, "Delete"),
            (".", 47, "."), (",", 43, ","), ("/", 44, "/"), (";", 41, ";"), ("'", 39, "'"), ("[", 33, "["), ("]", 30, "]"),
            ("-", 27, "-"), ("=", 24, "="), ("`", 50, "`"),
            ("left", 123, "←"), ("right", 124, "→"), ("down", 125, "↓"), ("up", 126, "↑"),
        ]
        let letters: [(String, Int)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (letter, code) in letters { list.append((letter, code, letter.uppercased())) }
        let digits = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (digit, code) in digits.enumerated() { list.append((String(digit), code, String(digit))) }
        let functionKeys = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() { list.append(("f\(index + 1)", code, "F\(index + 1)")) }
        return list
    }()

    /// Every name that `parse` accepts for a key: the names of `keyList` and a few other spellings.
    static let keys: [String: (code: Int, label: String)] = {
        var keys = Dictionary(uniqueKeysWithValues: keyList.map { ($0.name, (code: $0.code, label: $0.label)) })
        let aliases = ["enter": "return", "escape": "esc", "period": ".", "comma": ",", "slash": "/"]
        for (alias, name) in aliases { keys[alias] = keys[name] }
        return keys
    }()

    private static let byCode = Dictionary(uniqueKeysWithValues: keyList.map { ($0.code, $0) })
    private static let functionKeyCodes = Set(keyList.filter { $0.name.hasPrefix("f") && $0.name.count > 1 }.map(\.code))

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
        return from(keyCode: key.code, modifiers: modifiers)
    }

    /// The shortcut for a key that a person pressed, for a key recorder. `modifiers` are the
    /// Carbon flags; other bits are ignored. Nil for a key that `parse` does not know, and for a
    /// key with no modifier, except a function key.
    public static func from(keyCode: Int, modifiers: Int) -> Shortcut? {
        guard let key = byCode[keyCode] else { return nil }
        let modifiers = modifiers & (control | option | shift | command)
        guard modifiers != 0 || functionKeyCodes.contains(keyCode) else { return nil }

        // Apple's order: ⌃⌥⇧⌘.
        let symbols = [(control, "⌃"), (option, "⌥"), (shift, "⇧"), (command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        return Shortcut(keyCode: keyCode, modifiers: modifiers, display: symbols + key.label)
    }

    /// True when the key is one that a shortcut can use, with or without a modifier.
    public static func knows(keyCode: Int) -> Bool {
        byCode[keyCode] != nil
    }

    /// The form that `parse` reads back and that the config file keeps: `ctrl+option+space`.
    public var configText: String {
        let names = [(Self.control, "ctrl"), (Self.option, "option"), (Self.shift, "shift"), (Self.command, "cmd")]
            .filter { modifiers & $0.0 != 0 }.map(\.1)
        return (names + [Self.byCode[keyCode]?.name ?? "?"]).joined(separator: "+")
    }

    /// True when two shortcuts are the same keys, whatever their labels.
    public func sameKeys(as other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// Bruh's global shortcuts. Each one can be changed in the Settings window or in
/// `~/.config/bruh/config.json`:
/// `{"shortcuts": {"talk": "ctrl+option+space", "stop": "ctrl+option+.", "mute": "ctrl+option+m",
/// "hide": "ctrl+option+h", "handsFree": "ctrl+option+j"}}`
public struct Shortcuts: Equatable, Sendable {
    public var talk: Shortcut
    public var stop: Shortcut
    public var mute: Shortcut
    public var hide: Shortcut
    /// Turns the "Hey Bruh" wake word on and off.
    public var handsFree: Shortcut

    public init(talk: Shortcut, stop: Shortcut, mute: Shortcut, hide: Shortcut, handsFree: Shortcut) {
        self.talk = talk
        self.stop = stop
        self.mute = mute
        self.hide = hide
        self.handsFree = handsFree
    }

    public static let defaults = Shortcuts(
        talk: Shortcut.parse("ctrl+option+space")!,
        stop: Shortcut.parse("ctrl+option+.")!,
        mute: Shortcut.parse("ctrl+option+m")!,
        hide: Shortcut.parse("ctrl+option+h")!,
        handsFree: Shortcut.parse("ctrl+option+j")!
    )

    /// The name of each shortcut in the config file.
    public static var names: [String] { slots.map(\.0) }

    static let slots: [(String, WritableKeyPath<Shortcuts, Shortcut>)] = [
        ("talk", \.talk), ("stop", \.stop), ("mute", \.mute), ("hide", \.hide), ("handsFree", \.handsFree),
    ]

    /// The shortcut with the config name `talk`, `stop`, `mute`, `hide` or `handsFree`.
    public subscript(name: String) -> Shortcut? {
        get { Self.slots.first { $0.0 == name }.map { self[keyPath: $0.1] } }
        set {
            guard let newValue, let path = Self.slots.first(where: { $0.0 == name })?.1 else { return }
            self[keyPath: path] = newValue
        }
    }

    /// The shortcuts from the config file, with the default for each one that is missing or
    /// wrong, and a line for the user about each one that was wrong.
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (Shortcuts, [String]) {
        resolve(section(Config.json(home: home)))
    }

    /// The `shortcuts` object of a config file, as text.
    static func section(_ json: [String: Any]?) -> [String: String] {
        let section = json?["shortcuts"] as? [String: Any] ?? [:]
        return section.compactMapValues { $0 as? String }
    }

    static func resolve(_ texts: [String: String]) -> (Shortcuts, [String]) {
        var result = defaults
        var problems: [String] = []
        var custom: Set<String> = []
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
            problems.append("Unknown shortcut name \"\(unknown)\". The names are talk, stop, mute, hide and handsFree.")
        }
        return (result, problems)
    }
}

/// `~/.config/bruh/config.json`.
public enum Config {
    public static func json(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: Any]? {
        guard let data = try? Data(contentsOf: ConfigFile.url(home: home)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
