import AppKit
import SwiftUI

@MainActor
final class BubbleModel: ObservableObject {
    enum Phase: Equatable {
        case asking
        case thinking
        case answer(String)
        case failed(String)
    }

    @Published var phase: Phase = .asking
    @Published var question = ""
    var agentName = "Hermes"
    var onSubmit: (String) -> Void = { _ in }
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.phase {
            case .asking:
                TextField("Ask \(model.agentName) about your screen", text: $model.question)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { model.onSubmit(model.question) }
                    .onAppear { focused = true }
            case .thinking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.question).lineLimit(2).foregroundStyle(.secondary)
                }
                hint("esc to stop")
            case .answer(let text):
                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                hint("esc to close")
            case .failed(let text):
                Text(text).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                hint("esc to close")
            }
        }
        .font(.system(size: 14))
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
    }
}

/// A panel that takes typing without making Bruh the active app, so the app the user works in
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

        // The panel grows with its text. Keep its top-left corner where it opened.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeTopLeft() }
        }
    }

    func show(near mouse: CGPoint, phase: BubbleModel.Phase) {
        model.question = ""
        model.phase = phase
        anchor = CGPoint(x: mouse.x + 18, y: mouse.y - 18)
        placeTopLeft()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func placeTopLeft() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        // Stay on the screen: flip to the other side of the cursor near the right or bottom edge.
        let x = anchor.x + size.width > visible.maxX ? anchor.x - size.width - 36 : anchor.x
        let top = anchor.y - size.height < visible.minY ? anchor.y + size.height + 36 : anchor.y
        panel.setFrameTopLeftPoint(CGPoint(x: max(visible.minX, x), y: min(visible.maxY, top)))
    }
}
