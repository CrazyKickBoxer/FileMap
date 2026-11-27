import CoreGraphics
import Foundation

/// How much detail to draw, chosen from the zoom level.
enum DetailLevel: Sendable, Comparable {
    case far, mid, near

    init(scale: CGFloat) {
        self = scale < 0.32 ? .far : scale < 0.85 ? .mid : .near
    }
}

/// How much text a box shows this frame.
enum TextLevel: Sendable, Comparable { case none, title, titleSubtitle, full }

/// One box to draw, already in screen coordinates.
struct BoxItem: Sendable {
    var key: SceneKey
    var rect: CGRect
    var display: NodeDisplay
    var alpha: CGFloat = 1
    var selected = false
    var focused = false
    var dropTarget = false
    var onPath = false
    var pulse: CGFloat?
    var text: TextLevel = .none
}

struct EdgeItem: Sendable {
    var from: CGPoint
    var to: CGPoint
    var highlighted: Bool
    var alpha: CGFloat
}

/// A renderer-agnostic list of primitives for one frame. Any backend (Canvas, Metal) draws this.
struct RenderFrame: Sendable {
    var level: DetailLevel = .far
    var scale: CGFloat = 1
    var viewSize: CGSize = .zero
    var boxes: [BoxItem] = []
    var edges: [EdgeItem] = []
    /// Collapsed summaries for branches too small to draw box by box.
    var bands: [CGRect] = []
    var marquee: CGRect?
    var style: MapScene.Style = .tree
}

/// Interaction state the scene builder needs.
struct RenderState: Sendable {
    var selection: Set<SceneKey> = []
    var focus: SceneKey?
    var dropTarget: SceneKey?
    var highlightPath: Set<SceneKey> = []
    var pulse: Pulse?
    var transition: SceneTransition?
    var marquee: CGRect?
}

struct Pulse: Sendable {
    var key: SceneKey
    var start: Date
    static let duration = 0.9

    func progress(at date: Date) -> Double { min(1, max(0, date.timeIntervalSince(start) / Self.duration)) }
}

/// Animates boxes from their old positions to new ones after a layout change.
struct SceneTransition: Sendable {
    struct Ghost: Sendable {
        var key: SceneKey
        var from: CGRect
        var to: CGRect
        var display: NodeDisplay
    }

    var from: [SceneKey: CGRect]
    /// Where new boxes grow out of (their parent's old position).
    var appearFrom: [SceneKey: CGRect]
    var ghosts: [Ghost]
    var start: Date
    var duration: Double

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 1 }
        return Ease.inOut(min(1, max(0, date.timeIntervalSince(start) / duration)))
    }
}

extension CGRect {
    func lerp(to other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: minX + (other.minX - minX) * t, y: minY + (other.minY - minY) * t,
               width: width + (other.width - width) * t, height: height + (other.height - height) * t)
    }
}
