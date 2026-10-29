import AppKit
import BruhCore
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A press shorter than this is a tap: Bruh opens a text field. A longer one is talk.
    private static let tapSeconds = 0.35

    private var statusItem: NSStatusItem?
    private lazy var bubble = Bubble(onEscape: { [weak self] in self?.escape() })
    private let pointer = Pointer()
    private let recorder = Recorder()
    private var voice = Voice(hermes: nil)
    private var agent: AgentConnection?
    /// The screen as the user saw it when they pressed the hotkey. The question waits for it.
    private var capture: Task<Snapshot, Error>?
    private var pressedAt: Date?
    /// Opens the live words socket while the user talks. Nil result: no live route.
    private var listening: Task<WordStream?, Never>?
    private var work: Task<Void, Never>?
    /// The answer as far as it has arrived, without POINT lines.
    private var shown = ""
    private var shownFilter = SpokenText()
    private var shortcuts = Shortcuts.defaults
    private var voiceReady: Task<Void, Never>?
    private var speakItem: NSMenuItem?
    private var voiceItem: NSMenuItem?

    private var speaks: Bool {
        get { UserDefaults.standard.object(forKey: "speak") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speak") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        agent = HermesSettings.load().map { HermesConnection(settings: $0) }
        voice.log = { [weak self] line in self?.log(line) }
        connectVoice()
        log("agent: \(agent?.name ?? "none")")
        bubble.model.agentName = agent?.name ?? "Hermes"
        bubble.model.onSubmit = { [weak self] question in self?.submit(question) }

        let problems: [String]
        (shortcuts, problems) = Shortcuts.load()
        problems.forEach { log($0) }
        Hotkeys.register(shortcuts.talk, onRelease: { [weak self] in self?.released() }) { [weak self] in self?.pressed() }
        Hotkeys.register(shortcuts.stop) { [weak self] in self?.stop() }
        Hotkeys.register(shortcuts.hide) { [weak self] in self?.hide() }
        Hotkeys.register(shortcuts.mute) { [weak self] in self?.toggleMute() }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        Task { _ = await Recorder.allowed() }
        buildMenu()
        runTestArguments()
    }

    /// Use the Hermes voice when the backend lets Bruh in. Until then, and when it does not, the
    /// Mac speaks.
    private func connectVoice() {
        let hermes = HermesVoice(settings: HermesVoiceSettings.load())
        voiceReady = Task {
            do {
                try await hermes.connect()
                voice = Voice(hermes: hermes, deepgram: await hermes.deepgramLive())
            } catch {
                log("Hermes voice not available: \(error.localizedDescription)")
            }
            voice.log = { [weak self] line in self?.log(line) }
            voiceItem?.title = "Voice: \(voice.route)"
            log("voice: \(voice.route)")
        }
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("bruh: \(line)\n".utf8))
    }

    // MARK: Hotkey

    /// Capture the screen at once, so the agent sees it as the user saw it, and start listening.
    /// A press while Bruh is open closes it.
    private func pressed() {
        if bubble.isVisible && pressedAt == nil {
            hide()
            return
        }

        stop()
        pointer.hide()
        pressedAt = Date()
        let mouse = NSEvent.mouseLocation
        capture = Task { try await Capture.snapshot() }

        do {
            try recorder.start()
            bubble.show(near: mouse, phase: .listening, typing: false)
            listening = Task {
                await voice.listen(to: recorder) { [weak self] words in
                    guard let self, [.listening, .transcribing].contains(self.bubble.model.phase) else { return }
                    self.bubble.model.question = words
                }
            }
        } catch {
            log("microphone failed: \(error.localizedDescription)")
            pressedAt = nil
            bubble.show(near: mouse, phase: .asking, typing: true)
        }
    }

    private func released() {
        guard let pressedAt else { return }
        self.pressedAt = nil
        let recording = recorder.stop()

        if Date().timeIntervalSince(pressedAt) < Self.tapSeconds {
            cancelListening()
            bubble.show(near: NSEvent.mouseLocation, phase: .asking, typing: true)
            return
        }

        bubble.model.phase = .transcribing
        let listening = listening
        self.listening = nil
        work = Task {
            do {
                let live = await listening?.value
                let words = try await voice.words(live: live, wav: recording.wav)
                guard !Task.isCancelled else { return }
                log("heard \(String(format: "%.1f", recording.seconds)) s: \(words.debugDescription)")
                guard !words.isEmpty else {
                    bubble.model.phase = .failed("I did not hear any words. Hold \(shortcuts.talk.display) while you talk.")
                    return
                }
                bubble.model.question = words
                submit(words)
            } catch {
                guard !Task.isCancelled else { return }
                bubble.model.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Actions

    private func submit(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let capture else { return }
        guard let agent else {
            bubble.model.phase = .failed("No Hermes key found. Set BRUH_HERMES_KEY, or write ~/.config/bruh/config.json.")
            return
        }

        bubble.model.phase = .thinking
        shown = ""
        shownFilter = SpokenText()
        if speaks {
            voice.beginReply()
        }
        work = Task {
            do {
                let snapshot = try await capture.value
                let reply = try await agent.ask(question, snapshot: snapshot) { [weak self] piece in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.arrived(piece) } }
                }
                guard !Task.isCancelled else { return }
                log("reply=\(reply.text.debugDescription) point=\(String(describing: reply.point))")
                bubble.model.phase = .answer(reply.text)
                if speaks {
                    voice.endReply(reply.text)
                }
                if let spot = reply.point {
                    pointer.show(at: snapshot.viewPoint(spot), label: spot.label, on: snapshot.screenFrame)
                }
            } catch {
                guard !Task.isCancelled else { return }
                log("ask failed: \(error.localizedDescription)")
                bubble.model.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// A piece of the answer: show it, and say it while the rest arrives.
    private func arrived(_ piece: String) {
        // A stopped answer stays stopped, even when pieces were still on their way.
        guard work != nil, bubble.model.phase == .thinking || !shown.isEmpty else { return }
        shown += shownFilter.feed(piece)
        if !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bubble.model.phase = .answer(shown)
        }
        if speaks {
            voice.replyPiece(piece)
        }
    }

    private func cancelListening() {
        let listening = listening
        self.listening = nil
        Task { await listening?.value?.cancel() }
    }

    /// Stop listening, stop waiting for the agent and stop talking. The bubble stays, so the user
    /// sees that it stopped.
    func stop() {
        if pressedAt != nil {
            pressedAt = nil
            _ = recorder.stop()
        }
        cancelListening()
        work?.cancel()
        work = nil
        voice.stop()
        if [.listening, .transcribing, .thinking].contains(bubble.model.phase) {
            bubble.model.phase = .failed("Stopped.")
        }
    }

    /// Stop, and take every Bruh window off the screen.
    func hide() {
        stop()
        bubble.hide()
        pointer.hide()
    }

    private func escape() {
        if [.listening, .transcribing, .thinking].contains(bubble.model.phase) {
            stop()
        } else {
            hide()
        }
    }

    // MARK: Tests

    /// `--ask "question"` asks without the hotkey. `--talk 4` listens for four seconds, as a hold
    /// of the hotkey would. Both are for tests and scripts.
    private func runTestArguments() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--ask") || arguments.contains("--talk") else { return }
        Task {
            await voiceReady?.value
            runTest(arguments)
        }
    }

    private func runTest(_ arguments: [String]) {
        if let index = arguments.firstIndex(of: "--ask"), index + 1 < arguments.count {
            let question = arguments[index + 1]
            capture = Task { try await Capture.snapshot() }
            bubble.show(near: NSEvent.mouseLocation, phase: .asking, typing: false)
            bubble.model.question = question
            submit(question)
        } else if let index = arguments.firstIndex(of: "--talk"), index + 1 < arguments.count,
                  let seconds = Double(arguments[index + 1]) {
            Task {
                pressed()
                log("listening for \(seconds) s")
                try? await Task.sleep(for: .seconds(seconds))
                released()
            }
        }
    }

    // MARK: Menu bar

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = Bundle.main.image(forResource: "MenuIcon")
            ?? NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Bruh")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 18, height: 18)
        icon?.accessibilityDescription = "Bruh"
        item.button?.image = icon

        let menu = NSMenu()
        menu.addItem(entry("Type a question", shortcut: nil, action: #selector(menuType)))
        menu.addItem(entry("Stop", shortcut: shortcuts.stop, action: #selector(menuStop)))
        menu.addItem(entry("Hide", shortcut: shortcuts.hide, action: #selector(menuHide)))
        menu.addItem(.separator())
        let speak = entry("Speak replies", shortcut: shortcuts.mute, action: #selector(toggleSpeak))
        speak.state = speaks ? .on : .off
        menu.addItem(speak)
        speakItem = speak
        menu.addItem(entry("New conversation", shortcut: nil, action: #selector(newConversation)))
        menu.addItem(.separator())
        let agentLine = NSMenuItem(title: agent == nil ? "Hermes: no key found" : "Connected to Hermes", action: nil, keyEquivalent: "")
        agentLine.isEnabled = false
        menu.addItem(agentLine)
        let voiceLine = NSMenuItem(title: "Voice: \(voice.route)", action: nil, keyEquivalent: "")
        voiceLine.isEnabled = false
        menu.addItem(voiceLine)
        voiceItem = voiceLine
        let hint = NSMenuItem(title: "Hold \(shortcuts.talk.display) to talk, tap to type", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Bruh", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    /// A menu item that shows its global shortcut on the right, as macOS menus do.
    private func entry(_ title: String, shortcut: Shortcut?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut.map(Self.keyEquivalent) ?? "")
        item.target = self
        if let shortcut {
            var mask: NSEvent.ModifierFlags = []
            if shortcut.modifiers & Shortcut.control != 0 { mask.insert(.control) }
            if shortcut.modifiers & Shortcut.option != 0 { mask.insert(.option) }
            if shortcut.modifiers & Shortcut.shift != 0 { mask.insert(.shift) }
            if shortcut.modifiers & Shortcut.command != 0 { mask.insert(.command) }
            item.keyEquivalentModifierMask = mask
        }
        return item
    }

    private static func keyEquivalent(_ shortcut: Shortcut) -> String {
        let label = String(shortcut.display.drop(while: { "⌃⌥⇧⌘".contains($0) }))
        let special: [String: Int] = ["←": NSLeftArrowFunctionKey, "→": NSRightArrowFunctionKey, "↓": NSDownArrowFunctionKey,
                                      "↑": NSUpArrowFunctionKey]
        switch label {
        case "Space": return " "
        case "Return": return "\r"
        case "Tab": return "\t"
        case "Esc": return "\u{1b}"
        case "Delete": return "\u{8}"
        default:
            if let code = special[label] { return String(UnicodeScalar(UInt16(code)).map(Character.init) ?? " ") }
            if label.hasPrefix("F"), let number = Int(label.dropFirst()) {
                return String(UnicodeScalar(UInt16(NSF1FunctionKey + number - 1)).map(Character.init) ?? " ")
            }
            return label.lowercased()
        }
    }

    @objc private func menuType() {
        stop()
        pointer.hide()
        capture = Task { try await Capture.snapshot() }
        bubble.show(near: NSEvent.mouseLocation, phase: .asking, typing: true)
    }

    @objc private func menuStop() { stop() }
    @objc private func menuHide() { hide() }

    @objc private func toggleSpeak(_ sender: NSMenuItem) {
        toggleMute()
    }

    /// Mute stops the voice at once. The answer still shows in the bubble.
    private func toggleMute() {
        speaks.toggle()
        if !speaks {
            voice.stop()
        }
        speakItem?.state = speaks ? .on : .off
        log(speaks ? "voice on" : "voice muted")
    }

    @objc private func newConversation() {
        Task { await agent?.reset() }
    }
}
