import CoreGraphics
import Foundation

/// The parts of the tree that are loaded and expanded, captured for a layout pass.
struct TreeSnapshot: Sendable {
    var rootID: Int64
    var nodes: [Int64: Node]
    var children: [Int64: ChildPage]
    var expanded: Set<Int64>
    /// Children picked from the "+ N more" grid, shown in addition to the biggest ones.
    var promoted: [Int64: [Node]] = [:]
    var pinned: Set<Int64> = []
    var sizeMode = false
}

/// Turns loaded index data into layout input (boxes with sizes and display text).
enum TreeInputBuilder {
    static let folderSize = CGSize(width: 248, height: 54)
    static let fileSize = CGSize(width: 248, height: 38)
    static let rootSize = CGSize(width: 268, height: 64)

    private enum Pending {
        case node(Node, Int32?)
        case more(parent: Int32, parentID: Int64, display: NodeDisplay, size: CGSize)
    }

    static func build(_ s: TreeSnapshot) -> LayoutInput {
        var input = LayoutInput()
        guard let root = s.nodes[s.rootID] else { return input }
        let rootAlloc = max(1, root.allocSize)
        var stack: [Pending] = [.node(root, nil)]
        while let item = stack.popLast() {
            switch item {
            case let .more(parent, parentID, display, size):
                input.add(.init(key: .more(parentID), size: size, display: display), parent: parent)
            case let .node(node, parentIndex):
                let expanded = node.isFolder && s.expanded.contains(node.id)
                let display = display(for: node, isRoot: parentIndex == nil, expanded: expanded, pinned: s.pinned.contains(node.id))
                let size = size(for: node, isRoot: parentIndex == nil, sizeMode: s.sizeMode, rootAlloc: rootAlloc)
                let index = input.add(.init(key: .node(node.id), size: size, display: display), parent: parentIndex)
                guard expanded, let page = s.children[node.id] else { continue }
                var kids = page.nodes
                if let extra = s.promoted[node.id], !extra.isEmpty {
                    let have = Set(kids.map(\.id))
                    kids = NodeQueries.sortForDisplay(kids + extra.filter { !have.contains($0.id) })
                }
                // Stack order: the "+ more" box is pushed first so it pops (and is added) last.
                let hiddenCount = page.total - kids.count
                if hiddenCount > 0 {
                    let more = NodeDisplay(
                        role: .more, title: "+ \(Format.count(Int64(hiddenCount))) more",
                        subtitle: "Show all \(Format.count(Int64(page.total)))", modifiedAt: nil, glyph: GlyphTable.more, kind: .other)
                    let moreSize = s.sizeMode ? CGSize(width: fileSize.width, height: 30) : fileSize
                    stack.append(.more(parent: index, parentID: node.id, display: more, size: moreSize))
                }
                for child in kids.reversed() {
                    stack.append(.node(s.nodes[child.id] ?? child, index))
                }
            }
        }
        return input
    }

    static func display(for node: Node, isRoot: Bool, expanded: Bool, pinned: Bool) -> NodeDisplay {
        let role: NodeDisplay.Role = isRoot ? .root : node.isFolder ? .folder : node.isPackage ? .package : .file
        var flags: NodeDisplay.Flags = []
        if expanded { flags.insert(.expanded) }
        if node.isFolder && node.itemCount > 0 { flags.insert(.hasChildren) }
        if node.isSystem { flags.insert(.dimmed) }
        if pinned { flags.insert(.pinned) }
        if !node.hasAccess { flags.insert(.noAccess) }
        if node.isLink { flags.insert(.link) }
        if node.isHidden { flags.insert(.hidden) }
        let subtitle: String
        if node.isFolder {
            subtitle = node.hasAccess ? "\(Format.bytes(node.size)) · \(Format.items(node.itemCount))" : "No access"
        } else {
            subtitle = Format.bytes(node.size)
        }
        let glyph = isRoot ? GlyphTable.volume
            : GlyphTable.glyph(name: node.name, uti: node.uti, kind: node.kind, isFolder: node.isFolder, expanded: expanded)
        return NodeDisplay(role: role, title: node.name, subtitle: subtitle, modifiedAt: node.modifiedAt,
                           glyph: glyph, kind: node.isFolder ? .folder : node.kind, flags: flags)
    }

    static func size(for node: Node, isRoot: Bool, sizeMode: Bool, rootAlloc: Int64) -> CGSize {
        let base = isRoot ? rootSize : node.isFolder ? folderSize : fileSize
        guard sizeMode else { return base }
        // Area grows with disk usage: height ∝ sqrt(share of the whole drive).
        let share = Double(max(0, node.allocSize)) / Double(rootAlloc)
        let h = max(26, min(1400, 1400 * sqrt(share)))
        return CGSize(width: base.width + CGFloat(120 * sqrt(share)), height: CGFloat(h))
    }
}
