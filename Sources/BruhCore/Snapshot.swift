import CoreGraphics
import Foundation

/// One capture of the display the user works on, and where things were at that moment.
///
/// Two spaces meet here. The screenshot is in image pixels with the origin top-left. AppKit
/// screens are in points with the origin bottom-left. `scale` is image pixels per point.
public struct Snapshot: Sendable {
    public var jpeg: Data
    public var imageSize: CGSize
    /// The frame of the captured screen in AppKit global coordinates.
    public var screenFrame: CGRect
    public var scale: Double
    /// The user's mouse cursor, in image pixels.
    public var cursor: CGPoint
    public var appName: String?
    public var windowTitle: String?

    public init(jpeg: Data, imageSize: CGSize, screenFrame: CGRect, scale: Double, cursor: CGPoint,
                appName: String?, windowTitle: String?) {
        self.jpeg = jpeg
        self.imageSize = imageSize
        self.screenFrame = screenFrame
        self.scale = scale
        self.cursor = cursor
        self.appName = appName
        self.windowTitle = windowTitle
    }

    /// A mouse location in AppKit global coordinates, as image pixels of a screen with `frame`.
    public static func imagePoint(mouse: CGPoint, frame: CGRect, scale: Double) -> CGPoint {
        CGPoint(x: (mouse.x - frame.minX) * scale, y: (frame.maxY - mouse.y) * scale)
    }

    /// An image pixel as a point in a top-left (flipped) view that covers the captured screen.
    /// Values outside the image are clamped to its edges.
    public func viewPoint(_ point: Spot) -> CGPoint {
        let x = min(max(point.x, 0), imageSize.width)
        let y = min(max(point.y, 0), imageSize.height)
        return CGPoint(x: x / scale, y: y / scale)
    }
}
