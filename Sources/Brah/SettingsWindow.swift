import AppKit
import BrahCore
import SwiftUI

/// The Settings window: the agent, the voice, the shortcuts and hands-free mode. It writes
/// `~/.config/brah/config.json` and puts the secrets in the Keychain. The app sets `onSave` to
/// load the settings again.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    /// Called after a save, before the window closes.
    var onSave: () -> Void = {}
    /// True when the window opens, false when it closes. The app pauses its global shortcuts
    /// meanwhile, so the key recorder gets every key.
    var onOpen: (Bool) -> Void = { _ in }

    private var window: NSWindow?
    private var model: SettingsModel?

    /// Opens the window with the saved settings, or brings it to the front when it is open.
    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = SettingsModel()
        model.onClose = { [weak self] saved in self?.close(saved: saved) }
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Brah Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        // Tall enough for every section, but never taller than the screen.
        let room = (NSScreen.main?.visibleFrame.height ?? 900) - 60
        window.setContentSize(NSSize(width: 480, height: min(1000, room)))
        window.delegate = self
        window.center()
        self.model = model
        self.window = window
        onOpen(true)

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close(saved: Bool) {
        if saved { onSave() }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model?.stopRecording()
        model = nil
        window = nil
        onOpen(false)
    }
}

/// The values in the window, and the key recorder.
@MainActor
final class SettingsModel: ObservableObject {
    static let actions = [("talk", "Talk"), ("stop", "Stop"), ("mute", "Mute"), ("hide", "Hide"), ("handsFree", "Hands-free")]

    /// The Keychain accounts that the window shows.
    static let secretAccounts = [Secrets.hermesKey, Secrets.voicePassword, Secrets.accessClientID, Secrets.accessClientSecret]

    @Published var settings: EditableSettings
    /// The secrets in the fields, by Keychain account.
    @Published var secrets: [String: String]
    /// The name of the shortcut that waits for keys.
    @Published private(set) var recording: String?
    /// A key that the recorder did not take, and why.
    @Published private(set) var shortcutProblem: (name: String, text: String)?
    @Published private(set) var saveProblem: String?

    /// True when the config file has a secret of an older setup. It is used when the field is empty.
    let fileHasKey: Bool
    let fileHasPassword: Bool

    var onClose: (Bool) -> Void = { _ in }

    private let savedSecrets: [String: String]
    private var monitor: Any?

    init() {
        var json: [String: Any] = [:]
        do {
            json = try ConfigFile.read()
        } catch {
            saveProblem = Self.text(error)
        }
        settings = EditableSettings(json: json)
        savedSecrets = Dictionary(uniqueKeysWithValues: Self.secretAccounts.map { ($0, Secrets.get($0) ?? "") })
        secrets = savedSecrets

        let hermes = json["hermes"] as? [String: Any]
        fileHasKey = (hermes?["key"] as? String)?.isEmpty == false
        fileHasPassword = ((hermes?["voice"] as? [String: Any])?["password"] as? String)?.isEmpty == false
    }

    // MARK: Key recorder

    func toggleRecording(_ name: String) {
        let wasRecording = recording == name
        stopRecording()
        guard !wasRecording else { return }

        recording = name
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // While the recorder waits, no key reaches the fields or the buttons.
            let taken = MainActor.assumeIsolated { self?.record(event) ?? false }
            return taken ? nil : event
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    /// True when the key press was for the recorder.
    private func record(_ event: NSEvent) -> Bool {
        guard let name = recording else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.control) { modifiers |= Shortcut.control }
        if flags.contains(.option) { modifiers |= Shortcut.option }
        if flags.contains(.shift) { modifiers |= Shortcut.shift }
        if flags.contains(.command) { modifiers |= Shortcut.command }
        let keyCode = Int(event.keyCode)

        if keyCode == 53, modifiers == 0 { // Esc
            shortcutProblem = nil
            stopRecording()
            return true
        }
        guard let shortcut = Shortcut.from(keyCode: keyCode, modifiers: modifiers) else {
            shortcutProblem = (name, Shortcut.knows(keyCode: keyCode)
                ? "Add ⌃, ⌥, ⇧ or ⌘. Only F1 to F12 work alone."
                : "Brah cannot use this key. Use a letter, a digit, Space, an arrow or F1 to F12.")
            return true
        }
        if let other = Self.actions.first(where: { $0.0 != name && settings.shortcuts[$0.0]?.sameKeys(as: shortcut) == true }) {
            shortcutProblem = (name, "\(shortcut.display) is already the shortcut for \(other.1).")
            return true
        }
        settings.shortcuts[name] = shortcut
        shortcutProblem = nil
        stopRecording()
        return true
    }

    func problem(for name: String) -> String? {
        shortcutProblem?.name == name ? shortcutProblem?.text : nil
    }

    // MARK: Save

    func save() {
        stopRecording()
        for (text, label) in [(settings.hermesURL, "Hermes address"), (settings.voiceURL, "dashboard address")] {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
                saveProblem = "The \(label) must start with http:// or https://."
                return
            }
        }

        // A password can start or end with a space. A key, a client ID or a client secret cannot.
        var values = secrets.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        values[Secrets.voicePassword] = secrets[Secrets.voicePassword]
        if values[Secrets.accessClientID, default: ""].isEmpty != values[Secrets.accessClientSecret, default: ""].isEmpty {
            saveProblem = "Fill in both the Access client ID and the Access client secret, or neither."
            return
        }

        do {
            try ConfigFile.write(settings.applied(to: try ConfigFile.read()))
            for account in Self.secretAccounts where values[account, default: ""] != savedSecrets[account, default: ""] {
                try Secrets.set(values[account, default: ""], for: account)
            }
        } catch {
            saveProblem = Self.text(error)
            return
        }
        onClose(true)
    }

    func cancel() {
        stopRecording()
        onClose(false)
    }

    private static func text(_ error: Error) -> String {
        switch error {
        case let failure as ConfigFile.Failure: failure.description
        case let failure as Secrets.Failure: failure.description
        default: error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Agent") {
                    TextField("Hermes address", text: $model.settings.hermesURL,
                              prompt: Text(HermesSettings.defaultURL.absoluteString))
                    SecureField("API key", text: secret(Secrets.hermesKey),
                                prompt: Text(model.fileHasKey ? "Saved in config.json" : "Not set"))
                    note("Hermes can run on this Mac or on a server, with an http:// or https:// address. "
                         + (model.fileHasKey
                            ? "With no key here, Brah uses the key in ~/.config/brah/config.json."
                            : "With no key, Brah reads API_SERVER_KEY from ~/.hermes/.env."))
                }

                Section("Voice") {
                    TextField("Dashboard address", text: $model.settings.voiceURL,
                              prompt: Text(HermesVoiceSettings.defaultURL.absoluteString))
                    TextField("Username", text: $model.settings.voiceUsername, prompt: Text("Not set"))
                    SecureField("Password", text: secret(Secrets.voicePassword),
                                prompt: Text(model.fileHasPassword ? "Saved in config.json" : "Not set"))
                    note("The username and password are only for a dashboard with a sign-in. With the deepgram-live plugin, Brah uses your live voice.")
                }

                Section("Cloudflare Access") {
                    TextField("Access client ID", text: secret(Secrets.accessClientID), prompt: Text("Not set"))
                    SecureField("Access client secret", text: secret(Secrets.accessClientSecret), prompt: Text("Not set"))
                    note("Only for a server behind Cloudflare Access. Brah sends this pair to the Hermes address and to the dashboard.")
                }

                Section {
                    ForEach(SettingsModel.actions, id: \.0) { name, title in
                        LabeledContent(title) {
                            Button {
                                model.toggleRecording(name)
                            } label: {
                                Text(model.recording == name ? "Press keys…" : model.settings.shortcuts[name]?.display ?? "")
                                    .frame(width: 110)
                            }
                        }
                        if let problem = model.problem(for: name) {
                            Text(problem)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Shortcuts")
                } footer: {
                    note("Click a shortcut, then press the new keys. Esc cancels.")
                }

                Section("Hands-free") {
                    Toggle("Listen for “Hey Brah”", isOn: $model.settings.handsFree.enabled)
                    LabeledContent("Stop after") {
                        HStack {
                            Text("\(model.settings.handsFree.idleSeconds) seconds of quiet")
                                .monospacedDigit()
                            Stepper("Stop after", value: $model.settings.handsFree.idleSeconds,
                                    in: HandsFreeSettings.idleRange, step: 5)
                                .labelsHidden()
                        }
                    }
                    .disabled(!model.settings.handsFree.enabled)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let problem = model.saveProblem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
        .frame(minHeight: 420, maxHeight: .infinity)
    }

    private func secret(_ account: String) -> Binding<String> {
        Binding(get: { model.secrets[account, default: ""] }, set: { model.secrets[account] = $0 })
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
