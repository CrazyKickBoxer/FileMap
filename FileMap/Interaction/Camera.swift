import CoreGraphics
import Foundation

/// Maps world coordinates (layout space, y down) to screen coordinates.
struct Camera: Sendable, Equatable {
    var center: CGPoint = .zero
    var scale: CGFloat = 1

    static let minScale: CGFloat = 0.0002
    static let maxScale: CGFloat = 4

    func toScreen(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - center.x) * scale + size.width / 2, y: (p.y - center.y) * scale + size.height / 2)
    }

    func toScreen(_ r: CGRect, in size: CGSize) -> CGRect {
        let o = toScreen(r.origin, in: size)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }

    func toWorld(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2) / scale + center.x, y: (p.y - size.height / 2) / scale + center.y)
    }

    func toWorld(_ r: CGRect, in size: CGSize) -> CGRect {
        let a = toWorld(r.origin, in: size)
        return CGRect(x: a.x, y: a.y, width: r.width / scale, height: r.height / scale)
    }

    func visibleRect(in size: CGSize) -> CGRect {
        toWorld(CGRect(origin: .zero, size: size), in: size)
    }

    mutating func zoom(by factor: CGFloat, around screenPoint: CGPoint, in size: CGSize) {
        let anchor = toWorld(screenPoint, in: size)
        scale = min(Self.maxScale, max(Self.minScale, scale * factor))
        // Keep the world point under the cursor fixed.
        center.x = anchor.x - (screenPoint.x - size.width / 2) / scale
        center.y = anchor.y - (screenPoint.y - size.height / 2) / scale
    }

    mutating func pan(byScreen delta: CGSize) {
        center.x -= delta.width / scale
        center.y -= delta.height / scale
    }

    static func fit(_ rect: CGRect, in size: CGSize, padding: CGFloat = 60, maxScale: CGFloat = 1.1) -> Camera {
        guard !rect.isNull, rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else {
            return Camera(center: CGPoint(x: rect.midX.isFinite ? rect.midX : 0, y: rect.midY.isFinite ? rect.midY : 0), scale: 1)
        }
        let sx = max(1, size.width - padding * 2) / rect.width
        let sy = max(1, size.height - padding * 2) / rect.height
        return Camera(center: CGPoint(x: rect.midX, y: rect.midY), scale: max(minScale, min(maxScale, min(sx, sy))))
    }
}

/// A smooth "fly" between two cameras: zooms out a little in the middle when travelling far.
struct CameraAnimation: Sendable {
    var from: Camera
    var to: Camera
    var start: Date
    var duration: Double

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(start) / duration))
    }

    func camera(at date: Date, viewSize: CGSize) -> Camera {
        let t = Ease.inOut(progress(at: date))
        var c = Camera()
        c.center.x = from.center.x + (to.center.x - from.center.x) * t
        c.center.y = from.center.y + (to.center.y - from.center.y) * t
        let logScale = log(from.scale) + (log(to.scale) - log(from.scale)) * t
        // Dip proportional to the distance travelled in screens.
        let distance = hypot(to.center.x - from.center.x, to.center.y - from.center.y) * min(from.scale, to.scale)
        let screens = distance / max(1, max(viewSize.width, viewSize.height))
        let dip = min(0.7, 0.25 * log1p(screens)) * sin(.pi * t)
        c.scale = exp(logScale) * (1 - dip)
        return c
    }
}

enum Ease {
    static func inOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func out(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}
