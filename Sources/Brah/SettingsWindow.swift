import AppKit
import AVFoundation
import BrahCore
import SwiftUI

/// The Settings window: the AI provider, the voice, the shortcuts and hands-free mode. It writes
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

    /// The window's number, for a screenshot of it alone.
    var windowNumber: Int? { window?.windowNumber }

    /// Opens the window with the saved settings, or brings it to the front when it is open.
    /// `demo` fills it with made-up values, for screenshots.
    func show(demo: Bool = false) {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = demo ? SettingsModel.demo() : SettingsModel()
        model.onClose = { [weak self] saved in self?.close(saved: saved) }
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Brah Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        // Tall enough for every section, but never taller than the screen.
        let room = (NSScreen.main?.visibleFrame.height ?? 900) - 60
        window.setContentSize(NSSize(width: 520, height: min(540, room)))
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
    static let secretAccounts = [Secrets.hermesKey, Secrets.voicePassword, Secrets.accessClientID, Secrets.accessClientSecret,
                                 Secrets.anthropicKey, Secrets.customKey, Secrets.deepgramKey, Secrets.groqKey]

    @Published var settings: EditableSettings
    @Published var providers: ProviderSettings
    @Published var responses: ResponseSettings
    @Published var speech: SpeechSettings
    private let preview = AVSpeechSynthesizer()
    /// Model ids from the provider, after a check.
    @Published var models: [String] = []
    @Published var check: (ok: Bool, text: String)?
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
        providers = ProviderSettings(json: json)
        responses = ResponseSettings(json: json)
        speech = SpeechSettings(json: json)
        savedSecrets = Dictionary(uniqueKeysWithValues: Self.secretAccounts.map { ($0, Secrets.get($0) ?? "") })
        secrets = savedSecrets

        let hermes = json["hermes"] as? [String: Any]
        fileHasKey = (hermes?["key"] as? String)?.isEmpty == false
        fileHasPassword = ((hermes?["voice"] as? [String: Any])?["password"] as? String)?.isEmpty == false
        isDemo = false
    }

    /// Made-up values for screenshots. A demo never reads or writes the real settings.
    private init(demo settings: EditableSettings, secrets: [String: String]) {
        self.settings = settings
        providers = ProviderSettings(active: .claude)
        responses = ResponseSettings()
        speech = SpeechSettings(provider: .deepgram, deepgramVoice: "aura-2-athena-en")
        self.secrets = secrets
        savedSecrets = secrets
        fileHasKey = false
        fileHasPassword = false
        isDemo = true
    }

    static func demo() -> SettingsModel {
        var settings = EditableSettings(hermesURL: "https://hermes.example.com", voiceURL: "https://hermes.example.com",
                                        voiceUsername: "ava")
        settings.handsFree = HandsFreeSettings(enabled: true, idleSeconds: 20)
        return SettingsModel(demo: settings, secrets: [
            Secrets.hermesKey: "demo-key-0000000000", Secrets.voicePassword: "demo-password",
            Secrets.accessClientID: "", Secrets.accessClientSecret: "",
        ])
    }

    private let isDemo: Bool

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
        guard !isDemo else {
            onClose(false)
            return
        }
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

        if providers.active == .custom {
            guard let url = URL(string: providers.customURL.trimmingCharacters(in: .whitespaces)),
                  ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
                saveProblem = "The server address must start with http:// or https://."
                return
            }
            guard !providers.custom.model.trimmingCharacters(in: .whitespaces).isEmpty else {
                saveProblem = "Pick a model for the server."
                return
            }
        }

        do {
            let json = providers.applied(to: settings.applied(to: try ConfigFile.read()))
            try ConfigFile.write(speech.applied(to: responses.applied(to: json)))
            for account in Self.secretAccounts where values[account, default: ""] != savedSecrets[account, default: ""] {
                try Secrets.set(values[account, default: ""], for: account)
            }
        } catch {
            saveProblem = Self.text(error)
            return
        }
        onClose(true)
    }

    func playVoice() {
        preview.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Ho, brah. This is how I sound.")
        utterance.voice = AVSpeechSynthesisVoice(identifier: speech.macVoice) ?? Voice.bestMacVoice
        preview.speak(utterance)
    }

    /// Reaches the provider with the key in the field, and loads its models.
    func checkProvider() async {
        check = nil
        models = []
        do {
            switch providers.active {
            case .hermes:
                check = (true, "Save, then ask Brah a question to check Hermes.")
                return
            case .claude:
                guard let path = ClaudeCodeConnection.executable() else { throw ProviderError.notInstalled }
                check = (true, "Claude Code found at \(path.path). It uses your Claude sign-in.")
                return
            case .anthropic:
                let key = secrets[Secrets.anthropicKey, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw ProviderError.noKey("the Anthropic API") }
                models = try await AnthropicConnection.models(key: key)
            case .custom:
                guard let url = URL(string: providers.customURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
                    throw ProviderError.offline
                }
                models = try await OpenAICompatibleConnection.models(baseURL: url, key: secrets[Secrets.customKey])
            }
            check = (true, "Connected. \(models.count) models.")
        } catch {
            check = (false, error.localizedDescription)
        }
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
            TabView {
                Form { providerSection }
                    .formStyle(.grouped)
                    .tabItem { Label("AI", systemImage: "sparkles") }
                Form { voiceSection }
                    .formStyle(.grouped)
                    .tabItem { Label("Voice", systemImage: "waveform") }
                Form {
                    shortcutsSection
                    handsFreeSection
                }
                .formStyle(.grouped)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            }

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
        .frame(width: 520)
        .frame(minHeight: 480, maxHeight: .infinity)
        .onChange(of: model.providers.active) {
            model.check = nil
            model.models = []
        }
    }

    @ViewBuilder
    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $model.providers.active) {
                ForEach(ProviderKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } footer: {
            note(providerNote)
        }

        Section {
            switch model.providers.active {
            case .hermes:
                TextField("Address", text: $model.settings.hermesURL, prompt: Text(HermesSettings.defaultURL.absoluteString))
                SecureField("API key", text: secret(Secrets.hermesKey),
                            prompt: Text(model.fileHasKey ? "Saved in config.json" : "From ~/.hermes/.env"))
            case .claude:
                Picker("Model", selection: $model.providers.claude.model) {
                    ForEach(ProviderSettings.claudeModels, id: \.self) { Text($0.capitalized).tag($0) }
                }
                effortPicker($model.providers.claude.effort)
            case .anthropic:
                SecureField("API key", text: secret(Secrets.anthropicKey), prompt: Text("sk-ant-…"))
                modelField($model.providers.anthropic.model)
                effortPicker($model.providers.anthropic.effort)
            case .custom:
                TextField("Server", text: $model.providers.customURL, prompt: Text("http://localhost:11434/v1"))
                SecureField("API key", text: secret(Secrets.customKey), prompt: Text("Optional"))
                modelField($model.providers.custom.model)
                Toggle("Send effort", isOn: $model.providers.customSendsEffort)
                if model.providers.customSendsEffort {
                    effortPicker($model.providers.custom.effort)
                }
            }
            HStack {
                Button("Check") { Task { await model.checkProvider() } }
                if let check = model.check {
                    Text(check.text)
                        .font(.callout)
                        .foregroundStyle(check.ok ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        Section {
            Picker("Answers", selection: $model.responses.style) {
                Text("Short").tag(ResponseSettings.Style.short)
                Text("Normal").tag(ResponseSettings.Style.normal)
                Text("Detailed").tag(ResponseSettings.Style.detailed)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom instructions")
                TextEditor(text: $model.responses.instructions)
                    .font(.body)
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        } header: {
            Text("Responses")
        } footer: {
            note("Brah gives these to every provider, for example: “Call me Rez. Use British English.”")
        }

        if model.providers.active == .hermes {
            Section {
                DisclosureGroup("Advanced") {
                    TextField("Access client ID", text: secret(Secrets.accessClientID), prompt: Text("Not set"))
                    SecureField("Access client secret", text: secret(Secrets.accessClientSecret), prompt: Text("Not set"))
                    note("Only for a Hermes server behind Cloudflare Access.")
                }
            }
        }
    }

    private var providerNote: String {
        switch model.providers.active {
        case .hermes: "Your own Hermes agent, on this Mac or on a server. It can click for you after a yes."
        case .claude: "Uses your Claude plan through Claude Code. Install it and sign in once."
        case .anthropic: "Pay per use with a key from console.anthropic.com."
        case .custom: "Any server with an OpenAI-style API: Ollama, LM Studio, OpenRouter, Groq. Pick a model that can see images."
        }
    }

    private func modelField(_ text: Binding<String>) -> some View {
        HStack {
            TextField("Model", text: text)
            if !model.models.isEmpty {
                Menu("Models") {
                    ForEach(model.models, id: \.self) { name in Button(name) { text.wrappedValue = name } }
                }
                .fixedSize()
            }
        }
    }

    private func effortPicker(_ effort: Binding<Effort>) -> some View {
        Picker("Effort", selection: effort) {
            ForEach(Effort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
    }

    @ViewBuilder
    private var voiceSection: some View {
        Section {
            Picker("Speaks with", selection: $model.speech.provider) {
                ForEach(SpeechProvider.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            switch model.speech.provider {
            case .deepgram:
                Picker("Voice", selection: $model.speech.deepgramVoice) {
                    ForEach(SpeechSettings.deepgramVoices, id: \.id) { Text($0.about).tag($0.id) }
                }
                SecureField("API key", text: secret(Secrets.deepgramKey), prompt: Text("From your Hermes if empty"))
            case .groq:
                Picker("Voice", selection: $model.speech.groqVoice) {
                    ForEach(SpeechSettings.groqVoices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                SecureField("API key", text: secret(Secrets.groqKey), prompt: Text("gsk_…"))
            case .auto, .mac:
                EmptyView()
            }
        } header: {
            Text("Voice")
        } footer: {
            note(speechNote)
        }

        Section {
            HStack {
                Picker("Mac voice", selection: $model.speech.macVoice) {
                    Text("Best installed").tag("")
                    ForEach(Voice.macVoices, id: \.identifier) { voice in
                        Text(voiceName(voice)).tag(voice.identifier)
                    }
                }
                Button("Play") { model.playVoice() }
            }
        } footer: {
            note("The Mac voice speaks when no other voice can. Add better voices in System Settings, Accessibility, Spoken Content.")
        }

        Section {
            TextField("Dashboard address", text: $model.settings.voiceURL,
                      prompt: Text(HermesVoiceSettings.defaultURL.absoluteString))
            TextField("Username", text: $model.settings.voiceUsername, prompt: Text("Not set"))
            SecureField("Password", text: secret(Secrets.voicePassword),
                        prompt: Text(model.fileHasPassword ? "Saved in config.json" : "Not set"))
        } header: {
            Text("Hermes voice")
        } footer: {
            note("Optional. Without it, your Mac listens and speaks. The username and password are only for a dashboard with a sign-in.")
        }
    }

    private var shortcutsSection: some View {
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
    }

    private var handsFreeSection: some View {
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

    private var speechNote: String {
        switch model.speech.provider {
        case .auto: "Your Hermes voice when Hermes has one, else your Mac."
        case .mac: "Free, private, and works offline."
        case .deepgram: "Speaks while the answer arrives. With a key, Brah also listens with Deepgram."
        case .groq: "Speaks a sentence at a time with your Groq key."
        }
    }

    private func voiceName(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = voice.quality == .premium ? ", Premium" : voice.quality == .enhanced ? ", Enhanced" : ""
        return "\(voice.name) (\(voice.language)\(quality))"
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
