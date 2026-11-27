import AppKit
import Foundation
import Observation

enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case tree, size, cluster
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tree: "Tree"
        case .size: "Size"
        case .cluster: "Cluster"
        }
    }
}

struct UserAlert: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var message: String
}

/// All state behind the map: what is loaded and expanded, the laid-out scene, the camera,
/// selection, and animations. Disk access goes through `IndexStore` asynchronously.
@MainActor
@Observable
final class MapModel {
    @ObservationIgnored let store: IndexStore
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored weak var fileOps: FileOperations?
    @ObservationIgnored weak var pins: PinStore?
    @ObservationIgnored let frameSink = FrameSink()
    @ObservationIgnored var quickLookHandler: (() -> Void)?
    @ObservationIgnored lazy var clusters = ClusterController(store: store, settings: settings)

    // Loaded tree data (not observed directly; changes flow through `scene`).
    @ObservationIgnored var rootID: Int64?
    @ObservationIgnored var nodes: [Int64: Node] = [:]
    @ObservationIgnored var childPages: [Int64: ChildPage] = [:]
    @ObservationIgnored var expanded: Set<Int64> = []
    @ObservationIgnored var promoted: [Int64: [Node]] = [:]
    @ObservationIgnored private var layoutGeneration = 0
    @ObservationIgnored private var animationEndTask: Task<Void, Never>?
    @ObservationIgnored private var cameras: [ViewMode: Camera] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPatch = PatchResult()
    @ObservationIgnored private var fitOnNextScene = false

    private(set) var mode: ViewMode = .tree
    private(set) var scene: MapScene = .empty
    private(set) var debugScene: MapScene?
    var camera = Camera()
    var viewSize: CGSize = .zero
    var selection: Set<SceneKey> = []
    private(set) var focus: SceneKey?
    var dropTarget: SceneKey?
    var marquee: CGRect?
    private(set) var transition: SceneTransition?
    private(set) var cameraAnimation: CameraAnimation?
    private(set) var pulse: Pulse?
    var renaming: Int64?
    var moreGridParent: Int64?
    private(set) var breadcrumb: [Node] = []
    private(set) var infoNode: Node?
    var alert: UserAlert?
    private(set) var isLoaded = false
    private(set) var isBuildingDebugTree = false

    init(store: IndexStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    // MARK: Derived state for the renderer

    var displayScene: MapScene { debugScene ?? scene }
    var isDebugActive: Bool { debugScene != nil }
    var isAnimating: Bool { transition != nil || cameraAnimation != nil || pulse != nil }
    var filter: VisibilityFilter { settings.visibility }

    var renderState: RenderState {
        RenderState(selection: selection, focus: focus, dropTarget: dropTarget, highlightPath: highlightPath,
                    pulse: pulse, transition: transition, marquee: marquee)
    }

    /// Keys from the root to the focused box (its edges glow).
    var highlightPath: Set<SceneKey> {
        guard let focus, let i = displayScene.index[focus] else { return [] }
        var keys: Set<SceneKey> = []
        var cur = i
        while cur >= 0 {
            let n = displayScene.nodes[Int(cur)]
            keys.insert(n.key)
            cur = n.parent
        }
        return keys
    }

    func cameraAt(_ date: Date) -> Camera? {
        cameraAnimation?.camera(at: date, viewSize: viewSize)
    }

    var effectiveCamera: Camera { cameraAt(Date()) ?? camera }

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var animationDuration: Double { reduceMotion ? 0 : 0.26 }

    var selectedNodeIDs: [Int64] { selection.compactMap(\.nodeID) }

    var selectedNodes: [Node] {
        selectedNodeIDs.compactMap { nodes[$0] }
    }

    var focusedNode: Node? { focus?.nodeID.flatMap { nodes[$0] } }

    // MARK: Loading

    /// Loads the root and restores the previous session's expanded folders and camera.
    func load() async {
        do {
            guard let root = try await store.read({ db in try NodeQueries.root(db) }) else {
                scene = .empty
                isLoaded = true
                return
            }
            rootID = root.id
            nodes[root.id] = root
            let saved: (paths: [String], camera: [Double]?) = try await store.read { db in
                (try Meta.getJSON(db, "expanded_paths", as: [String].self) ?? [],
                 try Meta.getJSON(db, "camera", as: [Double].self))
            }
            let wanted = Set(saved.paths)
            expanded = [root.id]
            var frontier = [root.id]
            while !frontier.isEmpty {
                let pages = try await loadPages(frontier)
                frontier = []
                for (_, page) in pages {
                    for child in page.nodes where child.isFolder && wanted.contains(child.path) {
                        expanded.insert(child.id)
                        frontier.append(child.id)
                    }
                }
            }
            relayout(animated: false)
            if let c = saved.camera, c.count == 3 {
                camera = Camera(center: CGPoint(x: c[0], y: c[1]), scale: CGFloat(c[2]))
            } else {
                fitAll(animated: false)
            }
            isLoaded = true
        } catch {
            report("Could not load the index", error)
        }
    }

    /// Fetches child pages for folders and caches their nodes.
    @discardableResult
    func loadPages(_ ids: [Int64]) async throws -> [Int64: ChildPage] {
        guard !ids.isEmpty else { return [:] }
        let filter = self.filter
        let pages = try await store.read { db in
            var result: [Int64: ChildPage] = [:]
            for id in ids { result[id] = try NodeQueries.children(db, of: id, filter: filter) }
            return result
        }
        for (id, page) in pages {
            childPages[id] = page
            for n in page.nodes { nodes[n.id] = n }
        }
        return pages
    }

    func node(id: Int64) async -> Node? {
        if let n = nodes[id] { return n }
        let n = try? await store.read { db in try NodeQueries.node(db, id: id) }
        if let n { nodes[n.id] = n }
        return n
    }

    // MARK: Expand / collapse

    func isExpanded(_ id: Int64) -> Bool { expanded.contains(id) }

    func expand(_ id: Int64, animated: Bool = true) async {
        guard let node = await node(id: id), node.isFolder else { return }
        if childPages[id] == nil {
            do { try await loadPages([id]) } catch { report("Could not read \(node.name)", error); return }
        }
        expanded.insert(id)
        relayout(animated: animated)
    }

    func collapse(_ id: Int64) {
        guard expanded.contains(id), id != rootID || expanded.count > 1 else { return }
        expanded.remove(id)
        relayout(animated: true)
    }

    func toggle(_ id: Int64) async {
        if expanded.contains(id) { collapse(id) } else { await expand(id) }
    }

    /// Adds a child picked from the "+ N more" grid to the visible tree.
    func promote(_ child: Node, into parentID: Int64) {
        nodes[child.id] = child
        var list = promoted[parentID] ?? []
        if !list.contains(where: { $0.id == child.id }) { list.append(child) }
        promoted[parentID] = list
    }

    // MARK: View mode

    func setMode(_ newMode: ViewMode) {
        guard newMode != mode else { return }
        cameras[mode] = camera
        mode = newMode
        moreGridParent = nil
        if newMode == .cluster {
            selection = selection.filter { $0.nodeID != nil }
        }
        if let saved = cameras[newMode] { camera = saved } else { fitOnNextScene = true }
        relayout(animated: false)
    }

    // MARK: Layout

    func relayout(animated: Bool) {
        guard debugScene == nil else { return }
        layoutGeneration += 1
        let generation = layoutGeneration
        switch mode {
        case .tree, .size:
            guard let rootID else { setScene(.empty, animated: false); return }
            let snapshot = TreeSnapshot(rootID: rootID, nodes: nodes, children: childPages, expanded: expanded,
                                        promoted: promoted, pinned: pins?.pinnedNodeIDs ?? [], sizeMode: mode == .size)
            let input = TreeInputBuilder.build(snapshot)
            if input.entries.count < 40_000 {
                setScene(TidyTreeLayout.layout(input), animated: animated)
            } else {
                Task.detached(priority: .userInitiated) {
                    let scene = TidyTreeLayout.layout(input)
                    await MainActor.run {
                        guard generation == self.layoutGeneration else { return }
                        self.setScene(scene, animated: false)
                    }
                }
            }
        case .cluster:
            let scope = clusters.scopeToSelection ? clusters.scopePath : nil
            let filter = self.filter
            Task {
                let scene = await clusters.buildScene(filter: filter, scopePath: scope)
                guard generation == layoutGeneration else { return }
                for n in clusters.lastItems { nodes[n.id] = n }
                setScene(scene, animated: animated)
            }
        }
    }

    private func setScene(_ new: MapScene, animated: Bool) {
        let now = Date()
        if animated, animationDuration > 0, !scene.nodes.isEmpty, scene.style == new.style, new.nodes.count < 20_000 {
            let t = CGFloat(transition?.progress(at: now) ?? 1)
            func current(_ n: SceneNode) -> CGRect {
                guard let tr = transition, t < 1 else { return n.rect }
                if let old = tr.from[n.key] { return old.lerp(to: n.rect, t) }
                if let o = tr.appearFrom[n.key] { return o.lerp(to: n.rect, t) }
                return n.rect
            }
            var from: [SceneKey: CGRect] = [:]
            var ghosts: [SceneTransition.Ghost] = []
            for n in scene.nodes {
                if new.index[n.key] != nil {
                    from[n.key] = current(n)
                } else if ghosts.count < 1500 {
                    // Slide towards the nearest ancestor that survives.
                    var p = n.parent
                    var target: CGRect?
                    while p >= 0 {
                        let pk = scene.nodes[Int(p)].key
                        if let ni = new.index[pk] { target = new.nodes[Int(ni)].rect; break }
                        p = scene.nodes[Int(p)].parent
                    }
                    let r = current(n)
                    let to = target.map { CGRect(x: $0.minX, y: $0.midY - r.height / 2, width: r.width, height: r.height) } ?? r
                    ghosts.append(.init(key: n.key, from: r, to: to, display: n.display))
                }
            }
            var appear: [SceneKey: CGRect] = [:]
            for n in new.nodes where from[n.key] == nil {
                var p = n.parent
                while p >= 0 {
                    if let r = from[new.nodes[Int(p)].key] {
                        appear[n.key] = CGRect(x: r.minX, y: r.midY - n.rect.height / 2, width: n.rect.width, height: n.rect.height)
                        break
                    }
                    p = new.nodes[Int(p)].parent
                }
            }
            transition = SceneTransition(from: from, appearFrom: appear, ghosts: ghosts, start: now, duration: animationDuration)
            scheduleAnimationEnd()
        } else {
            transition = nil
        }
        scene = new
        if fitOnNextScene, !new.nodes.isEmpty {
            fitOnNextScene = false
            fitAll(animated: false)
        }
        if let focus, new.index[focus] == nil, mode != .cluster, focus.nodeID == nil { self.focus = nil }
    }

    func scheduleAnimationEnd() {
        animationEndTask?.cancel()
        let now = Date()
        var remaining: Double = 0
        if let t = transition { remaining = max(remaining, t.start.addingTimeInterval(t.duration).timeIntervalSince(now)) }
        if let c = cameraAnimation { remaining = max(remaining, c.start.addingTimeInterval(c.duration).timeIntervalSince(now)) }
        if let p = pulse { remaining = max(remaining, p.start.addingTimeInterval(Pulse.duration).timeIntervalSince(now)) }
        animationEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, remaining) + 0.02))
            guard !Task.isCancelled else { return }
            self?.finishAnimations()
        }
    }

    private func finishAnimations() {
        let now = Date()
        if let t = transition, now >= t.start.addingTimeInterval(t.duration) { transition = nil }
        if let c = cameraAnimation, c.progress(at: now) >= 1 {
            camera = c.to
            cameraAnimation = nil
        }
        if let p = pulse, p.progress(at: now) >= 1 { pulse = nil }
        if isAnimating { scheduleAnimationEnd() }
    }

    func startPulse(_ key: SceneKey) {
        guard !reduceMotion else { return }
        pulse = Pulse(key: key, start: Date())
        scheduleAnimationEnd()
    }

    // MARK: Live updates

    /// Applies index changes from the watcher or a file operation. Coalesces bursts.
    func apply(_ patch: PatchResult) {
        pendingPatch.merge(patch)
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            let patch = self.pendingPatch
            self.pendingPatch = PatchResult()
            await self.refresh(patch)
            self.refreshTask = nil
            if !self.pendingPatch.isEmpty { self.apply(PatchResult()) }
        }
    }

    private func refresh(_ patch: PatchResult) async {
        for id in patch.removedNodes {
            nodes[id] = nil
            childPages[id] = nil
            expanded.remove(id)
            selection.remove(.node(id))
            for (parent, list) in promoted { promoted[parent] = list.filter { $0.id != id } }
        }
        let reloadNodes = patch.changedNodes.filter { nodes[$0] != nil }
        let reloadPages = patch.changedParents.filter { childPages[$0] != nil }
        do {
            let fresh = try await store.read { db in try NodeQueries.nodes(db, ids: Array(reloadNodes)) }
            for n in fresh { nodes[n.id] = n }
            try await loadPages(Array(reloadPages))
        } catch {
            Log.interaction.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
        }
        if let f = focus?.nodeID, let n = nodes[f] { infoNode = n }
        relayout(animated: true)
        if mode == .cluster { clusters.invalidate() }
    }

    /// Reloads everything currently loaded (used while a scan is filling the index).
    func refreshAll() async {
        if rootID == nil {
            await load()
            return
        }
        do {
            let ids = Array(nodes.keys)
            let fresh = try await store.read { db in try NodeQueries.nodes(db, ids: ids) }
            for n in fresh { nodes[n.id] = n }
            try await loadPages(Array(expanded))
        } catch {
            Log.interaction.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
        }
        relayout(animated: false)
    }

    /// Drops all cached data (after clearing the index or changing visibility settings).
    func reset() async {
        nodes = [:]
        childPages = [:]
        promoted = [:]
        selection = []
        focus = nil
        rootID = nil
        scene = .empty
        await load()
    }

    func reloadForVisibilityChange() async {
        let ids = Array(childPages.keys)
        childPages = [:]
        promoted = [:]
        _ = try? await loadPages(ids)
        relayout(animated: true)
    }

    // MARK: Persistence

    func saveState() {
        let paths = expanded.compactMap { nodes[$0]?.path }
        // Don't persist the stress-test camera or another view's camera as the tree's.
        let cam = (mode == .tree && debugScene == nil) ? camera : (cameras[.tree] ?? Camera.fit(scene.bounds, in: viewSize))
        let rects: [(Int64, CGRect)] = scene.nodes.prefix(20_000).compactMap { n in n.key.nodeID.map { ($0, n.rect) } }
        do {
            try store.writeNow { db in
                try Meta.setJSON(db, "expanded_paths", paths)
                try Meta.setJSON(db, "camera", [Double(cam.center.x), Double(cam.center.y), Double(cam.scale)])
                try db.execute(sql: "DELETE FROM layout_cache")
                let stmt = try db.cachedStatement(sql: "INSERT INTO layout_cache (node_id, x, y, w, h) VALUES (?, ?, ?, ?, ?)")
                for (id, r) in rects {
                    try stmt.execute(arguments: [id, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)])
                }
            }
        } catch {
            Log.interaction.error("Could not save map state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Debug stress test

    /// Builds a synthetic tree of about one million boxes to measure rendering speed.
    func enterDebugTree() {
        guard !isBuildingDebugTree else { return }
        if debugScene == nil { cameras[mode] = camera }
        isBuildingDebugTree = true
        Task.detached(priority: .userInitiated) {
            let scene = DebugTree.makeScene(fanout: 10, depth: 6)
            await MainActor.run {
                self.debugScene = scene
                self.isBuildingDebugTree = false
                self.fitAll(animated: false)
            }
        }
    }

    func exitDebugTree() {
        debugScene = nil
        if let saved = cameras[mode] { camera = saved } else { fitAll(animated: false) }
    }

    // MARK: Errors

    func report(_ title: String, _ error: Error) {
        Log.interaction.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        alert = UserAlert(title: title, message: error.localizedDescription)
    }

    func report(_ title: String, message: String) {
        alert = UserAlert(title: title, message: message)
    }

    // MARK: Focus

    func setFocus(_ key: SceneKey?) {
        focus = key
        updateFocusInfo()
    }

    private func updateFocusInfo() {
        guard let id = focus?.nodeID else {
            infoNode = nil
            breadcrumb = []
            return
        }
        infoNode = nodes[id]
        Task {
            let lineage = (try? await store.read { db in try NodeQueries.lineage(db, of: id) }) ?? []
            guard focus?.nodeID == id else { return }
            breadcrumb = lineage
            if let last = lineage.last {
                nodes[last.id] = last
                infoNode = last
            }
        }
    }

    func setCameraAnimation(_ animation: CameraAnimation?) {
        cameraAnimation = animation
        if animation != nil { scheduleAnimationEnd() }
    }

    func setDebugSceneForTesting(_ scene: MapScene?) { debugScene = scene }
}
