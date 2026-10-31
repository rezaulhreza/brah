import Foundation

/// Reads and writes `~/.config/brah/config.json` for the Settings window. A write keeps every key
/// that the window does not manage.
public enum ConfigFile {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The file is there, but it is not a JSON object. A save would lose it.
        case notJSON
        /// The file could not be written. The text is from the system.
        case cannotWrite(String)

        public var description: String {
            switch self {
            case .notJSON: "~/.config/brah/config.json is not valid JSON. Correct it or remove it, then save again."
            case .cannotWrite(let reason): "Brah cannot write ~/.config/brah/config.json: \(reason)"
            }
        }
    }

    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/brah/config.json")
    }

    /// The whole file. Empty when there is no file.
    public static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url(home: home)) else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notJSON }
        return json
    }

    /// Writes the whole file, readable only by the user (mode 600). The new file replaces the old
    /// one in one step, so a crash never leaves half a file.
    public static func write(_ json: [String: Any], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        // A symbolic link (for example from a dotfiles folder) stays a link: write its target.
        let file = url(home: home).resolvingSymlinksInPath()
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }

        var data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)

        // The temporary file has mode 600 from its first byte, as the secrets of older setups can be in it.
        let temporary = folder.appendingPathComponent(".config.json.\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Failure.cannotWrite(String(cString: strerror(errno))) }

        let written = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return fsync(descriptor) == 0
        }
        let reason = String(cString: strerror(errno))
        close(descriptor)
        guard written, rename(temporary.path, file.path) == 0 else {
            let failure = written ? String(cString: strerror(errno)) : reason
            unlink(temporary.path)
            throw Failure.cannotWrite(failure)
        }
    }
}

/// Hands-free mode: Brah listens for "Hey Brah", and stops after a time with no talk.
/// `{"handsFree": {"enabled": true, "idleSeconds": 20}}` in `~/.config/brah/config.json`.
public struct HandsFreeSettings: Equatable, Sendable {
    public var enabled: Bool
    /// Seconds of quiet before Brah stops listening. Always in `idleRange`.
    public var idleSeconds: Int

    public static let idleRange = 10...120
    public static let defaultIdleSeconds = 20

    public init(enabled: Bool = false, idleSeconds: Int = defaultIdleSeconds) {
        self.enabled = enabled
        self.idleSeconds = min(max(idleSeconds, Self.idleRange.lowerBound), Self.idleRange.upperBound)
    }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> HandsFreeSettings {
        HandsFreeSettings(json: Config.json(home: home))
    }

    init(json: [String: Any]?) {
        let section = json?["handsFree"] as? [String: Any]
        let seconds = (section?["idleSeconds"] as? Double).map { Int($0.rounded()) }
        self.init(enabled: section?["enabled"] as? Bool ?? false, idleSeconds: seconds ?? Self.defaultIdleSeconds)
    }
}

/// The values of `~/.config/brah/config.json` that the Settings window changes. The secrets are
/// not here: they go to the Keychain (see `Secrets`).
public struct EditableSettings: Equatable, Sendable {
    /// Empty means the default address.
    public var hermesURL: String
    /// Empty means the default dashboard address.
    public var voiceURL: String
    public var voiceUsername: String
    public var shortcuts: Shortcuts
    public var handsFree: HandsFreeSettings

    public init(hermesURL: String = "", voiceURL: String = "", voiceUsername: String = "",
                shortcuts: Shortcuts = .defaults, handsFree: HandsFreeSettings = HandsFreeSettings()) {
        self.hermesURL = hermesURL
        self.voiceURL = voiceURL
        self.voiceUsername = voiceUsername
        self.shortcuts = shortcuts
        self.handsFree = handsFree
    }

    /// The values in a config file. A shortcut that is not valid shows as its default.
    public init(json: [String: Any]) {
        let hermes = json["hermes"] as? [String: Any]
        let voice = hermes?["voice"] as? [String: Any]
        self.init(hermesURL: hermes?["url"] as? String ?? "",
                  voiceURL: voice?["url"] as? String ?? "",
                  voiceUsername: voice?["username"] as? String ?? "",
                  shortcuts: Shortcuts.resolve(Shortcuts.section(json)).0,
                  handsFree: HandsFreeSettings(json: json))
    }

    /// The config file with these values in it. All other keys stay. An empty text removes its key.
    public func applied(to json: [String: Any]) -> [String: Any] {
        var json = json

        var hermes = json["hermes"] as? [String: Any] ?? [:]
        Self.put(hermesURL, "url", in: &hermes)
        var voice = hermes["voice"] as? [String: Any] ?? [:]
        Self.put(voiceURL, "url", in: &voice)
        Self.put(voiceUsername, "username", in: &voice)
        if voice.isEmpty { hermes.removeValue(forKey: "voice") } else { hermes["voice"] = voice }
        if hermes.isEmpty { json.removeValue(forKey: "hermes") } else { json["hermes"] = hermes }

        var section = json["shortcuts"] as? [String: Any] ?? [:]
        for (name, path) in Shortcuts.slots {
            section[name] = shortcuts[keyPath: path].configText
        }
        json["shortcuts"] = section

        var handsFreeSection = json["handsFree"] as? [String: Any] ?? [:]
        handsFreeSection["enabled"] = handsFree.enabled
        handsFreeSection["idleSeconds"] = handsFree.idleSeconds
        json["handsFree"] = handsFreeSection
        return json
    }

    private static func put(_ text: String, _ key: String, in object: inout [String: Any]) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { object.removeValue(forKey: key) } else { object[key] = text }
    }
}

/// How the agent answers: `{"responses": {"style": "short", "instructions": "Call me Rez."}}`.
public struct ResponseSettings: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable {
        case short, normal, detailed

        var instruction: String {
            switch self {
            case .short: "Answer in at most three short sentences."
            case .normal: "Answer in a short paragraph of at most six sentences."
            case .detailed: "Answer as fully as the question needs, in short sentences."
            }
        }
    }

    public var style: Style
    public var instructions: String

    public init(style: Style = .short, instructions: String = "") {
        self.style = style
        self.instructions = instructions
    }

    public init(json: [String: Any]) {
        let section = json["responses"] as? [String: Any]
        self.init(style: (section?["style"] as? String).flatMap(Style.init(rawValue:)) ?? .short,
                  instructions: section?["instructions"] as? String ?? "")
    }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ResponseSettings {
        ResponseSettings(json: Config.json(home: home) ?? [:])
    }

    public func applied(to json: [String: Any]) -> [String: Any] {
        var json = json
        json["responses"] = ["style": style.rawValue, "instructions": instructions.trimmingCharacters(in: .whitespacesAndNewlines)]
        return json
    }

    /// The user's own instructions, for the end of the brief.
    var custom: String {
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : "\n\nThe user's own instructions for every answer:\n\(text.prefix(2000))"
    }
}

/// `{"speech": {"macVoice": "com.apple.voice.premium.en-GB.Malcolm"}}`. Empty: the best installed voice.
public enum SpeechSettings {
    public static func macVoice(json: [String: Any]?) -> String {
        (json?["speech"] as? [String: Any])?["macVoice"] as? String ?? ""
    }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        macVoice(json: Config.json(home: home))
    }

    public static func applied(_ identifier: String, to json: [String: Any]) -> [String: Any] {
        var json = json
        var section = json["speech"] as? [String: Any] ?? [:]
        section["macVoice"] = identifier
        json["speech"] = section
        return json
    }
}
