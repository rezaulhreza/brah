import AppKit
import BruhCore
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noScreen
    case noPermission

    var errorDescription: String? {
        switch self {
        case .noScreen: return "Bruh could not find the screen under the cursor."
        case .noPermission:
            return "Bruh needs Screen Recording. Open System Settings > Privacy & Security > Screen Recording, turn on Bruh, then open Bruh again."
        }
    }
}

/// Takes the screenshot the agent sees: the display under the cursor, without Bruh's own windows,
/// with a red ring where the cursor is.
@MainActor
enum Capture {
    /// Wider screenshots cost tokens and do not help the agent read the screen.
    static let maxWidth = 1600.0

    static func snapshot() async throws -> Snapshot {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw CaptureError.noScreen }

        let front = NSWorkspace.shared.frontmostApplication
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noPermission
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noScreen }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let frame = screen.frame
        let scale = min(1.0, maxWidth / frame.width)
        let config = SCStreamConfiguration()
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let cursor = Snapshot.imagePoint(mouse: mouse, frame: frame, scale: scale)
        let size = CGSize(width: image.width, height: image.height)

        return Snapshot(jpeg: jpeg(marking(image, at: cursor)), imageSize: size, screenFrame: frame, scale: scale,
                        cursor: cursor, appName: front?.localizedName, windowTitle: front.flatMap { title(of: $0.processIdentifier) })
    }

    /// The title of the front window of `pid`. The window list is ordered front to back.
    private static func title(of pid: pid_t) -> String? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let window = list?.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        return window?[kCGWindowName as String] as? String
    }

    private static func marking(_ image: CGImage, at cursor: CGPoint) -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }

        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.15, alpha: 1))
        context.setLineWidth(3)
        let y = rect.height - cursor.y // CGContext is bottom-left
        context.strokeEllipse(in: CGRect(x: cursor.x - 14, y: y - 14, width: 28, height: 28))
        return context.makeImage() ?? image
    }

    private static func jpeg(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) ?? Data()
    }
}
