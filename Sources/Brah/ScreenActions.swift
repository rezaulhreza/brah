import AppKit
import ApplicationServices
import BrahCore

/// Brah's own hands for an agent: clicks, typing, keys and scrolling on this Mac. Brah's cursor
/// flies to each click first, and a risky action waits for the user's yes.
final class ScreenActions: ScreenActing, @unchecked Sendable {
    enum Approval { case allow, always, deny }

    @MainActor var confirm: (String) async -> Approval = { _ in .deny }
    @MainActor var onStep: (String) -> Void = { _ in }
    @MainActor var pointAt: (Spot, Snapshot) -> Void = { _, _ in }
    @MainActor var passThrough: (Bool) -> Void = { _ in }
    @MainActor private var snapshot: Snapshot?
    @MainActor private var allowed: Set<String> = []
    @MainActor private var generation = 0

    /// A new request starts from the screenshot the agent got with the question.
    @MainActor func begin(with snapshot: Snapshot) {
        self.snapshot = snapshot
        generation += 1
    }

    /// Stop: actions that are still on their way do nothing.
    @MainActor func cancel() {
        generation += 1
    }

    func run(_ name: String, input: Data) async -> ToolResult {
        let json = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        let request = Request(name: name, x: (json["x"] as? NSNumber)?.doubleValue, y: (json["y"] as? NSNumber)?.doubleValue,
                              text: json["text"] as? String ?? json["keys"] as? String ?? "",
                              label: json["label"] as? String ?? "", risky: json["risky"] as? Bool ?? false,
                              double: json["double"] as? Bool ?? false, right: json["right"] as? Bool ?? false,
                              direction: json["direction"] as? String ?? "down", amount: (json["amount"] as? NSNumber)?.intValue ?? 3)
        return await perform(request)
    }

    private struct Request: Sendable {
        var name: String
        var x, y: Double?
        var text, label: String
        var risky, double, right: Bool
        var direction: String
        var amount: Int
    }

    @MainActor private func perform(_ request: Request) async -> ToolResult {
        let started = generation
        if request.name == "screenshot" { return await look("The screen now.") }
        guard AXIsProcessTrusted() else {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return ToolResult(text: "Brah has no Accessibility permission, so it cannot click or type. Tell the user to allow Brah in "
                              + "System Settings, Privacy & Security, Accessibility, then ask again.", isError: true)
        }
        guard let snapshot else { return await look("Look at the screen first.") }

        let label = request.label.isEmpty ? (request.name == "type" ? "type \"\(request.text.prefix(40))\"" : request.name) : request.label
        let rule = "\(snapshot.appName ?? "")|\(Phrases.normalise(label))"
        if ScreenTool.isRisky(label: label, flagged: request.risky), !allowed.contains(rule) {
            onStep("Waiting for your yes")
            switch await confirm(label) {
            case .deny: return ToolResult(text: "The user said no to \"\(label)\". Do not do it; ask what they want instead.", isError: true)
            case .always: allowed.insert(rule)
            case .allow: break
            }
        }
        guard started == generation else { return ToolResult(text: "The user stopped Brah.", isError: true) }
        onStep(label)

        switch request.name {
        case "click":
            guard let x = request.x, let y = request.y else { return ToolResult(text: "click needs x and y.", isError: true) }
            pointAt(Spot(x: x, y: y, label: label), snapshot)
            try? await Task.sleep(for: .milliseconds(450))
            guard started == generation else { return ToolResult(text: "The user stopped Brah.", isError: true) }
            passThrough(true)
            // The window server takes a moment to let clicks through the bubble.
            try? await Task.sleep(for: .milliseconds(150))
            Self.click(at: Self.global(x, y, on: snapshot), right: request.right, double: request.double)
            try? await Task.sleep(for: .milliseconds(80))
            passThrough(false)
        case "type":
            Self.type(request.text)
        case "key":
            guard let key = Shortcut.keyPress(request.text) else { return ToolResult(text: "Unknown key \"\(request.text)\".", isError: true) }
            Self.press(key.keyCode, modifiers: key.modifiers)
        case "scroll":
            let point = Self.global(request.x ?? snapshot.imageSize.width / 2, request.y ?? snapshot.imageSize.height / 2, on: snapshot)
            Self.scroll(at: point, direction: request.direction, amount: max(1, min(10, request.amount)))
        default:
            return ToolResult(text: "Unknown tool \(request.name).", isError: true)
        }
        try? await Task.sleep(for: .milliseconds(600))
        return await look("Done: \(label).")
    }

    @MainActor private func look(_ text: String) async -> ToolResult {
        do {
            let snapshot = try await Capture.snapshot()
            self.snapshot = snapshot
            return ToolResult(text: "\(text) Screenshot \(Int(snapshot.imageSize.width))x\(Int(snapshot.imageSize.height)) pixels.",
                              jpeg: snapshot.jpeg)
        } catch {
            return ToolResult(text: "\(text) No new screenshot: \(error.localizedDescription)", isError: true)
        }
    }

    /// A screenshot pixel in Quartz global coordinates: points, origin top-left of the main display.
    static func global(_ x: Double, _ y: Double, on snapshot: Snapshot) -> CGPoint {
        let main = NSScreen.screens.first?.frame.height ?? snapshot.screenFrame.maxY
        let appKit = CGPoint(x: snapshot.screenFrame.minX + x / snapshot.scale, y: snapshot.screenFrame.maxY - y / snapshot.scale)
        return CGPoint(x: appKit.x, y: main - appKit.y)
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    static func click(at point: CGPoint, right: Bool, double: Bool) {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        for count in 1...(double ? 2 : 1) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    static func type(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.offset > 0 { press(36, modifiers: 0) }
            var rest = Substring(line.element)
            while !rest.isEmpty {
                let chunk = Array(rest.prefix(16).utf16)
                rest = rest.dropFirst(16)
                for keyDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event?.post(tap: .cghidEventTap)
                }
            }
        }
    }

    static func press(_ keyCode: Int, modifiers: Int) {
        var flags = CGEventFlags()
        if modifiers & Shortcut.command != 0 { flags.insert(.maskCommand) }
        if modifiers & Shortcut.shift != 0 { flags.insert(.maskShift) }
        if modifiers & Shortcut.option != 0 { flags.insert(.maskAlternate) }
        if modifiers & Shortcut.control != 0 { flags.insert(.maskControl) }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    static func scroll(at point: CGPoint, direction: String, amount: Int) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        let lines = Int32(amount * 3)
        let (vertical, horizontal): (Int32, Int32) = switch direction {
        case "up": (lines, 0)
        case "left": (0, lines)
        case "right": (0, -lines)
        default: (-lines, 0)
        }
        CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }
}
