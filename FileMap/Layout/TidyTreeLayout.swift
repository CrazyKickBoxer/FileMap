import CoreGraphics
import Foundation

/// Left-to-right tidy tree (Reingold–Tilford style, with per-level contours).
///
/// Each subtree is laid out on its own; siblings are then pushed apart just far enough that
/// their contours never overlap at any depth, and parents are centred on their children.
/// Columns are fixed per depth, so boxes in different columns can never collide.
enum TidyTreeLayout {
    struct Spacing: Sendable {
        var columnGap: CGFloat = 96
        var siblingGap: CGFloat = 10
        var rootGap: CGFloat = 60
    }

    private struct Contour {
        var tops: [CGFloat]
        var bottoms: [CGFloat]
    }

    static func layout(_ input: LayoutInput, spacing: Spacing = Spacing()) -> MapScene {
        let count = input.entries.count
        guard count > 0 else { return .empty }

        // Depth of every entry and the widest box per column.
        var depth = [Int16](repeating: 0, count: count)
        var parent = [Int32](repeating: -1, count: count)
        var columnWidth: [CGFloat] = []
        var order: [Int32] = []
        order.reserveCapacity(count)
        var queue = input.roots
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            order.append(i)
            let d = Int(depth[Int(i)])
            if columnWidth.count <= d { columnWidth.append(0) }
            columnWidth[d] = max(columnWidth[d], input.entries[Int(i)].size.width)
            for c in input.entries[Int(i)].children {
                depth[Int(c)] = depth[Int(i)] + 1
                parent[Int(c)] = i
                queue.append(c)
            }
        }
        var columnX = [CGFloat](repeating: 0, count: columnWidth.count)
        for d in 1..<max(1, columnWidth.count) { columnX[d] = columnX[d - 1] + columnWidth[d - 1] + spacing.columnGap }

        // Relative y of each entry's top, measured from its parent's top.
        var relY = [CGFloat](repeating: 0, count: count)

        func place(_ i: Int32) -> Contour {
            let entry = input.entries[Int(i)]
            let h = entry.size.height
            let kids = entry.children
            if kids.isEmpty { return Contour(tops: [0], bottoms: [h]) }
            var acc = Contour(tops: [], bottoms: [])
            var offsets = [CGFloat](repeating: 0, count: kids.count)
            for (n, c) in kids.enumerated() {
                let cc = place(c)
                if n == 0 {
                    acc = cc
                    continue
                }
                var shift = -CGFloat.infinity
                for k in 0..<min(acc.tops.count, cc.tops.count) {
                    shift = max(shift, acc.bottoms[k] + spacing.siblingGap - cc.tops[k])
                }
                offsets[n] = shift
                for k in 0..<cc.tops.count {
                    if k < acc.tops.count {
                        acc.tops[k] = min(acc.tops[k], cc.tops[k] + shift)
                        acc.bottoms[k] = max(acc.bottoms[k], cc.bottoms[k] + shift)
                    } else {
                        acc.tops.append(cc.tops[k] + shift)
                        acc.bottoms.append(cc.bottoms[k] + shift)
                    }
                }
            }
            let first = offsets[0] + input.entries[Int(kids[0])].size.height / 2
            let last = offsets[kids.count - 1] + input.entries[Int(kids[kids.count - 1])].size.height / 2
            let top = (first + last) / 2 - h / 2
            for (n, c) in kids.enumerated() { relY[Int(c)] = offsets[n] - top }
            var result = Contour(tops: [0], bottoms: [h])
            result.tops.reserveCapacity(acc.tops.count + 1)
            result.bottoms.reserveCapacity(acc.tops.count + 1)
            for k in 0..<acc.tops.count {
                result.tops.append(acc.tops[k] - top)
                result.bottoms.append(acc.bottoms[k] - top)
            }
            return result
        }

        // Stack the roots like siblings.
        var rootTop: [CGFloat] = []
        var accBottom: [CGFloat] = []
        for (n, r) in input.roots.enumerated() {
            let c = place(r)
            var shift: CGFloat = 0
            if n > 0 {
                shift = -CGFloat.infinity
                for k in 0..<min(accBottom.count, c.tops.count) { shift = max(shift, accBottom[k] + spacing.rootGap - c.tops[k]) }
                if shift == -.infinity { shift = (accBottom.max() ?? 0) + spacing.rootGap }
            }
            rootTop.append(shift)
            for k in 0..<c.bottoms.count {
                if k < accBottom.count { accBottom[k] = max(accBottom[k], c.bottoms[k] + shift) } else { accBottom.append(c.bottoms[k] + shift) }
            }
        }

        // Absolute positions (BFS order guarantees parents first).
        var y = [CGFloat](repeating: 0, count: count)
        for (n, r) in input.roots.enumerated() { y[Int(r)] = rootTop[n] }
        var nodes: [SceneNode] = []
        nodes.reserveCapacity(count)
        for i in 0..<count {
            let e = input.entries[i]
            nodes.append(SceneNode(key: e.key, rect: .zero, bounds: .zero, parent: parent[i], children: e.children,
                                   depth: depth[i], display: e.display))
        }
        for i in order {
            let p = parent[Int(i)]
            if p >= 0 { y[Int(i)] = y[Int(p)] + relY[Int(i)] }
            let e = input.entries[Int(i)]
            let rect = CGRect(x: columnX[Int(depth[Int(i)])], y: y[Int(i)], width: e.size.width, height: e.size.height)
            nodes[Int(i)].rect = rect
            nodes[Int(i)].bounds = rect
        }
        // Subtree bounds, children before parents.
        for i in order.reversed() {
            let p = parent[Int(i)]
            if p >= 0 { nodes[Int(p)].bounds = nodes[Int(p)].bounds.union(nodes[Int(i)].bounds) }
        }
        var index: [SceneKey: Int32] = [:]
        index.reserveCapacity(count)
        for i in 0..<count { index[nodes[i].key] = Int32(i) }
        let bounds = input.roots.reduce(CGRect.null) { $0.union(nodes[Int($1)].bounds) }
        return MapScene(style: .tree, nodes: nodes, roots: input.roots, index: index, bounds: bounds)
    }
}
