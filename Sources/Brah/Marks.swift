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
        let drawn = marks.map { DrawnMark($0, scale: scale) }
        panel.contentView = NSHostingView(rootView: MarksView(marks: drawn.filter { $0.shape == .spotlight } + drawn.filter { $0.shape != .spotlight }))
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
        number = mark.shape == .number ? Int(mark.numbers[2]) : 0
        switch mark.shape {
        case .circle, .box, .highlight, .cross, .spotlight: points = [CGPoint(x: n[0], y: n[1]), CGPoint(x: n[0] + n[2], y: n[1] + n[3])]
        case .underline: points = [CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[1])]
        case .tick, .number: points = [CGPoint(x: n[0], y: n[1])]
        case .arrow, .line: points = stride(from: 0, to: n.count - 1, by: 2).map { CGPoint(x: n[$0], y: n[$0 + 1]) }
        }
    }

    let number: Int
    var rect: CGRect {
        CGRect(x: points[0].x, y: points[0].y, width: points.last!.x - points[0].x, height: points.last!.y - points[0].y)
    }

    var labelAnchor: CGPoint {
        switch shape {
        case .circle, .box, .highlight, .cross, .spotlight: CGPoint(x: points[0].x, y: points[0].y - 30)
        case .underline: CGPoint(x: points[0].x, y: points[0].y + 10)
        case .tick, .number: CGPoint(x: points[0].x + 22, y: points[0].y - 12)
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
        case .highlight:
            let rect = rect
            path.move(to: CGPoint(x: rect.minX - 4, y: rect.midY + wobble(1)))
            path.addLine(to: CGPoint(x: rect.maxX + 6, y: rect.midY - 1.5 * wobble(2)))
        case .cross:
            let rect = rect.insetBy(dx: -4, dy: -4)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + 2 * wobble(1)))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX + 2 * wobble(2), y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY + 2 * wobble(3)))
        case .tick:
            let p = points[0]
            path.move(to: CGPoint(x: p.x - 13, y: p.y - 1))
            path.addLine(to: CGPoint(x: p.x - 3, y: p.y + 10))
            path.addQuadCurve(to: CGPoint(x: p.x + 18, y: p.y - 18), control: CGPoint(x: p.x + 4, y: p.y - 6))
        case .number, .spotlight:
            break
        case .line:
            path.move(to: points[0])
            if points.count == 2 {
                // A straight stroke gets the small wobble of a hand.
                let (from, to) = (points[0], points[1])
                path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2 + 3 * wobble(1), y: (from.y + to.y) / 2 - 3 * wobble(1.5)))
            } else {
                // Three points or more: one smooth curve through all of them (Catmull-Rom).
                for i in 0..<points.count - 1 {
                    let (before, from, to, after) = (points[max(i - 1, 0)], points[i], points[i + 1], points[min(i + 2, points.count - 1)])
                    path.addCurve(to: to,
                                  control1: CGPoint(x: from.x + (to.x - before.x) / 6, y: from.y + (to.y - before.y) / 6),
                                  control2: CGPoint(x: to.x - (after.x - from.x) / 6, y: to.y - (after.y - from.y) / 6))
                }
            }
        }
        return path
    }
}

private struct Spotlight: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14))
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

    private var color: Color {
        switch mark.shape {
        case .tick: Color(red: 0.2, green: 0.78, blue: 0.4)
        case .cross: Color(red: 0.95, green: 0.32, blue: 0.27)
        default: Self.yellow
        }
    }
    @State private var drawn: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch mark.shape {
            case .spotlight:
                Spotlight(hole: mark.rect.insetBy(dx: -12, dy: -12))
                    .fill(Color.black.opacity(0.45 * drawn), style: FillStyle(eoFill: true))
            case .number:
                Text("\(mark.number)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.1))
                    .frame(width: 30, height: 30)
                    .background(Self.yellow, in: Circle())
                    .overlay(Circle().strokeBorder(Color(white: 0.1), lineWidth: 2))
                    .scaleEffect(drawn)
                    .offset(x: mark.points[0].x - 15, y: mark.points[0].y - 15)
            case .highlight:
                MarkShape(mark: mark).trim(from: 0, to: drawn)
                    .stroke(Self.yellow.opacity(0.42), style: StrokeStyle(lineWidth: mark.rect.height + 8, lineCap: .butt))
            default:
                MarkShape(mark: mark).trim(from: 0, to: drawn)
                    .stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                MarkShape(mark: mark).trim(from: 0, to: drawn)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if !mark.label.isEmpty {
                Text(mark.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.1))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color, in: Capsule())
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
