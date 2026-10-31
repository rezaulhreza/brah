import AppKit
import BrahCore
import SwiftUI

/// Marks drawn on the screen by hand, one after the other: ovals, boxes, underlines, arrows, lines.
@MainActor
final class ScreenMarks {
    private var panel: NSPanel?
    private var expiry: DispatchWorkItem?

    func show(_ marks: [Mark], on snapshot: Snapshot) {
        hide()
        guard !marks.isEmpty else { return }
        let panel = NSPanel(contentRect: snapshot.screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let scale = CGFloat(snapshot.scale)
        panel.contentView = NSHostingView(rootView: MarksView(marks: marks.map { DrawnMark($0, scale: scale) }))
        panel.setFrame(snapshot.screenFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        let expiry = DispatchWorkItem { [weak self] in self?.hide() }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: expiry)
    }

    func hide() {
        expiry?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A mark in view points, with its own small wobble so it looks drawn, not rendered.
struct DrawnMark {
    let shape: Mark.Shape
    let points: [CGPoint]
    let label: String
    let seed: Double

    init(_ mark: Mark, scale: CGFloat) {
        let n = mark.numbers.map { CGFloat($0) / scale }
        shape = mark.shape
        label = mark.label
        seed = mark.numbers.reduce(0, +).truncatingRemainder(dividingBy: 97)
        switch mark.shape {
        case .circle, .box: points = [CGPoint(x: n[0], y: n[1]), CGPoint(x: n[0] + n[2], y: n[1] + n[3])]
        case .underline: points = [CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[1])]
        case .arrow, .line: points = stride(from: 0, to: n.count - 1, by: 2).map { CGPoint(x: n[$0], y: n[$0 + 1]) }
        }
    }

    var labelAnchor: CGPoint {
        switch shape {
        case .circle, .box: CGPoint(x: points[0].x, y: points[0].y - 30)
        case .underline: CGPoint(x: points[0].x, y: points[0].y + 10)
        case .arrow, .line: CGPoint(x: points[0].x, y: points[0].y + 8)
        }
    }

    func wobble(_ i: Double) -> CGFloat { CGFloat(sin(seed * 1.7 + i * 2.3) + 0.5 * sin(seed * 0.9 + i * 5.1)) }

    var path: Path {
        var path = Path()
        switch shape {
        case .circle:
            let rect = CGRect(x: points[0].x, y: points[0].y, width: points[1].x - points[0].x, height: points[1].y - points[0].y)
                .insetBy(dx: -12, dy: -10)
            let start = -2.4 + 0.3 * Double(wobble(0))
            let steps = 72
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let angle = start + t * 2 * .pi * 1.1
                let grow = 1 + 0.06 * t + 0.025 * Double(wobble(t * 3))
                let point = CGPoint(x: rect.midX + rect.width / 2 * CGFloat(cos(angle) * grow),
                                    y: rect.midY + rect.height / 2 * CGFloat(sin(angle) * grow))
                step == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        case .box:
            let rect = CGRect(x: points[0].x, y: points[0].y, width: points[1].x - points[0].x, height: points[1].y - points[0].y)
                .insetBy(dx: -8, dy: -6)
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                           CGPoint(x: rect.minX, y: rect.minY - 4)]
            path.move(to: corners[0])
            for (i, corner) in corners.dropFirst().enumerated() {
                let from = corners[i]
                let bow = 3 * wobble(Double(i))
                path.addQuadCurve(to: corner, control: CGPoint(x: (from.x + corner.x) / 2 + bow, y: (from.y + corner.y) / 2 - bow))
            }
        case .underline:
            let (a, b) = (points[0], points[1])
            path.move(to: CGPoint(x: a.x - 4, y: a.y + 2 * wobble(1)))
            path.addQuadCurve(to: CGPoint(x: b.x + 6, y: b.y - 3),
                              control: CGPoint(x: (a.x + b.x) / 2, y: a.y + 4 + 2 * wobble(2)))
        case .arrow:
            let (tail, tip) = (points[0], points[1])
            let dx = tip.x - tail.x, dy = tip.y - tail.y
            let length = max(hypot(dx, dy), 1)
            let bend = 0.08 * length * (wobble(1) >= 0 ? 1 : -1)
            path.move(to: tail)
            path.addQuadCurve(to: tip, control: CGPoint(x: (tail.x + tip.x) / 2 - dy / length * bend,
                                                       y: (tail.y + tip.y) / 2 + dx / length * bend))
            let angle = atan2(dy, dx)
            for side in [-1.0, 1.0] {
                let wing = angle + .pi + side * 0.5
                path.move(to: tip)
                path.addLine(to: CGPoint(x: tip.x + 16 * cos(wing), y: tip.y + 16 * sin(wing)))
            }
        case .line:
            path.move(to: points[0])
            for i in 1..<points.count {
                let (from, to) = (points[i - 1], points[i])
                path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2 + 3 * wobble(Double(i)),
                                                          y: (from.y + to.y) / 2 - 3 * wobble(Double(i) + 0.5)))
            }
        }
        return path
    }
}

private struct MarkShape: Shape {
    let mark: DrawnMark
    func path(in rect: CGRect) -> Path { mark.path }
}

private struct MarksView: View {
    let marks: [DrawnMark]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(marks.indices, id: \.self) { index in
                DrawnMarkView(mark: marks[index], delay: Double(index) * 0.35)
            }
        }
    }
}

private struct DrawnMarkView: View {
    static let yellow = Color(red: 1, green: 0.77, blue: 0.19)
    let mark: DrawnMark
    let delay: Double
    @State private var drawn: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarkShape(mark: mark).trim(from: 0, to: drawn)
                .stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            MarkShape(mark: mark).trim(from: 0, to: drawn)
                .stroke(Self.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if !mark.label.isEmpty {
                Text(mark.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.1))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Self.yellow, in: Capsule())
                    .fixedSize()
                    .offset(x: mark.labelAnchor.x, y: mark.labelAnchor.y)
                    .opacity(drawn)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(delay)) { drawn = 1 }
        }
    }
}
