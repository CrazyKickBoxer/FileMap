import CoreGraphics
import Foundation
import Observation

/// Cluster view state: grouping choice, which sub-groups are open, and cached query results.
@MainActor
@Observable
final class ClusterController {
    @ObservationIgnored private let store: IndexStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var groupCache: [String: [GroupSummary]] = [:]
    @ObservationIgnored private var itemCache: [String: (nodes: [Node], total: Int)] = [:]
    @ObservationIgnored private(set) var lastItems: [Node] = []

    var grouping: ClusterGrouping = .type { didSet { invalidate(); collapsed = []; expandedGroups = [] } }
    var scopeToSelection = false { didSet { invalidate() } }
    /// The folder clustering is limited to (captured when scoping is turned on).
    var scopePath: String?
    private(set) var expandedGroups: Set<String> = []
    private(set) var collapsed: Set<String> = []
    private(set) var isLoading = false
    @ObservationIgnored private var itemLimits: [String: Int] = [:]

    static let defaultItemLimit = 120
    static let separator = "|"

    init(store: IndexStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func invalidate() {
        groupCache = [:]
        itemCache = [:]
    }

    func toggle(_ key: SceneKey) {
        switch key {
        case .cluster(let k):
            if collapsed.contains(k) { collapsed.remove(k) } else { collapsed.insert(k) }
        case .group(let k):
            if k.hasSuffix(Self.separator + "#more") {
                let group = String(k.dropLast((Self.separator + "#more").count))
                itemLimits[group, default: Self.defaultItemLimit] += 240
                itemCache[group] = nil
            } else if expandedGroups.contains(k) {
                expandedGroups.remove(k)
            } else {
                expandedGroups.insert(k)
            }
        default:
            break
        }
    }

    private func query(filter: VisibilityFilter, scopePath: String?) -> ClusterQuery {
        ClusterQuery(grouping: grouping, dateColumn: settings.clusterDateField.column, filter: filter, scopePath: scopePath)
    }

    /// Builds the nested cluster scene. Returns the scene; item nodes are kept in `lastItems`.
    func buildScene(filter: VisibilityFilter, scopePath: String?) async -> MapScene {
        isLoading = true
        defer { isLoading = false }
        let q = query(filter: filter, scopePath: scopePath)
        let grouping = self.grouping
        var input = LayoutInput()
        var items: [Node] = []
        do {
            let clusters = try await groups(q, path: [])
            await prefetchSubgroups(q, clusters: clusters)
            for c in clusters {
                let ckey = grouping.rawValue + Self.separator + c.value
                let cIndex = input.add(.init(key: .cluster(ckey), size: CGSize(width: 320, height: 96),
                                             display: display(c, role: .cluster, level: q.levels[0])), parent: nil)
                if collapsed.contains(ckey) { continue }
                try await addChildren(q, path: [c.value], keyPrefix: ckey, parent: cIndex, input: &input, items: &items)
            }
        } catch {
            Log.clusters.error("Cluster query failed: \(error.localizedDescription, privacy: .public)")
        }
        lastItems = items
        return NestedGridLayout.layout(input)
    }

    private func addChildren(_ q: ClusterQuery, path: [String], keyPrefix: String, parent: Int32,
                             input: inout LayoutInput, items: inout [Node]) async throws {
        if path.count < q.levels.count {
            for g in try await groups(q, path: path) {
                let key = keyPrefix + Self.separator + g.value
                let open = expandedGroups.contains(key)
                var d = display(g, role: .group, level: q.levels[path.count])
                if open { d.flags.insert(.expanded) }
                let gi = input.add(.init(key: .group(key), size: CGSize(width: 236, height: 64), display: d), parent: parent)
                if open {
                    try await addChildren(q, path: path + [g.value], keyPrefix: key, parent: gi, input: &input, items: &items)
                }
            }
            return
        }
        // Deepest level: the files themselves.
        let limit = itemLimits[keyPrefix] ?? Self.defaultItemLimit
        let page: (nodes: [Node], total: Int)
        if let cached = itemCache[keyPrefix] {
            page = cached
        } else {
            let p = path
            page = try await store.read { db in try q.items(db, path: p, limit: limit) }
            itemCache[keyPrefix] = page
        }
        for n in page.nodes {
            items.append(n)
            input.add(.init(key: .node(n.id), size: CGSize(width: 236, height: 38),
                            display: TreeInputBuilder.display(for: n, isRoot: false, expanded: false, pinned: false)), parent: parent)
        }
        if page.total > page.nodes.count {
            let more = NodeDisplay(role: .more, title: "+ \(Format.count(Int64(page.total - page.nodes.count))) more",
                                   subtitle: "Show more", modifiedAt: nil, glyph: GlyphTable.more, kind: .other)
            input.add(.init(key: .group(keyPrefix + Self.separator + "#more"), size: CGSize(width: 236, height: 38), display: more), parent: parent)
        }
    }

    /// Runs the first-level sub-group queries for every cluster at once (the pool has several readers).
    private func prefetchSubgroups(_ q: ClusterQuery, clusters: [GroupSummary]) async {
        let store = self.store
        let missing = clusters.map(\.value).filter { groupCache[$0] == nil && q.levels.count > 1 }
        let results = await withTaskGroup(of: (String, [GroupSummary]?).self) { group in
            for value in missing {
                group.addTask { (value, try? await store.read { db in try q.groups(db, path: [value]) }) }
            }
            var out: [(String, [GroupSummary])] = []
            for await (value, result) in group { if let result { out.append((value, result)) } }
            return out
        }
        for (value, result) in results { groupCache[value] = result }
    }

    private func groups(_ q: ClusterQuery, path: [String]) async throws -> [GroupSummary] {
        let cacheKey = path.joined(separator: Self.separator)
        if let cached = groupCache[cacheKey] { return cached }
        let result = try await store.read { db in try q.groups(db, path: path) }
        groupCache[cacheKey] = result
        return result
    }

    private func display(_ g: GroupSummary, role: NodeDisplay.Role, level: ClusterQuery.Level) -> NodeDisplay {
        let kind: FileKind
        let glyph: String
        switch level {
        case .kind:
            kind = FileKind(raw: g.value)
            glyph = GlyphTable.byKind[kind] ?? ""
        case .year, .month, .dateBucket:
            kind = .document
            glyph = GlyphTable.calendar
        case .project:
            kind = .code
            glyph = GlyphTable.project
        }
        return NodeDisplay(role: role, title: g.title, subtitle: "\(Format.bytes(g.size)) · \(Format.items(g.count))",
                           modifiedAt: nil, glyph: glyph, kind: kind, flags: [.hasChildren])
    }
}
