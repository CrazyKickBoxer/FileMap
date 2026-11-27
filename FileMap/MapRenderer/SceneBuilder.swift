import CoreGraphics
import Foundation

/// Culls and simplifies a laid-out scene into a `RenderFrame` for the current camera.
///
/// Traversal is top-down and prunes whole branches whose bounds are off screen, so cost is
/// proportional to what is visible, not to the size of the tree. Branches smaller than a few
/// pixels are drawn as a single band instead of thousands of sub-pixel boxes.
enum SceneBuilder {
    static let bandThreshold: CGFloat = 4

    static func build(scene: MapScene, camera: Camera, viewSize: CGSize, state: RenderState, time: Date) -> RenderFrame {
        var frame = RenderFrame(level: DetailLevel(scale: camera.scale), scale: camera.scale, viewSize: viewSize, style: scene.style)
        frame.marquee = state.marquee
        guard !scene.nodes.isEmpty, viewSize.width > 0 else { return frame }
        let scale = camera.scale
        let margin = 40 / scale
        let visible = camera.visibleRect(in: viewSize).insetBy(dx: -margin, dy: -margin)
        let t = CGFloat(state.transition?.progress(at: time) ?? 1)
        let transition = (state.transition != nil && t < 1) ? state.transition : nil
        let pulseKey = state.pulse?.key
        let pulseProgress = state.pulse.map { CGFloat($0.progress(at: time)) }

        func worldRect(_ n: SceneNode) -> CGRect {
            guard let transition else { return n.rect }
            if let old = transition.from[n.key] { return old.lerp(to: n.rect, t) }
            if let origin = transition.appearFrom[n.key] { return origin.lerp(to: n.rect, t) }
            return n.rect
        }
        func alpha(_ n: SceneNode) -> CGFloat {
            guard let transition, transition.from[n.key] == nil else { return 1 }
            return t
        }

        frame.boxes.reserveCapacity(512)
        var stack = scene.roots
        while let i = stack.popLast() {
            let n = scene.nodes[Int(i)]
            let r = worldRect(n)
            var b = n.bounds
            if transition != nil { b = b.union(r).union(transition?.from[n.key] ?? r) }
            guard b.intersects(visible) else { continue }

            if scene.style == .tree, !n.children.isEmpty, transition == nil, b.height * scale < bandThreshold {
                // Whole branch is a sliver: draw the node and one band for everything below it.
                if r.intersects(visible) { frame.boxes.append(box(n, rect: r, camera: camera, viewSize: viewSize, frame: frame, state: state)) }
                let below = CGRect(x: r.maxX, y: b.minY, width: max(0, b.maxX - r.maxX), height: b.height)
                frame.bands.append(camera.toScreen(below, in: viewSize))
                continue
            }

            if r.intersects(visible) {
                var item = box(n, rect: r, camera: camera, viewSize: viewSize, frame: frame, state: state)
                item.alpha = alpha(n)
                if n.key == pulseKey, let pulseProgress, pulseProgress < 1 { item.pulse = pulseProgress }
                frame.boxes.append(item)
            }

            if scene.style == .tree {
                for c in n.children {
                    let child = scene.nodes[Int(c)]
                    let cr = worldRect(child)
                    let from = CGPoint(x: r.maxX, y: r.midY)
                    let to = CGPoint(x: cr.minX, y: cr.midY)
                    let edgeBox = CGRect(x: from.x, y: min(from.y, to.y), width: to.x - from.x, height: abs(to.y - from.y))
                    guard edgeBox.insetBy(dx: -1, dy: -1).intersects(visible) else { continue }
                    let highlighted = state.highlightPath.contains(n.key) && state.highlightPath.contains(child.key)
                    frame.edges.append(EdgeItem(from: camera.toScreen(from, in: viewSize), to: camera.toScreen(to, in: viewSize),
                                                highlighted: highlighted, alpha: alpha(child)))
                }
            }
            stack.append(contentsOf: n.children.reversed())
        }

        // Boxes that are leaving fade out while sliding towards their parent.
        if let transition {
            for ghost in transition.ghosts {
                let r = ghost.from.lerp(to: ghost.to, t)
                guard r.intersects(visible) else { continue }
                var item = BoxItem(key: ghost.key, rect: camera.toScreen(r, in: viewSize), display: ghost.display)
                item.alpha = 1 - t
                frame.boxes.append(item)
            }
        }
        return frame
    }

    private static func box(_ n: SceneNode, rect: CGRect, camera: Camera, viewSize: CGSize, frame: RenderFrame, state: RenderState) -> BoxItem {
        let screen = camera.toScreen(rect, in: viewSize)
        var item = BoxItem(key: n.key, rect: screen, display: n.display)
        item.selected = state.selection.contains(n.key)
        item.focused = state.focus == n.key
        item.dropTarget = state.dropTarget == n.key
        item.onPath = state.highlightPath.contains(n.key)
        item.text = textLevel(for: n.display, screen: screen, level: frame.level, scale: camera.scale)
        return item
    }

    static func textLevel(for d: NodeDisplay, screen: CGRect, level: DetailLevel, scale: CGFloat) -> TextLevel {
        if d.role == .cluster {
            // Cluster titles stay readable at any zoom (drawn above the region when it's small).
            return screen.width >= 70 ? .titleSubtitle : .none
        }
        if d.isContainer {
            // Group headers stay readable whenever the header is big enough.
            let header = min(screen.height, NestedGridLayout.Spacing().header * scale)
            if screen.width < 60 || header < 14 { return .none }
            return screen.width > 160 ? .titleSubtitle : .title
        }
        let h = CanvasDrawing.labelRect(screen, scale: scale).height
        if h < 15 || screen.width < 50 { return .none }
        switch level {
        case .far:
            return .none
        case .mid:
            switch d.role {
            case .root, .folder, .more: return h >= 30 ? .titleSubtitle : .title
            case .file, .package: return h >= 18 ? .title : .none
            case .cluster, .group: return .titleSubtitle
            }
        case .near:
            return h >= 30 ? .full : .title
        }
    }
}
