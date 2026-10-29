import CoreGraphics
import Foundation
import XCTest
@testable import BruhCore

final class ReplyTests: XCTestCase {
    func testTextWithoutPoint() {
        let reply = Reply.parse("  Click File, then Export.  ")
        XCTAssertEqual(reply, Reply(text: "Click File, then Export.", point: nil))
    }

    func testPointLineIsTakenOutOfTheText() {
        let reply = Reply.parse("It is the blue button.\nPOINT 412 230 Save button")
        XCTAssertEqual(reply.text, "It is the blue button.")
        XCTAssertEqual(reply.point, Spot(x: 412, y: 230, label: "Save button"))
    }

    func testPointToleratesCommaBracketsAndQuotes() {
        let reply = Reply.parse("There.\n[POINT 10.5, 20 \"Menu\"]")
        XCTAssertEqual(reply.point, Spot(x: 10.5, y: 20, label: "Menu"))
        XCTAssertEqual(reply.text, "There.")
    }

    func testLastPointWins() {
        let reply = Reply.parse("POINT 1 2 a\nText\npoint 3 4 b")
        XCTAssertEqual(reply.point, Spot(x: 3, y: 4, label: "b"))
        XCTAssertEqual(reply.text, "Text")
    }

    func testPointWithoutLabel() {
        XCTAssertEqual(Reply.parse("POINT 5 6").point, Spot(x: 5, y: 6, label: ""))
    }

    func testSentenceThatStartsWithPointIsKept() {
        let reply = Reply.parse("Point your mouse at the top bar.")
        XCTAssertNil(reply.point)
        XCTAssertEqual(reply.text, "Point your mouse at the top bar.")
    }
}

final class SnapshotTests: XCTestCase {
    private func snapshot(scale: Double) -> Snapshot {
        Snapshot(jpeg: Data(), imageSize: CGSize(width: 1512 * scale, height: 982 * scale),
                 screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: scale,
                 cursor: .zero, appName: nil, windowTitle: nil)
    }

    func testMouseBecomesTopLeftImagePixels() {
        let frame = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let point = Snapshot.imagePoint(mouse: CGPoint(x: 1612, y: 780), frame: frame, scale: 0.5)
        XCTAssertEqual(point, CGPoint(x: 50, y: 50))
    }

    func testImagePixelBecomesViewPoint() {
        XCTAssertEqual(snapshot(scale: 0.5).viewPoint(Spot(x: 100, y: 40, label: "")), CGPoint(x: 200, y: 80))
    }

    func testViewPointIsClampedToTheScreen() {
        XCTAssertEqual(snapshot(scale: 1).viewPoint(Spot(x: -5, y: 5000, label: "")), CGPoint(x: 0, y: 982))
    }
}

final class HermesTests: XCTestCase {
    func testEnvValueStripsQuotes() {
        let env = "OTHER=1\nAPI_SERVER_KEY=\"abc123\"\n"
        XCTAssertEqual(HermesSettings.envValue(env, name: "API_SERVER_KEY"), "abc123")
        XCTAssertNil(HermesSettings.envValue(env, name: "MISSING"))
    }

    func testEnvironmentWinsOverFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".hermes"), withIntermediateDirectories: true)
        try "API_SERVER_KEY=from-file".write(to: home.appendingPathComponent(".hermes/.env"), atomically: true, encoding: .utf8)

        let fromFile = HermesSettings.load(environment: [:], home: home)
        XCTAssertEqual(fromFile, HermesSettings(url: HermesSettings.defaultURL, key: "from-file"))

        let fromEnv = HermesSettings.load(environment: ["BRUH_HERMES_KEY": "env", "BRUH_HERMES_URL": "http://h:1"], home: home)
        XCTAssertEqual(fromEnv, HermesSettings(url: URL(string: "http://h:1")!, key: "env"))
    }

    func testNoKeyMeansNotConfigured() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(HermesSettings.load(environment: [:], home: home))
    }

    func testRequestCarriesImageSessionAndKey() throws {
        let snap = Snapshot(jpeg: Data([1, 2, 3]), imageSize: CGSize(width: 10, height: 10),
                            screenFrame: .zero, scale: 1, cursor: CGPoint(x: 3, y: 4), appName: "Finder", windowTitle: "Docs")
        let request = HermesConnection.request(question: "What is this?", snapshot: snap,
                                               settings: HermesSettings(url: URL(string: "http://h:1")!, key: "k"), sessionID: "s1")

        XCTAssertEqual(request.url?.absoluteString, "http://h:1/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Id"), "s1")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertTrue((messages[0]["content"] as? String ?? "").contains("(3, 4)"))
        XCTAssertTrue((messages[0]["content"] as? String ?? "").contains("window \"Docs\""))
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let image = try XCTUnwrap((parts[1]["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertEqual(image, "data:image/jpeg;base64,AQID")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }
}

final class StreamingTests: XCTestCase {
    func testChatStreamLines() {
        XCTAssertEqual(ChatStream.parse(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#), .text("Hi"))
        XCTAssertEqual(ChatStream.parse("data: [DONE]"), .done)
        XCTAssertNil(ChatStream.parse(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertNil(ChatStream.parse(": keep-alive"))
        XCTAssertNil(ChatStream.parse("event: hermes.tool.progress"))
    }

    private func speak(_ pieces: [String]) -> String {
        var filter = SpokenText()
        return pieces.map { filter.feed($0) }.joined() + filter.finish()
    }

    func testPlainTextPassesAtOnce() {
        var filter = SpokenText()
        XCTAssertEqual(filter.feed("It is the "), "It is the ")
        XCTAssertEqual(filter.feed("blue button."), "blue button.")
    }

    func testPointLineIsNeverSpoken() {
        XCTAssertEqual(speak(["Click Save.\nPO", "INT 412 ", "230 Save button"]), "Click Save.\n")
        XCTAssertEqual(speak(["Here.\n[POINT 1 2 x]\n"]), "Here.\n\n")
    }

    func testWordPointInsideASentenceIsSpoken() {
        XCTAssertEqual(speak(["It is the ", "Point", " and click tool."]), "It is the Point and click tool.")
    }

    func testLineThatStartsLikePointIsSpokenWhenItIsNot() {
        XCTAssertEqual(speak(["Po", "int at the top bar."]), "Point at the top bar.")
        XCTAssertEqual(speak(["Pol", "ish it."]), "Polish it.")
    }
}

final class VoiceTests: XCTestCase {
    func testSoundFromDataURL() {
        XCTAssertEqual(Sound(dataURL: "data:audio/mpeg;base64,AQID"), Sound(data: Data([1, 2, 3]), mimeType: "audio/mpeg"))
        XCTAssertNil(Sound(dataURL: "audio/mpeg;base64,AQID"))
    }

    func testWAVHeader() {
        let wav = WAV.file(samples: [1, -1], sampleRate: 16_000)
        XCTAssertEqual(wav.count, 48)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 16_000)
    }

    func testVoiceSettingsDefaultToTheLocalDashboard() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(HermesVoiceSettings.load(environment: [:], home: home), HermesVoiceSettings(url: HermesVoiceSettings.defaultURL))

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/bruh"), withIntermediateDirectories: true)
        try #"{"hermes": {"voice": {"url": "http://h:2", "username": "u", "password": "p"}}}"#
            .write(to: home.appendingPathComponent(".config/bruh/config.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HermesVoiceSettings.load(environment: [:], home: home),
                       HermesVoiceSettings(url: URL(string: "http://h:2")!, username: "u", password: "p"))
    }

    func testPageToken() {
        XCTAssertEqual(HermesVoiceSettings.pageToken(#"<script>window.__HERMES_SESSION_TOKEN__="abc-1_2";</script>"#), "abc-1_2")
        XCTAssertEqual(HermesVoiceSettings.pageToken(#"window.__HERMES_SESSION_TOKEN__ = "x";"#), "x")
        XCTAssertNil(HermesVoiceSettings.pageToken("<html>Sign in</html>"))
    }
}

final class ShortcutTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Shortcut.parse("ctrl+option+space"), Shortcut(keyCode: 49, modifiers: Shortcut.control | Shortcut.option, display: "⌃⌥Space"))
        XCTAssertEqual(Shortcut.parse(" Cmd + Shift + . ")?.display, "⇧⌘.")
        XCTAssertEqual(Shortcut.parse("alt+k")?.keyCode, 40)
        XCTAssertEqual(Shortcut.parse("f5"), Shortcut(keyCode: 96, modifiers: 0, display: "F5"))
    }

    func testRefusesKeysThatWouldStealTyping() {
        XCTAssertNil(Shortcut.parse("space"))
        XCTAssertNil(Shortcut.parse("m"))
        XCTAssertNil(Shortcut.parse("ctrl+banana"))
        XCTAssertNil(Shortcut.parse("hyper+space"))
        XCTAssertNil(Shortcut.parse("ctrl+"))
    }

    func testResolveKeepsDefaultsAndReportsProblems() {
        let (shortcuts, problems) = Shortcuts.resolve(["talk": "cmd+shift+space", "mute": "nope", "volume": "ctrl+v"])
        XCTAssertEqual(shortcuts.talk.display, "⇧⌘Space")
        XCTAssertEqual(shortcuts.mute, Shortcuts.defaults.mute)
        XCTAssertEqual(shortcuts.stop, Shortcuts.defaults.stop)
        XCTAssertEqual(problems.count, 2)
    }

    func testDuplicateGoesBackToDefault() {
        let (shortcuts, problems) = Shortcuts.resolve(["talk": "ctrl+option+h"])
        XCTAssertEqual(shortcuts, Shortcuts.defaults)
        XCTAssertTrue(problems.first?.contains("both talk and hide") == true)
    }

    func testSwapIsAllowed() {
        let (shortcuts, problems) = Shortcuts.resolve(["talk": "ctrl+option+.", "stop": "ctrl+option+space"])
        XCTAssertEqual(shortcuts.talk.display, "⌃⌥.")
        XCTAssertEqual(shortcuts.stop.display, "⌃⌥Space")
        XCTAssertEqual(problems, [])
    }
}

final class DeepgramLiveTests: XCTestCase {
    private let status: [String: Any] = [
        "available": true, "voice": "aura-2-thalia-en", "listen_model": "flux-general-en", "eot_threshold": 0.7,
        "eot_timeout_ms": 3000, "speed": 1.1, "keyterms": ["Hermes", "Bruh"], "mip_opt_out": true,
    ]

    func testSettingsNeedAWorkingPlugin() {
        XCTAssertNotNil(DeepgramLiveSettings(status: status))
        var off = status
        off["available"] = false
        XCTAssertNil(DeepgramLiveSettings(status: off))
    }

    func testSpeakURLUsesTheChosenVoice() throws {
        let url = try XCTUnwrap(DeepgramLiveSettings(status: status)).speakURL().absoluteString
        XCTAssertTrue(url.hasPrefix("wss://api.deepgram.com/v1/speak?"))
        XCTAssertTrue(url.contains("model=aura-2-thalia-en"))
        XCTAssertTrue(url.contains("encoding=linear16"))
        XCTAssertTrue(url.contains("sample_rate=24000"))
        XCTAssertTrue(url.contains("speed=1.1"))
    }

    func testListenURLUsesFluxAndKeyterms() throws {
        let url = try XCTUnwrap(DeepgramLiveSettings(status: status)).listenURL(sampleRate: 16_000).absoluteString
        XCTAssertTrue(url.hasPrefix("wss://api.deepgram.com/v2/listen?"))
        XCTAssertTrue(url.contains("model=flux-general-en"))
        XCTAssertTrue(url.contains("sample_rate=16000"))
        XCTAssertTrue(url.contains("keyterm=Hermes&keyterm=Bruh"))
    }

    func testSentenceSplit() {
        XCTAssertTrue(DeepgramSpeech.sentences("Hello there. How") == ("Hello there.", " How"))
        XCTAssertTrue(DeepgramSpeech.sentences("It costs 3.5 pounds") == ("", "It costs 3.5 pounds"))
        XCTAssertTrue(DeepgramSpeech.sentences("Done!\nNext") == ("Done!\n", "Next"))
        XCTAssertTrue(DeepgramSpeech.sentences("Wait.") == ("", "Wait."))
    }
}

final class ShortcutSettingsTests: XCTestCase {
    func testHandsFreeSlot() {
        XCTAssertEqual(Shortcuts.defaults.handsFree.display, "⌃⌥J")
        XCTAssertEqual(Shortcuts.resolve(["handsFree": "cmd+shift+j"]).0.handsFree.display, "⇧⌘J")

        let (shortcuts, problems) = Shortcuts.resolve(["handsFree": "ctrl+option+space"])
        XCTAssertEqual(shortcuts, Shortcuts.defaults)
        XCTAssertTrue(problems.first?.contains("both talk and handsFree") == true)

        let unknown = Shortcuts.resolve(["wake": "ctrl+option+w"]).1
        XCTAssertEqual(unknown, ["Unknown shortcut name \"wake\". The names are talk, stop, mute, hide and handsFree."])
    }

    func testConfigTextRoundTripsForEveryKey() {
        XCTAssertEqual(Shortcuts.defaults.talk.configText, "ctrl+option+space")
        XCTAssertEqual(Shortcut.parse("cmd+alt+shift+ctrl+escape")?.configText, "ctrl+option+shift+cmd+esc")
        for (name, _) in Shortcut.keys {
            for modifiers in ["ctrl", "option+shift", "ctrl+option+shift+cmd"] {
                let shortcut = Shortcut.parse("\(modifiers)+\(name)")
                XCTAssertNotNil(shortcut, name)
                XCTAssertEqual(shortcut.flatMap { Shortcut.parse($0.configText) }, shortcut, name)
            }
        }
        XCTAssertEqual(Shortcut.parse("f12")?.configText, "f12")
    }

    func testFromKeyCode() {
        let control = Shortcut.control, option = Shortcut.option
        XCTAssertEqual(Shortcut.from(keyCode: 49, modifiers: control | option), Shortcut.parse("ctrl+option+space"))
        XCTAssertEqual(Shortcut.from(keyCode: 96, modifiers: 0), Shortcut.parse("f5"))
        // Caps Lock (1 << 10) and other bits do not count.
        XCTAssertEqual(Shortcut.from(keyCode: 46, modifiers: Shortcut.command | 1 << 10), Shortcut.parse("cmd+m"))
        XCTAssertNil(Shortcut.from(keyCode: 46, modifiers: 0))
        XCTAssertNil(Shortcut.from(keyCode: 46, modifiers: 1 << 10))
        XCTAssertNil(Shortcut.from(keyCode: 200, modifiers: control))
        for key in Shortcut.keyList {
            XCTAssertEqual(Shortcut.from(keyCode: key.code, modifiers: control), Shortcut.parse("ctrl+\(key.name)"), key.name)
        }
    }

    func testShortcutsByName() {
        var shortcuts = Shortcuts.defaults
        XCTAssertEqual(Shortcuts.names, ["talk", "stop", "mute", "hide", "handsFree"])
        XCTAssertEqual(shortcuts["hide"], Shortcuts.defaults.hide)
        XCTAssertNil(shortcuts["wake"])
        shortcuts["handsFree"] = Shortcut.parse("f6")
        XCTAssertEqual(shortcuts.handsFree.display, "F6")
    }
}
