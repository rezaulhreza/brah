import SwiftUI

/// How Brah feels, which is how its eyes look.
enum Mood: Equatable {
    /// The side-eye of the icon, drifting a little.
    case idle
    /// Wide open, looking at you.
    case listening
    /// Up, drifting from side to side.
    case thinking
    /// Relaxed, looking ahead.
    case speaking
    /// Looking along a direction (x right, y down).
    case looking(CGVector)
    /// Scanning, while the agent works on the screen.
    case working
    /// Wide open: it waits for your yes.
    case asking
    /// The flat "bruh" side-eye.
    case unimpressed
    /// Happy closed arcs.
    case happy
}

/// One frame of the eyes: how far the lids are down (0 open, 1 shut), where the pupils look
/// (each part -1...1), and whether they are happy arcs.
struct EyeLook {
    var lid: Double
    var lookX: Double
    var lookY: Double
    var happy: Bool

    static func of(_ mood: Mood, at time: Double) -> EyeLook {
        switch mood {
        case .idle: return EyeLook(lid: 0.5, lookX: 0.75 + 0.15 * sin(time * 0.7), lookY: 0.25, happy: false)
        case .listening: return EyeLook(lid: 0.05, lookX: 0.1 * sin(time * 0.9), lookY: 0.3, happy: false)
        case .thinking: return EyeLook(lid: 0.25, lookX: 0.6 * sin(time * 1.1), lookY: -0.7, happy: false)
        case .speaking: return EyeLook(lid: 0.2, lookX: 0.2 * sin(time * 1.3), lookY: 0.1, happy: false)
        case .looking(let direction):
            let length = max(0.001, (direction.dx * direction.dx + direction.dy * direction.dy).squareRoot())
            return EyeLook(lid: 0.15, lookX: direction.dx / length, lookY: direction.dy / length, happy: false)
        case .working: return EyeLook(lid: 0.3, lookX: 0.85 * sin(time * 2.4), lookY: 0.2, happy: false)
        case .asking: return EyeLook(lid: 0.08, lookX: 0, lookY: 0.25, happy: false)
        case .unimpressed: return EyeLook(lid: 0.58, lookX: 0.95, lookY: 0, happy: false)
        case .happy: return EyeLook(lid: 0, lookX: 0, lookY: 0, happy: true)
        }
    }

    /// A blink every few seconds, at a time that looks random but is the same on every redraw.
    static func blink(at time: Double) -> Double {
        let period = 4.3
        let cycle = (time / period).rounded(.down)
        let noise = sin(cycle * 12.9898) * 43_758.5453
        let start = (noise - noise.rounded(.down)) * (period - 0.4)
        let into = time - cycle * period - start
        guard into > 0, into < 0.16 else { return 0 }
        return sin(into / 0.16 * .pi)
    }
}

/// Moves the eyes smoothly from one mood to the next. A class, so a redraw can step it.
final class EyeMotion {
    private var current: EyeLook?

    func step(to target: EyeLook) -> EyeLook {
        guard var now = current, now.happy == target.happy else {
            current = target
            return target
        }
        let rate = 0.18
        now.lid += (target.lid - now.lid) * rate
        now.lookX += (target.lookX - now.lookX) * rate
        now.lookY += (target.lookY - now.lookY) * rate
        current = now
        return now
    }
}

enum EyeDrawing {
    static let ink = Color(white: 0.1)

    /// Two eyes at `centres`, each `radius` big.
    static func draw(_ canvas: GraphicsContext, centres: [CGPoint], radius r: CGFloat, look: EyeLook, blink: Double) {
        for centre in centres {
            let eye = CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
            if look.happy {
                var arc = Path()
                arc.addArc(center: CGPoint(x: centre.x, y: centre.y + r * 0.35), radius: r * 0.8,
                           startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                canvas.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: max(1.2, r * 0.38), lineCap: .round))
                continue
            }
            canvas.fill(Path(ellipseIn: eye), with: .color(.white))
            var inside = canvas
            inside.clip(to: Path(ellipseIn: eye))
            let pupil = r * 0.46
            let at = CGPoint(x: centre.x + CGFloat(look.lookX) * r * 0.45, y: centre.y + CGFloat(look.lookY) * r * 0.4)
            inside.fill(Path(ellipseIn: CGRect(x: at.x - pupil, y: at.y - pupil, width: 2 * pupil, height: 2 * pupil)), with: .color(ink))
            let lid = min(1, look.lid + blink)
            inside.fill(Path(CGRect(x: eye.minX, y: eye.minY, width: eye.width, height: eye.height * lid)), with: .color(ink))
            canvas.stroke(Path(ellipseIn: eye), with: .color(ink), lineWidth: max(1, r * 0.22))
        }
    }
}

/// Brah's face for the bubble: the yellow tile of the app icon with live eyes. The tile keeps
/// the eyes readable on a light and on a dark bubble.
struct BrahFace: View {
    let mood: Mood

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(red: 1, green: 0.77, blue: 0.19))
            .frame(width: 24, height: 24)
            .overlay(Eyes(mood: mood, width: 17).offset(y: 1))
            .help("Brah")
    }
}

/// Brah's two eyes.
struct Eyes: View {
    let mood: Mood
    var width: CGFloat = 22
    @State private var motion = EyeMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                let look = motion.step(to: EyeLook.of(mood, at: time))
                let r = size.height / 2 - 0.5
                EyeDrawing.draw(canvas, centres: [CGPoint(x: r + 0.5, y: size.height / 2), CGPoint(x: size.width - r - 0.5, y: size.height / 2)],
                                radius: r, look: look, blink: look.happy ? 0 : EyeLook.blink(at: time))
            }
        }
        .frame(width: width, height: width * 0.45)
        .accessibilityHidden(true)
    }
}
