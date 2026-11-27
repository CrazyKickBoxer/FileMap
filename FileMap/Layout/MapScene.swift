import CoreGraphics
import Foundation

/// Identifies a box on the map.
enum SceneKey: Hashable, Sendable {
    case node(Int64)
    case more(Int64)      // the "+ N more" box under a folder
    case cluster(String)  // a cluster region in cluster view
    case group(String)    // a sub-group inside a cluster
    case debug(Int32)     // the synthetic stress-test tree

    var nodeID: Int64? {
        if case .node(let id) = self { return id }
        return nil
    }
}

/// Everything the renderer needs to draw one box, computed once per layout.
struct NodeDisplay: Sendable {
    enum Role: Sendable { case root, folder, file, package, more, cluster, group }

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt16
        static let expanded = Flags(rawValue: 1 << 0)
        static let hasChildren = Flags(rawValue: 1 << 1)
        static let dimmed = Flags(rawValue: 1 << 2)
        static let pinned = Flags(rawValue: 1 << 3)
        static let noAccess = Flags(rawValue: 1 << 4)
        static let link = Flags(rawValue: 1 << 5)
        static let hidden = Flags(rawValue: 1 << 6)
    }

    var role: Role
    var title: String
    var subtitle: String
    var modifiedAt: Double?
    var glyph: String
    var kind: FileKind
    var flags: Flags = []
    var accessibilityLabel: String { "\(roleName) \(title), \(subtitle)" }

    var roleName: String {
        switch role {
        case .root: "Volume"
        case .folder: "Folder"
        case .file: "File"
        case .package: "Package"
        case .more: "More items"
        case .cluster: "Cluster"
        case .group: "Group"
        }
    }

    var isContainer: Bool { role == .cluster || role == .group }
}

/// A laid-out box.
struct SceneNode: Sendable {
    var key: SceneKey
    var rect: CGRect
    /// Union of this box and everything below it; used for culling whole branches at once.
    var bounds: CGRect
    var parent: Int32 = -1
    var children: [Int32] = []
    var depth: Int16 = 0
    var display: NodeDisplay
}

/// The output of a layout pass: what the renderer draws and what hit-testing searches.
struct MapScene: Sendable {
    enum Style: Sendable { case tree, nested }

    var style: Style
    var nodes: [SceneNode]
    var roots: [Int32]
    var index: [SceneKey: Int32]
    var bounds: CGRect

    static let empty = MapScene(style: .tree, nodes: [], roots: [], index: [:], bounds: .zero)

    func node(_ key: SceneKey) -> SceneNode? {
        index[key].map { nodes[Int($0)] }
    }

    func rect(_ key: SceneKey) -> CGRect? { node(key)?.rect }

    /// Deepest box containing a world point.
    func hitTest(_ p: CGPoint) -> Int32? {
        var found: Int32?
        var stack = roots
        while let i = stack.popLast() {
            let n = nodes[Int(i)]
            guard n.bounds.contains(p) else { continue }
            if n.rect.contains(p) { found = i }
            stack.append(contentsOf: n.children)
        }
        return found
    }
}

/// Input to a layout engine: a forest of boxes with preferred sizes.
struct LayoutInput: Sendable {
    struct Entry: Sendable {
        var key: SceneKey
        var size: CGSize
        var display: NodeDisplay
        var children: [Int32] = []
    }

    var entries: [Entry] = []
    var roots: [Int32] = []

    @discardableResult
    mutating func add(_ entry: Entry, parent: Int32?) -> Int32 {
        let i = Int32(entries.count)
        entries.append(entry)
        if let parent { entries[Int(parent)].children.append(i) } else { roots.append(i) }
        return i
    }
}
