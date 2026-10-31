import AppKit
import ApplicationServices
import BrahCore
import Carbon.HIToolbox
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A press shorter than this is a tap: Brah opens a text field. A longer one is talk.
    private static let tapSeconds = 0.35

    private var statusItem: NSStatusItem?
    lazy var bubble = Bubble(onEscape: { [weak self] in self?.escape() })
    let cursor = BrahCursor()
    let marks = ScreenMarks()
    private let actions = ScreenActions()
    private var toolServer: ToolServer?
    private var tools: ToolServerAddress?
    /// A risky screen action waits here for the user's answer.
    private var pendingAction: CheckedContinuation<ScreenActions.Approval, Never>?
    private var touring = false
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
    private var effortItems: [NSMenuItem] = []

    private var speaks: Bool {
        get { UserDefaults.standard.object(forKey: "speak") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speak") }
    }

    let settingsWindow = SettingsWindow()
    /// The fake app behind the bubble in demo mode.
    var demoStage: NSPanel?
    /// Watches clicks in other apps while a "show me" guide waits for the user.
    private var clickWatch: Any?
    /// Where the current step is, in AppKit screen coordinates.
    private var guideTarget: CGPoint?
    private var pointerHide: DispatchWorkItem?
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
        // Demo mode only draws: no permission prompts, no Hermes, no hotkeys, no microphone.
        if let index = CommandLine.arguments.firstIndex(of: "--demo") {
            runDemo(index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "")
            return
        }
        startTools()
        loadAgent()
        settingsWindow.onSave = { [weak self] in self?.reloadSettings() }
        settingsWindow.onOpen = { [weak self] open in
            // The key recorder must get every key, Brah's own shortcuts too.
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
        model.onApprove = { [weak self] yes in
            guard let self, !self.answerAction(yes ? .allow : .deny) else { return }
            yes ? self.approve() : self.deny()
        }
        model.onAlwaysAllow = { [weak self] in self?.answerAction(.always) }
        model.onDoIt = { [weak self] in self?.doItForMe() }

        loadShortcuts()
        registerHotkeys()
        idleSeconds = TimeInterval(HandsFreeSettings.load().idleSeconds)

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        Task {
            let microphone = await Recorder.allowed()
            let speech = SFSpeechRecognizer.authorizationStatus()
            log("permissions: microphone \(microphone ? "allowed" : "NOT allowed"), speech recognition \(speech == .authorized ? "allowed" : "NOT allowed (\(speech.rawValue))")")
        }
        buildMenu()
        buildMainMenu()
        if handsFreeOn {
            startWake()
        }
        if agent == nil, !CommandLine.arguments.contains("--ask") {
            settingsWindow.show()
        }
        runTestArguments()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the agent's screen tools locked after Brah quits.
        guard holdingScreen, let dashboard else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await dashboard.holdScreen(false)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    private func loadAgent() {
        let providers = ProviderSettings.load()
        let environment = ProcessInfo.processInfo.environment
        let responses = ResponseSettings.load()
        switch providers.active {
        case .hermes:
            agent = HermesSettings.load().map { HermesConnection(settings: $0, responses: responses) }
        case .claude:
            agent = ClaudeCodeConnection(choice: providers.claude, responses: responses, tools: tools)
        case .anthropic:
            agent = (environment["ANTHROPIC_API_KEY"] ?? Secrets.get(Secrets.anthropicKey))
                .map { AnthropicConnection(key: $0, choice: providers.anthropic, responses: responses, actions: actions) }
        case .custom:
            agent = URL(string: providers.customURL).flatMap { $0.scheme == nil ? nil : $0 }.map {
                OpenAICompatibleConnection(baseURL: $0, key: Secrets.get(Secrets.customKey), choice: providers.custom,
                                           sendsEffort: providers.customSendsEffort, responses: responses)
            }
        }
        agentIsLocal = agent?.canAct ?? false
        bubble.model.agentName = agent?.name ?? providers.active.title
        bubble.model.canAct = agentIsLocal
        log("agent: \(providers.active.title)\(agent == nil ? " (not set up)" : "")\(agentIsLocal ? "" : ", no screen actions")")
    }

    private func startTools() {
        actions.confirm = { [weak self] label in await self?.confirmAction(label) ?? .deny }
        actions.onStep = { [weak self] label in
            self?.bubble.model.step = label
            self?.bubble.model.acting = true
            self?.log("action: \(label)")
        }
        actions.pointAt = { [weak self] spot, snapshot in
            self?.cursor.mood = nil
            self?.cursor.show(at: snapshot.viewPoint(spot), label: spot.label, on: snapshot.screenFrame)
        }
        actions.passThrough = { [weak self] on in self?.bubble.passThrough(on) }
        toolServer = try? ToolServer(actions: actions)
        tools = toolServer?.start()
        log("screen tools: \(tools?.url.absoluteString ?? "none"), accessibility \(AXIsProcessTrusted() ? "allowed" : "NOT allowed")")
    }

    private func confirmAction(_ label: String) async -> ScreenActions.Approval {
        answerAction(.deny)
        let action = label.prefix(1).lowercased() + label.dropFirst()
        bubble.model.phase = .approval("Can I \(action)?")
        bubble.model.canAlwaysAllow = true
        if speaks { voice.say("Can I \(action)?") }
        if touring {
            bubble.model.phase = .approval("Can I \(action)? The tour says yes in 3 seconds.")
            Task {
                try? await Task.sleep(for: .seconds(3))
                answerAction(.allow)
            }
        }
        let answer = await withCheckedContinuation { pendingAction = $0 }
        bubble.model.canAlwaysAllow = false
        if work != nil { bubble.model.phase = .thinking }
        log("action \(answer == .deny ? "refused" : "allowed"): \(label)")
        return answer
    }

    @discardableResult
    private func answerAction(_ answer: ScreenActions.Approval) -> Bool {
        guard let pending = pendingAction else { return false }
        pendingAction = nil
        pending.resume(returning: answer)
        return true
    }

    private func setEffort(_ effort: Effort) {
        guard var json = try? ConfigFile.read() else { return }
        var providers = ProviderSettings(json: json)
        providers.effort = effort
        json = providers.applied(to: json)
        try? ConfigFile.write(json)
        Task { await agent?.setEffort(effort) }
        effortItems.forEach { $0.state = $0.representedObject as? String == effort.rawValue ? .on : .off }
        log("effort: \(effort.rawValue)")
    }

    @objc private func pickEffort(_ sender: NSMenuItem) {
        (sender.representedObject as? String).flatMap(Effort.init(rawValue:)).map(setEffort)
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

    /// Use the Hermes voice when the backend lets Brah in. Until then, and when it does not, the
    /// Mac speaks.
    private func connectVoice() {
        voice.stop()
        voice = Voice(hermes: nil)
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

    func log(_ line: String) {
        FileHandle.standardError.write(Data("brah: \(line)\n".utf8))
    }

    // MARK: Hotkey

    /// Capture the screen at once, so the agent sees it as the user saw it, and start listening.
    /// A press while Brah is open closes it.
    private func pressed() {
        if bubble.isVisible && pressedAt == nil && conversation == nil {
            hide()
            return
        }

        endConversation()
        stop()
        cursor.hide()
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
                if awaitingApproval || pendingAction != nil {
                    answered(words)
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
            bubble.model.phase = .failed("\(ProviderSettings.load().active.title) is not set up. Open Settings from the Brah menu.")
            return
        }

        work?.cancel()
        voice.stop()
        marks.hide()
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
                actions.begin(with: snapshot)
                log("asking\(approved ? " (approved)" : ""): \(question.debugDescription)")
                let reply = try await agent.ask(question, snapshot: snapshot) { [weak self] event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.arrived(event, for: id) } }
                }
                guard !Task.isCancelled, workID == id else { return }
                log("reply=\(reply.text.debugDescription) point=\(String(describing: reply.point)) step=\(String(describing: reply.step)) ask=\(reply.needsApproval) done=\(reply.done)")
                let wasActing = bubble.model.acting
                bubble.model.acting = false
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
                if let step = reply.step, !reply.needsApproval {
                    showStep(step, on: snapshot)
                } else {
                    if bubble.model.guideStep != nil || reply.done || wasActing {
                        endGuide(happy: reply.done || wasActing)
                    }
                    if let spot = reply.point {
                        point(at: spot, on: snapshot)
                    }
                }
                marks.show(reply.marks, on: snapshot)
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
            try await dashboard.holdScreen(locked, reason: "Brah: the user has not said yes to screen actions yet")
            holdingScreen = locked
            log(locked ? "screen locked" : "screen unlocked")
        } catch {
            log("screen lock failed: \(error.localizedDescription)")
        }
    }

    private func approve() {
        guard awaitingApproval else { return }
        log("approved")
        capture = Task { try await Capture.snapshot() }
        bubble.model.question = "Yes, go ahead."
        bubble.model.acting = true
        submit("Yes, go ahead.", approved: true)
    }

    // MARK: Show me

    /// One step of a guide: Brah's cursor flies to the place, and Brah waits for the user's click
    /// anywhere. The click means "done", and Brah asks for the next step with a new screenshot.
    private func showStep(_ step: Spot, on snapshot: Snapshot) {
        bubble.model.guideStep = (bubble.model.guideStep ?? 0) + 1
        log("guide step \(bubble.model.guideStep ?? 0): \(step.label)")
        pointerHide?.cancel()
        cursor.mood = nil
        let place = snapshot.viewPoint(step)
        cursor.show(at: place, label: step.label, on: snapshot.screenFrame)
        // The target in AppKit screen coordinates, for the click test.
        guideTarget = CGPoint(x: snapshot.screenFrame.minX + place.x, y: snapshot.screenFrame.maxY - place.y)
        if clickWatch == nil {
            // Clicks in other apps only: a click on Brah's own bubble is not a step.
            clickWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let at = NSEvent.mouseLocation
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.userClicked(at: at) } }
            }
        }
    }

    /// How near the target a click must be to count as the step. The agent's x and y can be a
    /// little off, and so can the user.
    private static let clickRadius: CGFloat = 70

    private func userClicked(at point: CGPoint) {
        guard bubble.model.guideStep != nil, work == nil, !awaitingApproval, let guideTarget else { return }
        // A click somewhere else is the user doing other things, not this step.
        guard hypot(point.x - guideTarget.x, point.y - guideTarget.y) <= Self.clickRadius else { return }
        log("guide: the user clicked")
        cursor.mood = .thinking
        Task {
            // Let the app under the click change before Brah looks again.
            try? await Task.sleep(for: .milliseconds(700))
            guard bubble.model.guideStep != nil, work == nil else { return }
            capture = Task { try await Capture.snapshot() }
            bubble.model.question = "Next step"
            submit("I clicked it. What is the next step?")
        }
    }

    /// The rest of a guide, done by the agent. The cua-driver shows its own cursor while it works,
    /// so Brah's cursor steps aside.
    private func doItForMe() {
        guard bubble.model.guideStep != nil else { return }
        log("guide: do it for me")
        stopWatchingClicks()
        bubble.model.guideStep = nil
        cursor.hide()
        capture = Task { try await Capture.snapshot() }
        bubble.model.question = "Do it for me"
        bubble.model.acting = true
        submit("Do it for me: finish the remaining steps yourself.", approved: true)
    }

    /// A guide or an approved task is over. `happy`: it worked, so the eyes say so for a moment.
    private func endGuide(happy: Bool) {
        stopWatchingClicks()
        bubble.model.guideStep = nil
        guard happy else {
            cursor.hide()
            return
        }
        bubble.model.celebrating = true
        cursor.mood = .happy
        Task {
            try? await Task.sleep(for: .seconds(2))
            bubble.model.celebrating = false
            if bubble.model.guideStep == nil {
                cursor.hide()
            }
        }
    }

    private func stopWatchingClicks() {
        if let clickWatch {
            NSEvent.removeMonitor(clickWatch)
        }
        clickWatch = nil
        guideTarget = nil
    }

    /// One place, with no guide: the cursor flies there and leaves after a while.
    private func point(at spot: Spot, on snapshot: Snapshot) {
        cursor.mood = nil
        cursor.show(at: snapshot.viewPoint(spot), label: spot.label, on: snapshot.screenFrame)
        pointerHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            guard let self, self.bubble.model.guideStep == nil else { return }
            self.cursor.hide()
        }
        pointerHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: hide)
    }

    /// Words said while Brah waits for a yes. A plain yes or no decides at once. Other words go to
    /// the agent with the screen open for that one request, and the agent decides from the words.
    private func answered(_ words: String) {
        if pendingAction != nil {
            answerAction(Phrases.approval(words) == true ? .allow : .deny)
            return
        }
        if let yes = Phrases.approval(words) {
            yes ? approve() : deny()
            return
        }
        log("unclear answer, the agent decides: \(words.debugDescription)")
        capture = Task { try await Capture.snapshot() }
        submit(Brief.replyToAsk(words), approved: true)
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
        touring = false
        marks.hide()
        answerAction(.deny)
        actions.cancel()
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
        stopWatchingClicks()
        bubble.model.guideStep = nil
        bubble.model.acting = false
        bubble.model.celebrating = false
        // A last flat look, then the cursor goes.
        cursor.mood = .unimpressed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.work == nil, self.bubble.model.guideStep == nil else { return }
            self.cursor.hide()
        }
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

    /// Stop, end a conversation, and take every Brah window off the screen.
    func hide() {
        marks.hide()
        endConversation()
        stop()
        bubble.hide()
        cursor.hide()
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
                log("listening for \"Hey Brah\"")
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
        cursor.hide()
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
                bubble.model.phase = .failed("Brah has no way to listen for a conversation here.")
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
            if awaitingApproval || pendingAction != nil {
                bubble.model.question = words
                answered(words)
                return
            }
            // "Okay" while the agent works after a yes is the user watching, not a new request. A new
            // request would lock the screen and stop the task half done.
            if bubble.model.acting, work != nil, Phrases.approval(words) == true {
                log("kept working: \(words.debugDescription)")
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
    /// of the hotkey would. `--converse` starts a hands-free conversation as "Hey Brah" would.
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
            // `--yes` says yes once when the agent asks to act, as a click on Allow would.
            if arguments.contains("--yes") {
                Task {
                    while !awaitingApproval { try? await Task.sleep(for: .milliseconds(200)) }
                    try? await Task.sleep(for: .seconds(1))
                    approve()
                }
            }
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
            ?? NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Brah")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 18, height: 18)
        icon?.accessibilityDescription = "Brah"
        item.button?.image = icon

        let menu = NSMenu()
        menu.addItem(entry("Type a question", shortcut: nil, action: #selector(menuType)))
        menu.addItem(entry("Stop", shortcut: shortcuts.stop, action: #selector(menuStop)))
        menu.addItem(entry("Hide", shortcut: shortcuts.hide, action: #selector(menuHide)))
        menu.addItem(.separator())
        let handsFree = entry("Listen for \u{201C}Hey Brah\u{201D}", shortcut: nil, action: #selector(toggleHandsFree))
        handsFree.state = handsFreeOn ? .on : .off
        menu.addItem(handsFree)
        handsFreeItem = handsFree
        let speak = entry("Speak replies", shortcut: shortcuts.mute, action: #selector(toggleSpeak))
        speak.state = speaks ? .on : .off
        menu.addItem(speak)
        speakItem = speak
        menu.addItem(entry("New conversation", shortcut: nil, action: #selector(newConversation)))
        menu.addItem(.separator())
        let providers = ProviderSettings.load()
        let agentLine = NSMenuItem(title: "\(providers.active.title)\(agent == nil ? ": not set up" : "")", action: nil, keyEquivalent: "")
        agentLine.isEnabled = false
        menu.addItem(agentLine)
        if let current = providers.effort {
            let effort = NSMenuItem(title: "Effort", action: nil, keyEquivalent: "")
            let levels = NSMenu()
            effortItems = Effort.allCases.map { level in
                let item = NSMenuItem(title: level.rawValue.capitalized, action: #selector(pickEffort), keyEquivalent: "")
                item.target = self
                item.representedObject = level.rawValue
                item.state = level == current ? .on : .off
                levels.addItem(item)
                return item
            }
            effort.submenu = levels
            menu.addItem(effort)
        }
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
        menu.addItem(NSMenuItem(title: "Quit Brah", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    /// A menu bar app has no menu bar of its own, so ⌘, and the edit keys in Settings need one.
    private func buildMainMenu() {
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Brah", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        for menu in [app, edit] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
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
        cursor.hide()
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

    /// Mute stops the voice at once. The answer still shows in the bubble. Unmute says the answer
    /// in the bubble: what has arrived so far, and the rest as it comes.
    private func toggleMute() {
        speaks.toggle()
        if !speaks {
            voice.stop()
        } else if bubble.isVisible {
            if work != nil, bubble.model.phase == .thinking || !shown.isEmpty {
                voice.beginReply()
                if !shown.isEmpty { voice.replyPiece(shown) }
            } else if case .answer(let text) = bubble.model.phase {
                voice.say(text)
            } else if case .approval(let text) = bubble.model.phase {
                voice.say(text)
            }
        }
        speakItem?.state = speaks ? .on : .off
        bubble.model.muted = !speaks
        log(speaks ? "voice on" : "voice muted")
    }

    @objc private func newConversation() {
        Task { await agent?.reset() }
    }
}

// MARK: Tour

extension AppDelegate {
    /// The questions of the hands-free tour of `demo/benchmark.html`. They live here, not in the
    /// page, so a web page cannot give Brah instructions.
    static let tour = [
        "What is this page? Show me its main parts.",
        "Which month had the highest revenue? Show me on the chart.",
        "Switch the date range to Last 90 days.",
        "Open Growth, then the Retention tab. Which cohort keeps the most users at month 3?",
        "Create a campaign named Winter Push for Trial users, and launch it.",
        "Find order #1024 and send its invoice.",
    ]

    /// `brah://tour` from the benchmark page's "Watch Brah do it" button.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "brah" && $0.host == "tour" }), !touring else { return }
        Task { await runTour() }
    }

    private func runTour() async {
        touring = true
        defer { touring = false }
        try? await Task.sleep(for: .seconds(1.5))
        // Only on the benchmark page: on any other screen the fixed steps could do real things.
        guard let first = try? await Capture.snapshot(), first.windowTitle?.contains("Brah benchmark") == true else {
            log("tour: refused, the front window is not the Brah benchmark page")
            return
        }
        log("tour: start")
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let corner = screen.map { CGPoint(x: $0.visibleFrame.maxX - 380, y: $0.visibleFrame.minY + 260) } ?? NSEvent.mouseLocation
        for question in Self.tour {
            guard touring else { return }
            capture = Task { try await Capture.snapshot() }
            bubble.show(near: corner, phase: .thinking, typing: false)
            bubble.model.question = question
            log("tour: \(question)")
            submit(question)
            while touring, work != nil || pendingAction != nil || voice.isSpeaking {
                try? await Task.sleep(for: .milliseconds(300))
            }
            try? await Task.sleep(for: .seconds(2.5))
        }
        log("tour: done")
    }
}
