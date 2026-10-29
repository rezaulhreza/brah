import AVFoundation
import AppKit
import BruhCore
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private lazy var bubble = Bubble(onEscape: { [weak self] in self?.escape() })
    private let pointer = Pointer()
    private let voice = AVSpeechSynthesizer()
    private var agent: AgentConnection?
    private var snapshot: Snapshot?
    private var work: Task<Void, Never>?

    private var speaks: Bool {
        get { UserDefaults.standard.object(forKey: "speak") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speak") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        agent = HermesSettings.load().map { HermesConnection(settings: $0) }
        bubble.model.agentName = agent?.name ?? "Hermes"
        bubble.model.onSubmit = { [weak self] question in self?.submit(question) }

        Hotkeys.register(kVK_Space, modifiers: Hotkeys.control | Hotkeys.option) { [weak self] in self?.ask() }
        Hotkeys.register(kVK_ANSI_Period, modifiers: Hotkeys.control | Hotkeys.option) { [weak self] in self?.stop() }
        Hotkeys.register(kVK_ANSI_H, modifiers: Hotkeys.control | Hotkeys.option) { [weak self] in self?.hide() }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        buildMenu()

        // `Bruh --ask "question"` runs one question without the hotkey, for tests and scripts.
        if let index = CommandLine.arguments.firstIndex(of: "--ask"), index + 1 < CommandLine.arguments.count {
            let question = CommandLine.arguments[index + 1]
            Task {
                let mouse = NSEvent.mouseLocation
                do {
                    snapshot = try await Capture.snapshot()
                } catch {
                    log("capture failed: \(error.localizedDescription)")
                    bubble.show(near: mouse, phase: .failed(error.localizedDescription))
                    return
                }
                log("captured \(Int(snapshot!.imageSize.width))x\(Int(snapshot!.imageSize.height)), asking")
                bubble.show(near: mouse, phase: .asking)
                bubble.model.question = question
                submit(question)
            }
        }
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("bruh: \(line)\n".utf8))
    }

    // MARK: Actions

    /// The hotkey: capture the screen first, so the agent sees it as the user saw it, then ask.
    /// A second press while Bruh is open closes it.
    func ask() {
        if bubble.isVisible {
            hide()
            return
        }

        stop()
        pointer.hide()
        let mouse = NSEvent.mouseLocation

        Task {
            do {
                snapshot = try await Capture.snapshot()
                bubble.show(near: mouse, phase: .asking)
            } catch {
                bubble.show(near: mouse, phase: .failed(error.localizedDescription))
            }
        }
    }

    private func submit(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let snapshot else { return }
        guard let agent else {
            bubble.model.phase = .failed("No Hermes key found. Set BRUH_HERMES_KEY, or write ~/.config/bruh/config.json.")
            return
        }

        bubble.model.phase = .thinking
        work = Task {
            do {
                let reply = try await agent.ask(question, snapshot: snapshot)
                guard !Task.isCancelled else { return }
                log("reply=\(reply.text.debugDescription) point=\(String(describing: reply.point))")
                bubble.model.phase = .answer(reply.text)
                if speaks {
                    voice.speak(AVSpeechUtterance(string: reply.text))
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

    /// Stop waiting for the agent and stop talking. The bubble stays, so the user sees it stopped.
    func stop() {
        work?.cancel()
        work = nil
        voice.stopSpeaking(at: .immediate)
        if bubble.model.phase == .thinking {
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
        if bubble.model.phase == .thinking {
            stop()
        } else {
            hide()
        }
    }

    // MARK: Menu bar

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Bruh")

        let menu = NSMenu()
        menu.addItem(entry("Ask", key: " ", action: #selector(menuAsk)))
        menu.addItem(entry("Stop", key: ".", action: #selector(menuStop)))
        menu.addItem(entry("Hide", key: "h", action: #selector(menuHide)))
        menu.addItem(.separator())
        let speak = entry("Speak replies", key: "", action: #selector(toggleSpeak))
        speak.state = speaks ? .on : .off
        menu.addItem(speak)
        menu.addItem(entry("New conversation", key: "", action: #selector(newConversation)))
        menu.addItem(.separator())
        let status = NSMenuItem(title: agent == nil ? "Hermes: no key found" : "Connected to Hermes", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem(title: "Quit Bruh", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    private func entry(_ title: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty && key != "q" {
            item.keyEquivalentModifierMask = [.control, .option]
        }
        return item
    }

    @objc private func menuAsk() { ask() }
    @objc private func menuStop() { stop() }
    @objc private func menuHide() { hide() }

    @objc private func toggleSpeak(_ sender: NSMenuItem) {
        speaks.toggle()
        sender.state = speaks ? .on : .off
    }

    @objc private func newConversation() {
        Task { await agent?.reset() }
    }
}
