import AppKit
import SwiftUI

/// Demo mode, for screenshots: `Brah --demo answer`. Brah draws a made-up app with made-up data,
/// a cursor, and its own windows on top, so a picture shows nothing of the real screen. The
/// line `demo frame x y w h` (points, origin top-left) tells scripts/screenshots.sh what to capture.
enum DemoState: String, CaseIterable {
    case listening, typing, thinking, answer, guide, done, approval, handsfree, settings
}

private enum Stage {
    static let size = CGSize(width: 1280, height: 800)
    /// The fake app window inside the stage.
    static let app = CGRect(x: 120, y: 70, width: 1040, height: 640)
    static let titleBar: CGFloat = 40
    static let toolbar: CGFloat = 52
    /// Where the user's (drawn) cursor is, in stage points from the top left.
    static let cursor = CGPoint(x: 470, y: 330)
    /// The Export button, the place Brah points at.
    static let export = CGPoint(x: app.maxX - 16 - 46, y: app.minY + titleBar + toolbar / 2)
}

private struct Bill: Identifiable {
    let id = UUID()
    let item: String
    let owner: String
    let due: String
    let amount: String
}

private let bills = [
    Bill(item: "Studio rent", owner: "Ava Thompson", due: "1 Oct", amount: "£1,250.00"),
    Bill(item: "Camera insurance", owner: "Leo Park", due: "4 Oct", amount: "£86.40"),
    Bill(item: "Design software", owner: "Mia Chen", due: "9 Oct", amount: "£54.99"),
    Bill(item: "Train tickets", owner: "Sam Okafor", due: "12 Oct", amount: "£212.10"),
    Bill(item: "Client lunch", owner: "Ava Thompson", due: "15 Oct", amount: "£67.80"),
    Bill(item: "Cloud storage", owner: "Leo Park", due: "18 Oct", amount: "£9.99"),
    Bill(item: "Freelance edit", owner: "Noor Haddad", due: "22 Oct", amount: "£480.00"),
    Bill(item: "Printer ink", owner: "Mia Chen", due: "26 Oct", amount: "£38.25"),
    Bill(item: "Coworking day passes", owner: "Sam Okafor", due: "29 Oct", amount: "£120.00"),
]

/// A plain ledger app with fake bills. It is not any real product.
private struct FakeLedger: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
                Spacer()
                Text("Q3 Budget").font(.system(size: 13, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 14)
            .frame(height: Stage.titleBar)

            HStack(spacing: 8) {
                tool("line.3.horizontal.decrease", "Filter")
                tool("arrow.up.arrow.down", "Sort")
                Spacer()
                tool("square.and.arrow.up", "Share")
                tool("arrow.down.doc", "Export").frame(width: 92)
            }
            .padding(.horizontal, 16)
            .frame(height: Stage.toolbar)
            Divider()

            HStack {
                column("Item", width: 360)
                column("Owner", width: 260)
                column("Due", width: 160)
                Spacer()
                Text("Amount").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(height: 34)
            Divider()

            ForEach(Array(bills.enumerated()), id: \.element.id) { index, bill in
                HStack {
                    Text(bill.item).frame(width: 360, alignment: .leading)
                    Text(bill.owner).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
                    Text(bill.due).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
                    Spacer()
                    Text(bill.amount).monospacedDigit()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 20)
                .frame(height: 40)
                .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.03) : .clear)
            }
            Spacer()
            Divider()
            HStack {
                Text("9 bills").foregroundStyle(.secondary)
                Spacer()
                Text("Total £2,319.53").fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 20)
            .frame(height: 44)
        }
        .frame(width: Stage.app.width, height: Stage.app.height)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
    }

    private func tool(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }

    private func column(_ title: String, width: CGFloat) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: width, alignment: .leading)
    }
}

/// The whole scene: a flat backdrop, the fake app, and the user's cursor.
private struct StageView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.19, green: 0.27, blue: 0.33)
            FakeLedger().offset(x: Stage.app.minX, y: Stage.app.minY)
            if let cursor = NSCursor.arrow.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                Image(decorative: cursor, scale: 2)
                    .offset(x: Stage.cursor.x - 4, y: Stage.cursor.y - 4)
            }
        }
        .frame(width: Stage.size.width, height: Stage.size.height)
    }
}

extension AppDelegate {
    /// Show one state over the fake app and log the frame to capture.
    func runDemo(_ name: String) {
        guard let state = DemoState(rawValue: name) else {
            log("demo states: \(DemoState.allCases.map(\.rawValue).joined(separator: ", "))")
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.frame
        let frame = CGRect(x: visible.midX - Stage.size.width / 2, y: visible.midY - Stage.size.height / 2,
                           width: Stage.size.width, height: Stage.size.height)

        if state == .settings {
            settingsWindow.show(demo: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.log("demo window \(self?.settingsWindow.windowNumber ?? 0)")
            }
            return
        }

        let stage = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        stage.level = .floating
        stage.hasShadow = false
        stage.contentView = NSHostingView(rootView: StageView())
        stage.orderFrontRegardless()
        demoStage = stage

        AudioIO.shared.demoLevels = true
        let model = bubble.model
        let mouse = CGPoint(x: frame.minX + Stage.cursor.x, y: frame.maxY - Stage.cursor.y)
        model.agentName = "Hermes"
        model.muted = false
        model.handsFree = false
        model.step = nil
        model.guideStep = nil
        model.celebrating = false

        switch state {
        case .listening:
            bubble.show(near: mouse, phase: .listening, typing: false)
            model.question = "How do I export this as a PDF?"
        case .typing:
            bubble.show(near: mouse, phase: .asking, typing: true)
            model.question = "Which bill is the biggest this month?"
        case .thinking:
            bubble.show(near: mouse, phase: .thinking, typing: false)
            model.question = "Export it as a PDF to my Desktop."
            model.step = "Clicking Export"
        case .answer:
            bubble.show(near: mouse, phase: .answer("Use the Export button at the top right, then choose PDF."), typing: false)
            cursor.show(at: Stage.export, label: "Export", on: frame)
        case .guide:
            bubble.show(near: mouse, phase: .answer("Click Export, at the top right."), typing: false)
            model.guideStep = 1
            cursor.show(at: Stage.export, label: "Export", on: frame)
        case .done:
            bubble.show(near: mouse, phase: .answer("Done. Q3 Budget.pdf is on your Desktop."), typing: false)
            model.celebrating = true
        case .approval:
            bubble.show(near: mouse, phase: .approval("I'll export Q3 Budget as a PDF to your Desktop."), typing: false)
        case .handsfree:
            bubble.show(near: mouse, phase: .listening, typing: false)
            model.handsFree = true
            model.question = "Who paid for the studio rent?"
        case .settings:
            break
        }
        // The stage came first, so the bubble is above it; the pointer has a higher level.
        bubble.bringToFront()

        let top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - frame.maxY
        log("demo frame \(Int(frame.minX)) \(Int(top)) \(Int(frame.width)) \(Int(frame.height))")
    }
}
