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
    /// The Hermes dashboard: the voice, its plugins and the screen lock.
    private var dashboard: HermesVoice?
    /// The screen as the user saw it when they asked. The question waits for it.
    private var capture: Task<Snapshot, Error>?
    private var pressedAt: Date?
    /// Opens the live words socket while the user talks. Nil result: no live route.
    private var listening: Task<WordStream?, Never>?
    /// The agent's work on the current question. Nil when the agent is idle.
    private var work: Task<Void, Never>?
    private var workID = UUID()
    /// The answer as far as it has arrived, without POINT and ASK lines.
    private var shown = ""
    private var shownFilter = SpokenText()
    private var shortcuts = Shortcuts.defaults
    private var voiceReady: Task<Void, Never>?

    // Acting on the screen
    private var canHoldScreen = false
    private var holdingScreen = false
    private var awaitingApproval = false

    // Hands-free
    private let wake = WakeListener()
    private var conversation: Conversation?
    private var idleSeconds: TimeInterval = 20

    // Menu
    private var speakItem: NSMenuItem?
    private var voiceItem: NSMenuItem?
    private var handsFreeItem: NSMenuItem?

    private var speaks: Bool {
        get { UserDefaults.standard.object(forKey: "speak") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speak") }
    }

    private let settingsWindow = SettingsWindow()
    /// Screen actions only make sense for an agent on this Mac: a Hermes on a server would click
    /// on the server.
    private var agentIsLocal = true

    /// Saved in the config file with the other settings.
    private var handsFreeOn: Bool {
        get { HandsFreeSettings.load().enabled }
        set {
            guard var json = try? ConfigFile.read() else { return }
            var settings = EditableSettings(json: json)
            settings.handsFree.enabled = newValue
            json = settings.applied(to: json)
            do {
                try ConfigFile.write(json)
            } catch {
                log("could not save hands-free: \(error)")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadAgent()
        settingsWindow.onSave = { [weak self] in self?.reloadSettings() }
        settingsWindow.onOpen = { [weak self] open in
            // The key recorder must get every key, Bruh's own shortcuts too.
            open ? Hotkeys.unregisterAll() : self?.registerHotkeys()
        }
        voice.log = { [weak self] line in self?.log(line) }
        AudioIO.shared.log = { [weak self] line in DispatchQueue.main.async { self?.log(line) } }
        connectVoice()

        let model = bubble.model
        model.muted = !speaks
        model.onSubmit = { [weak self] question in self?.submit(question) }
        model.onStop = { [weak self] in self?.stop() }
        model.onMute = { [weak self] in self?.toggleMute() }
        model.onClose = { [weak self] in self?.hide() }
        model.onListen = { [weak self] in
            guard let self else { return }
            if self.conversation != nil {
                self.endConversation()
                self.bubble.model.phase = .answer("Stopped listening.")
            } else {
                self.beginConversation(keepBubble: true)
            }
        }
        model.onApprove = { [weak self] yes in yes ? self?.approve() : self?.deny() }

        loadShortcuts()
        registerHotkeys()
        idleSeconds = TimeInterval(HandsFreeSettings.load().idleSeconds)

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        Task { _ = await Recorder.allowed() }
        buildMenu()
        if handsFreeOn {
            startWake()
        }
        runTestArguments()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the agent's screen tools locked after Bruh quits.
        guard holdingScreen, let dashboard else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await dashboard.holdScreen(false)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    private func loadAgent() {
        let settings = HermesSettings.load()
        agent = settings.map { HermesConnection(settings: $0) }
        agentIsLocal = settings?.isLocal ?? true
        bubble.model.agentName = agent?.name ?? "Hermes"
        log("agent: \(agent?.name ?? "none")\(agentIsLocal ? "" : " on a server (no screen actions)")")
    }

    private func loadShortcuts() {
        let problems: [String]
        (shortcuts, problems) = Shortcuts.load()
        problems.forEach { log($0) }
    }

    private func registerHotkeys() {
        Hotkeys.unregisterAll()
        Hotkeys.register(shortcuts.talk, onRelease: { [weak self] in self?.released() }) { [weak self] in self?.pressed() }
        Hotkeys.register(shortcuts.stop) { [weak self] in self?.stop() }
        Hotkeys.register(shortcuts.hide) { [weak self] in self?.hide() }
        Hotkeys.register(shortcuts.mute) { [weak self] in self?.toggleMute() }
        Hotkeys.register(shortcuts.handsFree) { [weak self] in self?.toggleHandsFree() }
    }

    /// After a save in the Settings window: everything again, from the saved settings.
    private func reloadSettings() {
        log("settings saved")
        hide()
        loadAgent()
        loadShortcuts()
        registerHotkeys()
        let handsFree = HandsFreeSettings.load()
        idleSeconds = TimeInterval(handsFree.idleSeconds)
        wake.stop()
        connectVoice()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        buildMenu()
        if handsFree.enabled {
            startWake()
        }
    }

    /// Use the Hermes voice when the backend lets Bruh in. Until then, and when it does not, the
    /// Mac speaks.
    private func connectVoice() {
        let hermes = HermesVoice(settings: HermesVoiceSettings.load())
        voiceReady = Task {
            do {
                try await hermes.connect()
                dashboard = hermes
                voice = Voice(hermes: hermes, deepgram: await hermes.deepgramLive())
                canHoldScreen = agentIsLocal ? await hermes.canHoldScreen() : false
            } catch {
                log("Hermes voice not available: \(error.localizedDescription)")
            }
            voice.log = { [weak self] line in self?.log(line) }
            voiceItem?.title = "Voice: \(voice.route)"
            log("voice: \(voice.route), screen lock: \(canHoldScreen ? "yes" : "no")")
        }
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("bruh: \(line)\n".utf8))
    }

    // MARK: Hotkey

    /// Capture the screen at once, so the agent sees it as the user saw it, and start listening.
    /// A press while Bruh is open closes it.
    private func pressed() {
        if bubble.isVisible && pressedAt == nil && conversation == nil {
            hide()
            return
        }

        endConversation()
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
        Task {
            do {
                let live = await listening?.value
                let words = try await voice.words(live: live, wav: recording.wav)
                guard bubble.model.phase == .transcribing else { return }
                log("heard \(String(format: "%.1f", recording.seconds)) s: \(words.debugDescription)")
                guard !words.isEmpty else {
                    bubble.model.phase = .failed("I did not hear any words. Hold \(shortcuts.talk.display) while you talk.")
                    return
                }
                bubble.model.question = words
                if awaitingApproval, let yes = Phrases.approval(words) {
                    yes ? approve() : deny()
                } else {
                    submit(words)
                }
            } catch {
                bubble.model.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Asking

    /// Send a question with the latest capture. While the agent works on a request the user has
    /// not approved, its screen tools are locked; `approved` unlocks them for this request.
    private func submit(_ question: String, approved: Bool = false) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let capture else { return }
        guard let agent else {
            bubble.model.phase = .failed("No Hermes key found. Set BRUH_HERMES_KEY, or write ~/.config/bruh/config.json.")
            return
        }

        work?.cancel()
        voice.stop()
        awaitingApproval = false
        bubble.model.phase = .thinking
        bubble.model.step = nil
        shown = ""
        shownFilter = SpokenText()
        if speaks {
            voice.beginReply()
        }
        let id = UUID()
        workID = id
        work = Task {
            defer { if workID == id { work = nil } }
            await lockScreen(!approved)
            do {
                let snapshot = try await capture.value
                let reply = try await agent.ask(question, snapshot: snapshot) { [weak self] event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.arrived(event, for: id) } }
                }
                guard !Task.isCancelled, workID == id else { return }
                log("reply=\(reply.text.debugDescription) point=\(String(describing: reply.point)) ask=\(reply.needsApproval)")
                if reply.needsApproval {
                    awaitingApproval = true
                    bubble.model.phase = .approval(reply.text)
                } else {
                    bubble.model.phase = .answer(reply.text)
                    await lockScreen(false)
                }
                if speaks {
                    voice.endReply(reply.text)
                }
                if let spot = reply.point {
                    pointer.show(at: snapshot.viewPoint(spot), label: spot.label, on: snapshot.screenFrame)
                }
            } catch {
                guard !Task.isCancelled, workID == id else { return }
                log("ask failed: \(error.localizedDescription)")
                bubble.model.phase = .failed(error.localizedDescription)
                await lockScreen(false)
            }
        }
    }

    /// A piece of the answer, or a step the agent takes.
    private func arrived(_ event: AgentEvent, for id: UUID) {
        // A stopped answer stays stopped, even when pieces were still on their way.
        guard workID == id, work != nil else { return }
        switch event {
        case .step(let label):
            log("step: \(label)")
            bubble.model.step = label
        case .text(let piece):
            guard bubble.model.phase == .thinking || !shown.isEmpty else { return }
            shown += shownFilter.feed(piece)
            if !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bubble.model.phase = .answer(shown)
            }
            if speaks {
                voice.replyPiece(piece)
            }
        }
    }

    // MARK: Acting on the screen

    /// Lock or unlock the agent's screen tools through the screen-remote plugin, when the host
    /// has it. Without it, the agent's own promise to ask first is the only gate.
    private func lockScreen(_ locked: Bool) async {
        guard canHoldScreen, let dashboard, locked != holdingScreen else { return }
        do {
            try await dashboard.holdScreen(locked, reason: "Bruh: the user has not said yes to screen actions yet")
            holdingScreen = locked
        } catch {
            log("screen lock failed: \(error.localizedDescription)")
        }
    }

    private func approve() {
        guard awaitingApproval else { return }
        log("approved")
        capture = Task { try await Capture.snapshot() }
        bubble.model.question = "Yes, go ahead."
        submit("Yes, go ahead.", approved: true)
    }

    private func deny() {
        guard awaitingApproval else { return }
        log("not approved")
        awaitingApproval = false
        bubble.model.phase = .answer("OK, I will leave the screen alone.")
        Task { await lockScreen(false) }
        capture = Task { try await Capture.snapshot() }
        submit("No, do not do that.")
    }

    // MARK: Stop, hide

    private func cancelListening() {
        let listening = listening
        self.listening = nil
        Task { await listening?.value?.cancel() }
    }

    /// Stop listening, stop the agent and stop talking. The bubble stays, so the user sees that
    /// it stopped. A hands-free conversation goes on listening.
    func stop() {
        if pressedAt != nil {
            pressedAt = nil
            _ = recorder.stop()
        }
        cancelListening()
        let wasWorking = work != nil
        work?.cancel()
        work = nil
        workID = UUID()
        voice.stop()
        awaitingApproval = false
        if bubble.model.isBusy {
            bubble.model.phase = conversation == nil ? .failed("Stopped.") : .listening
        }
        guard wasWorking || holdingScreen else { return }
        // Take the screen back at once; the agent stops when its stream closes.
        Task {
            await lockScreen(true)
            try? await Task.sleep(for: .seconds(3))
            if work == nil && !awaitingApproval {
                await lockScreen(false)
            }
        }
    }

    /// Stop, end a conversation, and take every Bruh window off the screen.
    func hide() {
        endConversation()
        stop()
        bubble.hide()
        pointer.hide()
    }

    private func escape() {
        if conversation != nil {
            hide()
        } else if bubble.model.isBusy {
            stop()
        } else {
            hide()
        }
    }

    // MARK: Hands-free

    private func setHandsFree(_ on: Bool) {
        handsFreeOn = on
        handsFreeItem?.state = on ? .on : .off
        if on {
            startWake()
        } else {
            endConversation()
            wake.stop()
        }
        log(on ? "hands-free on" : "hands-free off")
    }

    private func startWake() {
        guard handsFreeOn, conversation == nil else { return }
        Task {
            if let problem = await wake.start(onWake: { [weak self] in self?.woke() }) {
                log("wake word: \(problem)")
                bubble.show(near: NSEvent.mouseLocation, phase: .failed(problem), typing: false)
                setHandsFree(false)
            } else {
                log("listening for \"Hey Bruh\"")
            }
        }
    }

    private func woke() {
        guard conversation == nil, pressedAt == nil else { return }
        log("wake word heard")
        NSSound(named: "Tink")?.play()
        beginConversation()
    }

    /// The microphone stays open: each finished turn is a question, until "bye" or silence.
    private func beginConversation(keepBubble: Bool = false) {
        wake.stop()
        stop()
        pointer.hide()
        let session = Conversation()
        conversation = session
        capture = Task { try await Capture.snapshot() }
        if keepBubble && bubble.isVisible {
            bubble.model.phase = .listening
            bubble.model.question = ""
        } else {
            bubble.show(near: NSEvent.mouseLocation, phase: .listening, typing: false)
        }
        bubble.model.handsFree = true

        Task {
            let turns: LiveTurns?
            if let flux = await voice.turns(onTurn: { [weak self] event in self?.turn(event) }) {
                turns = FluxTurns(flux)
            } else if case .success(let recognizer) = await SpeechAccess.onDeviceRecognizer() {
                turns = MacTurns(recognizer: recognizer) { [weak self] event in self?.turn(event) }
            } else {
                turns = nil
            }
            guard conversation === session else {
                turns?.close()
                return
            }
            guard let turns else {
                bubble.model.phase = .failed("Bruh has no way to listen for a conversation here.")
                endConversation()
                return
            }
            do {
                try session.attach(turns)
                log("conversation started (\(turns is FluxTurns ? "Flux" : "on-device"))")
            } catch {
                bubble.model.phase = .failed("The microphone did not start: \(error.localizedDescription)")
                endConversation()
            }
        }
        session.lastActivity = Date()
        session.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func turn(_ event: TurnEvent) {
        guard let session = conversation else { return }
        switch event {
        case .started:
            break
        case .update(let words):
            guard !words.isEmpty else { return }
            if voice.isSpeaking {
                // Talking over the voice stops it, unless the words are the voice itself.
                guard !voice.isEcho(words) else { return }
                log("barge-in")
                voice.stop()
            }
            session.lastActivity = Date()
            if work == nil && !awaitingApproval {
                bubble.model.phase = .listening
            }
            if bubble.model.phase == .listening {
                bubble.model.question = words
            }
        case .ended(let words):
            let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return }
            if voice.isEcho(words) {
                log("echo ignored: \(words.debugDescription)")
                return
            }
            session.lastActivity = Date()
            log("turn: \(words.debugDescription)")
            if Phrases.isStop(words) {
                endConversation(sayBye: true)
                return
            }
            if awaitingApproval, let yes = Phrases.approval(words) {
                yes ? approve() : deny()
                return
            }
            capture = Task { try await Capture.snapshot() }
            bubble.model.question = words
            submit(words)
        }
    }

    /// The idle clock runs only while nobody talks: not while the agent works or the voice speaks.
    private func tick() {
        guard let session = conversation else { return }
        if work != nil || voice.isSpeaking || awaitingApproval {
            session.lastActivity = Date()
        } else if Date().timeIntervalSince(session.lastActivity) > idleSeconds {
            log("conversation idle")
            endConversation()
        }
    }

    private func endConversation(sayBye: Bool = false) {
        guard let session = conversation else { return }
        conversation = nil
        session.close()
        bubble.model.handsFree = false
        log("conversation ended")
        if sayBye {
            stop()
            if speaks { voice.say("Bye.") }
        }
        if bubble.model.phase == .listening || sayBye {
            bubble.hide()
        }
        // Give the microphone a moment before the wake word listens again.
        Task {
            try? await Task.sleep(for: .seconds(sayBye ? 1.5 : 0.5))
            startWake()
        }
    }

    // MARK: Tests

    /// `--ask "question"` asks without the hotkey. `--talk 4` listens for four seconds, as a hold
    /// of the hotkey would. `--converse` starts a hands-free conversation as "Hey Bruh" would.
    private func runTestArguments() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--ask") || arguments.contains("--talk") || arguments.contains("--converse") else { return }
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
        } else if arguments.contains("--converse") {
            beginConversation()
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
        let handsFree = entry("Listen for \u{201C}Hey Bruh\u{201D}", shortcut: nil, action: #selector(toggleHandsFree))
        handsFree.state = handsFreeOn ? .on : .off
        menu.addItem(handsFree)
        handsFreeItem = handsFree
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
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
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
        endConversation()
        stop()
        pointer.hide()
        capture = Task { try await Capture.snapshot() }
        bubble.show(near: NSEvent.mouseLocation, phase: .asking, typing: true)
    }

    @objc private func menuStop() { stop() }
    @objc private func menuHide() { hide() }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func toggleHandsFree() {
        setHandsFree(!handsFreeOn)
    }

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
        bubble.model.muted = !speaks
        log(speaks ? "voice on" : "voice muted")
    }

    @objc private func newConversation() {
        Task { await agent?.reset() }
    }
}
