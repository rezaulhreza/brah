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
    }

    func testAnswerText() {
        let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8)
        XCTAssertEqual(HermesConnection.answerText(data), "Hi")
        XCTAssertNil(HermesConnection.answerText(Data("{}".utf8)))
    }
}
