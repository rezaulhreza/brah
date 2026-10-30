import AppKit
import SwiftUI

/// Brah's own cursor: a yellow arrow with the side-eye. It flies from the user's pointer to the
/// place Brah means, leaves a trail that fades, and pulses there with a label. It never takes
/// the mouse: the window lets every click through.
@MainActor
final class CursorModel: ObservableObject {
    struct Mark {
        let point: CGPoint
        let time: Date
    }

    @Published var position: CGPoint = .zero
    @Published var label = ""
    @Published var arrived = false
    @Published var visible = false
    /// Set by the app: thinking, working, happy. Nil: the cursor's own looks while it flies and waits.
    @Published var mood: Mood?
    private(set) var trail: [Mark] = []
    private(set) var direction = CGVector(dx: 1, dy: 0)
    private(set) var arrivedAt: Date?

    /// How long Brah waits at a target before the eyes go flat: "bruh, click it".
    static let patience: TimeInterval = 8

    /// The eyes: the app's mood, else where it flies, then at the target, then unimpressed.
    func look(at now: Date) -> Mood {
        if let mood { return mood }
        guard arrived, let arrivedAt else { return .looking(direction) }
        return now.timeIntervalSince(arrivedAt) > Self.patience ? .unimpressed : .looking(CGVector(dx: -0.7, dy: -0.7))
    }

    static let flight: TimeInterval = 0.75
    static let trailLife: TimeInterval = 0.9

    private var timer: Timer?

    /// Fly from `start` to `end` (view points) on a slight arc, easing in and out.
    func fly(from start: CGPoint, to end: CGPoint, label: String) {
        timer?.invalidate()
        self.label = label
        arrived = false
        arrivedAt = nil
        visible = true
        position = start
        trail = []
        direction = CGVector(dx: end.x - start.x, dy: end.y - start.y)

        // The arc bends to one side of the straight line, by a fifth of its length.
        let dx = end.x - start.x
        let dy = end.y - start.y
        let bend = CGPoint(x: (start.x + end.x) / 2 - dy * 0.2, y: (start.y + end.y) / 2 + dx * 0.2)
        let began = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = min(1, Date().timeIntervalSince(began) / Self.flight)
                self.position = Self.arc(start, bend, end, at: Self.ease(t))
                self.trail.append(Mark(point: self.position, time: Date()))
                self.trail.removeAll { Date().timeIntervalSince($0.time) > Self.trailLife }
                if t >= 1 {
                    if !self.arrived { self.arrivedAt = Date() }
                    self.arrived = true
                    // Keep ticking until the trail has faded.
                    if self.trail.isEmpty { timer.invalidate() }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        visible = false
        trail = []
    }

    /// Slow at the start and at the end.
    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// A point on the curve from `a` through the pull of `b` to `c`, for `t` from 0 to 1.
    private static func arc(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, at t: Double) -> CGPoint {
        let u = 1 - t
        let x = u * u * a.x + 2 * u * t * b.x + t * t * c.x
        let y = u * u * a.y + 2 * u * t * b.y + t * t * c.y
        return CGPoint(x: x, y: y)
    }
}

private struct CursorView: View {
    @ObservedObject var model: CursorModel
    @State private var motion = EyeMotion()

    var body: some View {
        TimelineView(.animation) { context in
            ZStack(alignment: .topLeading) {
                Color.clear
                if model.visible {
                    Canvas { canvas, _ in
                        let now = context.date
                        let marks = model.trail
                        for (index, mark) in marks.enumerated() where index > 0 {
                            let age = now.timeIntervalSince(mark.time) / CursorModel.trailLife
                            guard age < 1 else { continue }
                            var line = Path()
                            line.move(to: marks[index - 1].point)
                            line.addLine(to: mark.point)
                            canvas.stroke(line, with: .color(Self.yellow.opacity(0.85 * (1 - age))),
                                          style: StrokeStyle(lineWidth: 6 * (1 - age) + 1, lineCap: .round))
                        }
                    }
                    if model.arrived {
                        Pulse().position(model.position)
                        if !model.label.isEmpty {
                            Text(model.label)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Self.yellow.opacity(0.8)))
                                .fixedSize()
                                .position(x: model.position.x + 18, y: model.position.y + 44)
                        }
                    }
                    let time = context.date.timeIntervalSinceReferenceDate
                    let look = motion.step(to: EyeLook.of(model.look(at: context.date), at: time))
                    Arrow(look: look, blink: look.happy ? 0 : EyeLook.blink(at: time))
                        .frame(width: 28, height: 44)
                        // The arrow's tip is its top left corner.
                        .position(x: model.position.x + 14, y: model.position.y + 22)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                }
            }
        }
    }

    static let yellow = Color(red: 1, green: 0.77, blue: 0.19)
}

/// The arrow of the app icon, with the half-shut eyes.
private struct Arrow: View {
    let look: EyeLook
    let blink: Double

    var body: some View {
        Canvas { canvas, size in
            // The icon's arrow, in a 432 x 684 box.
            let scale = min(size.width / 432, size.height / 684)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
            var arrow = Path()
            arrow.move(to: p(0, 0))
            for (x, y) in [(0, 600), (144, 468), (240, 684), (336, 642), (240, 432), (432, 432)] as [(CGFloat, CGFloat)] {
                arrow.addLine(to: p(x, y))
            }
            arrow.closeSubpath()
            canvas.fill(arrow, with: .color(CursorView.yellow))
            canvas.stroke(arrow, with: .color(Color(white: 0.1)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            // The eyes sit where the arrow is widest, and move with the mood.
            EyeDrawing.draw(canvas, centres: [p(80, 330), p(196, 330)], radius: 50 * scale, look: look, blink: blink)
        }
    }
}

private struct Pulse: View {
    @State private var big = false

    var body: some View {
        Circle()
            .strokeBorder(CursorView.yellow, lineWidth: 3)
            .frame(width: 46, height: 46)
            .scaleEffect(big ? 1.3 : 0.85)
            .opacity(big ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { big = true }
            }
    }
}

/// The window for the cursor: one screen, click-through, above other apps.
@MainActor
final class BrahCursor {
    private let model = CursorModel()
    private var panel: NSPanel?
    private var frame: CGRect = .zero

    /// The eyes. Nil: the cursor's own looks (where it flies, then at the target).
    var mood: Mood? {
        get { model.mood }
        set { model.mood = newValue }
    }

    /// Fly to `point`, in top-left points of the screen `screenFrame` (AppKit coordinates).
    /// The flight starts where Brah's cursor is, or at the user's pointer.
    func show(at point: CGPoint, label: String, on screenFrame: CGRect) {
        let start: CGPoint
        if let panel, panel.isVisible, frame == screenFrame, model.visible {
            start = model.position
        } else {
            let mouse = NSEvent.mouseLocation
            start = NSMouseInRect(mouse, screenFrame, false)
                ? CGPoint(x: mouse.x - screenFrame.minX, y: screenFrame.maxY - mouse.y)
                : CGPoint(x: point.x - 160, y: point.y + 120)
        }
        open(on: screenFrame)
        model.fly(from: start, to: point, label: label)
    }

    func hide() {
        model.stop()
        panel?.orderOut(nil)
    }

    private func open(on screenFrame: CGRect) {
        if let panel, frame == screenFrame {
            panel.orderFrontRegardless()
            return
        }
        panel?.orderOut(nil)
        let panel = NSPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: CursorView(model: model))
        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        frame = screenFrame
    }
}
