import AppKit
import SwiftUI

@MainActor
final class BubbleModel: ObservableObject {
    enum Phase: Equatable {
        case listening
        case transcribing
        case asking
        case thinking
        case answer(String)
        /// The agent says what it will do on the screen and waits for a yes.
        case approval(String)
        case failed(String)
    }

    @Published var phase: Phase = .asking
    @Published var question = ""
    /// What the agent is doing now ("Clicking Save"), while it works.
    @Published var step: String?
    /// A hands-free conversation is on: Brah listens again after each answer.
    @Published var handsFree = false
    @Published var muted = false
    /// The step of a "show me" guide, from 1. Nil when Brah is not guiding.
    @Published var guideStep: Int?
    /// The agent works on the screen after a yes.
    @Published var acting = false
    /// A task is done: happy eyes for a moment.
    @Published var celebrating = false
    var onDoIt: () -> Void = {}

    /// How Brah looks now.
    var mood: Mood {
        if celebrating { return .happy }
        switch phase {
        case .listening: return .listening
        case .transcribing: return .thinking
        case .asking: return .looking(CGVector(dx: 0.2, dy: 1))
        case .thinking: return acting ? .working : .thinking
        case .answer: return guideStep != nil ? .looking(CGVector(dx: 0.9, dy: -0.4)) : .speaking
        case .approval: return .asking
        case .failed: return .unimpressed
        }
    }
    var agentName = "Hermes"
    var onSubmit: (String) -> Void = { _ in }
    var onStop: () -> Void = {}
    var onMute: () -> Void = {}
    /// Start or end a hands-free conversation.
    var onListen: () -> Void = {}
    var onClose: () -> Void = {}
    var onApprove: (Bool) -> Void = { _ in }

    var isBusy: Bool { [.listening, .transcribing, .thinking].contains(phase) }
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .font(.system(size: 14))
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(DragArea())
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    /// Brah's eyes, the sound, and the controls.
    private var header: some View {
        HStack(spacing: 8) {
            BrahFace(mood: model.mood)
            if model.phase == .listening || model.handsFree {
                Waveform(input: model.phase == .listening)
            } else if case .answer = model.phase, !model.muted {
                Waveform(input: false)
            } else {
                Text(model.agentName).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            control(model.handsFree ? "mic.fill" : "mic.slash", help: model.handsFree ? "Stop listening" : "Keep listening: talk without the hotkey",
                    tint: model.handsFree ? .red : nil, action: model.onListen)
            control(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: model.muted ? "Unmute the voice" : "Mute the voice", action: model.onMute)
            if model.isBusy {
                control("stop.fill", help: "Stop", action: model.onStop)
            }
            control("xmark", help: "Close", action: model.onClose)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            Text(model.question.isEmpty ? "Listening" : model.question).fixedSize(horizontal: false, vertical: true)
            hint(model.handsFree ? "say \u{201C}bye\u{201D} to end" : "release to send")
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.question.isEmpty ? "Writing down what you said" : model.question).foregroundStyle(.secondary)
            }
        case .asking:
            TextField("Ask \(model.agentName) about your screen", text: $model.question)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.onSubmit(model.question) }
                .onAppear { focused = true }
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.step ?? model.question).lineLimit(2).foregroundStyle(.secondary)
            }
        case .answer(let text):
            Answer(text: text)
            if let number = model.guideStep {
                HStack(spacing: 8) {
                    hint("Step \(number): click where Brah points")
                    Spacer()
                    Button("Do it for me", action: model.onDoIt).controlSize(.small)
                }
            } else if let step = model.step {
                hint(step)
            }
        case .approval(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Allow") { model.onApprove(true) }.keyboardShortcut(.defaultAction)
                Button("Not now") { model.onApprove(false) }
                Spacer()
                hint(model.handsFree ? "or say yes or no" : "")
            }
            .controlSize(.small)
        case .failed(let text):
            Text(text).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func control(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .contentShape(Rectangle())
        .help(help)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
    }
}

/// The agent's answer. A copy button shows while the pointer is over it.
private struct Answer: View {
    let text: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 22)
            .overlay(alignment: .topTrailing) {
                if hovering || copied {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(copied ? "Copied" : "Copy the answer")
                }
            }
            .onHover { hovering = $0 }
    }
}

/// The loudness of the microphone (while listening) or of the voice (while it speaks).
private struct Waveform: View {
    let input: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { _ in
            let levels = AudioIO.shared.levels(input: input)
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(input ? Color.red.opacity(0.8) : Color.accentColor)
                        .frame(width: 2, height: 3 + CGFloat(levels[index]) * 15)
                }
            }
            .frame(height: 18)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}

/// The empty parts of the bubble move it, so it never sits on top of what the user needs.
private struct DragArea: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// A panel that takes typing without making Brah the active app, so the app the user works in
/// stays in front.
private final class BubblePanel: NSPanel {
    var onEscape: () -> Void = {}

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }
}

@MainActor
final class Bubble {
    let model = BubbleModel()
    private let panel: BubblePanel
    private var anchor = CGPoint.zero
    /// Set when the user drags the bubble: from then on it stays where they put it.
    private var dragged: CGPoint?
    private var placing = false

    var isVisible: Bool { panel.isVisible }

    init(onEscape: @escaping () -> Void) {
        panel = BubblePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = onEscape

        let host = NSHostingController(rootView: BubbleView(model: model))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host

        // The panel grows with its text. Keep its top-left corner where it opened, or where the
        // user dragged it.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placing else { return }
                self.dragged = CGPoint(x: self.panel.frame.minX, y: self.panel.frame.maxY)
            }
        }
    }

    /// `typing` makes the panel take the keyboard. Without it the app the user works in keeps it.
    func show(near mouse: CGPoint, phase: BubbleModel.Phase, typing: Bool) {
        model.question = ""
        model.phase = phase
        anchor = CGPoint(x: mouse.x + 18, y: mouse.y - 18)
        dragged = nil
        place()
        if typing {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func bringToFront() {
        panel.orderFrontRegardless()
    }

    private func place() {
        placing = true
        defer { placing = false }
        if let dragged {
            panel.setFrameTopLeftPoint(dragged)
            return
        }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        // Stay on the screen: flip to the other side of the cursor near the right or bottom edge.
        let x = anchor.x + size.width > visible.maxX ? anchor.x - size.width - 36 : anchor.x
        let top = anchor.y - size.height < visible.minY ? anchor.y + size.height + 36 : anchor.y
        panel.setFrameTopLeftPoint(CGPoint(x: max(visible.minX, x), y: min(visible.maxY, top)))
    }
}
