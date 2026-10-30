import AppKit
import SwiftUI

private struct PointerView: View {
    let at: CGPoint
    let label: String
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .frame(width: 44, height: 44)
                .scaleEffect(pulse ? 1.25 : 0.9)
                .opacity(pulse ? 0.5 : 1)
                .position(at)
            Circle().fill(Color.accentColor).frame(width: 8, height: 8).position(at)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .position(x: at.x, y: at.y + 38)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// A click-through window over one screen that shows where the agent points.
@MainActor
final class Pointer {
    private var panel: NSPanel?
    private var fade: Task<Void, Never>?

    func show(at point: CGPoint, label: String, on screenFrame: CGRect) {
        hide()
        let panel = NSPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PointerView(at: point, label: label))
        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        fade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        fade?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}
