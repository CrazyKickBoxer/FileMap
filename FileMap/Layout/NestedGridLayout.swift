import CoreGraphics
import Foundation

/// Lays out containers holding their children in a wrapped grid ("shelf" packing).
/// Used by cluster view: clusters are large regions, sub-groups sit inside them, files inside those.
enum NestedGridLayout {
    struct Spacing: Sendable {
        var header: CGFloat = 58
        var padding: CGFloat = 16
        var gap: CGFloat = 12
        var rootGap: CGFloat = 110
    }

    static func layout(_ input: LayoutInput, spacing: Spacing = Spacing()) -> MapScene {
        let count = input.entries.count
        guard count > 0 else { return .empty }
        var size = input.entries.map(\.size)
        var relOrigin = [CGPoint](repeating: .zero, count: count)
        var parent = [Int32](repeating: -1, count: count)
        var depth = [Int16](repeating: 0, count: count)

        // Post-order so children are sized before their containers.
        var order: [Int32] = []
        var stack = input.roots.reversed().map { $0 }
        var pre: [Int32] = []
        while let i = stack.popLast() {
            pre.append(i)
            for c in input.entries[Int(i)].children {
                parent[Int(c)] = i
                depth[Int(c)] = depth[Int(i)] + 1
                stack.append(c)
            }
        }
        order = pre.reversed()

        func pack(_ kids: [Int32], gap: CGFloat, minWidth: CGFloat) -> CGSize {
            let area = kids.reduce(CGFloat(0)) { $0 + (size[Int($1)].width + gap) * (size[Int($1)].height + gap) }
            let widest = kids.reduce(CGFloat(0)) { max($0, size[Int($1)].width) }
            let target = max(minWidth, widest, sqrt(area) * 1.5)
            var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, usedW: CGFloat = 0
            for c in kids {
                let s = size[Int(c)]
                if x > 0 && x + s.width > target {
                    x = 0
                    y += rowH + gap
                    rowH = 0
                }
                relOrigin[Int(c)] = CGPoint(x: x, y: y)
                x += s.width + gap
                rowH = max(rowH, s.height)
                usedW = max(usedW, x - gap)
            }
            return CGSize(width: usedW, height: y + rowH)
        }

        for i in order {
            let kids = input.entries[Int(i)].children
            guard !kids.isEmpty else { continue }
            let content = pack(kids, gap: spacing.gap, minWidth: input.entries[Int(i)].size.width - 2 * spacing.padding)
            for c in kids {
                relOrigin[Int(c)].x += spacing.padding
                relOrigin[Int(c)].y += spacing.header
            }
            size[Int(i)] = CGSize(width: max(input.entries[Int(i)].size.width, content.width + 2 * spacing.padding),
                                  height: spacing.header + content.height + spacing.padding)
        }
        _ = pack(input.roots, gap: spacing.rootGap, minWidth: 0)

        var nodes: [SceneNode] = []
        nodes.reserveCapacity(count)
        for i in 0..<count {
            let e = input.entries[i]
            nodes.append(SceneNode(key: e.key, rect: .zero, bounds: .zero, parent: parent[i], children: e.children, depth: depth[i], display: e.display))
        }
        for i in pre {
            let p = parent[Int(i)]
            let base = p >= 0 ? nodes[Int(p)].rect.origin : .zero
            let o = relOrigin[Int(i)]
            let rect = CGRect(x: base.x + o.x, y: base.y + o.y, width: size[Int(i)].width, height: size[Int(i)].height)
            nodes[Int(i)].rect = rect
            nodes[Int(i)].bounds = rect
        }
        var index: [SceneKey: Int32] = [:]
        for i in 0..<count { index[nodes[i].key] = Int32(i) }
        let bounds = input.roots.reduce(CGRect.null) { $0.union(nodes[Int($1)].rect) }
        return MapScene(style: .nested, nodes: nodes, roots: input.roots, index: index, bounds: bounds)
    }
}
