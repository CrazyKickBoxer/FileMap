import AppKit
import Foundation

extension MapModel {
    enum Direction { case left, right, up, down }

    // MARK: Camera

    /// Changes the camera immediately, cancelling any fly animation first.
    func moveCamera(_ change: (inout Camera) -> Void) {
        if cameraAnimation != nil {
            camera = effectiveCamera
            setCameraAnimation(nil)
        }
        change(&camera)
    }

    func fly(to target: Camera, duration: Double? = nil) {
        let start = effectiveCamera
        let d = reduceMotion ? 0 : (duration ?? 0.65)
        if d == 0 {
            setCameraAnimation(nil)
            camera = target
            return
        }
        camera = start
        setCameraAnimation(CameraAnimation(from: start, to: target, start: Date(), duration: d))
        camera = target
    }

    func fitAll(animated: Bool = true) {
        let target = Camera.fit(displayScene.bounds, in: viewSize, padding: 60, maxScale: 1.0)
        if animated { fly(to: target) } else {
            setCameraAnimation(nil)
            camera = target
        }
    }

    /// Smart zoom: fit the selected folder's branch (or toggle back to everything).
    func fitSelection() {
        guard let focus, let n = displayScene.node(focus) else { return fitAll() }
        let target = Camera.fit(n.bounds, in: viewSize, padding: 80, maxScale: 1.6)
        if abs(target.scale - camera.scale) / target.scale < 0.05, hypot(target.center.x - camera.center.x, target.center.y - camera.center.y) < 10 {
            fitAll()
        } else {
            fly(to: target)
        }
    }

    /// Pans just enough to bring a box into view.
    func ensureVisible(_ key: SceneKey) {
        guard let r = displayScene.rect(key) else { return }
        let cam = effectiveCamera
        let screen = cam.toScreen(r, in: viewSize)
        let bounds = CGRect(origin: .zero, size: viewSize).insetBy(dx: 40, dy: 40)
        if bounds.contains(screen) { return }
        var target = cam
        if cam.scale < 0.5 { target.scale = 0.9 }
        target.center = CGPoint(x: r.midX, y: r.midY)
        fly(to: target, duration: 0.35)
    }

    // MARK: Reveal and fly-to

    /// Expands the path to a node, flies there, and pulses the box once.
    func reveal(nodeID: Int64, pulse: Bool = true, select: Bool = true) async {
        if debugScene != nil { exitDebugTree() }
        if mode == .cluster { setMode(.tree) }
        do {
            let lineage = try await store.read { db in try NodeQueries.lineage(db, of: nodeID) }
            guard let target = lineage.last else {
                report("Item not found", message: "It may have been moved or deleted.")
                return
            }
            for n in lineage { nodes[n.id] = n }
            for (parent, child) in zip(lineage, lineage.dropFirst()) {
                if childPages[parent.id] == nil { try await loadPages([parent.id]) }
                expanded.insert(parent.id)
                if childPages[parent.id]?.nodes.contains(where: { $0.id == child.id }) != true {
                    promote(child, into: parent.id)
                }
            }
            relayout(animated: true)
            let key = SceneKey.node(target.id)
            if select {
                selection = [key]
                setFocus(key)
            }
            if let r = scene.rect(key) {
                let scale = max(effectiveCamera.scale, 0.9)
                fly(to: Camera(center: CGPoint(x: r.midX, y: r.midY), scale: min(scale, 1.4)))
            }
            if pulse { startPulse(key) }
        } catch {
            report("Could not reveal item", error)
        }
    }

    func reveal(path: String) async {
        guard let node = try? await store.read({ db in try NodeQueries.node(db, path: path) }) else {
            report("Not in the map yet", message: "\(path) has not been indexed.")
            return
        }
        await reveal(nodeID: node.id)
    }

    func goHome() async {
        await reveal(path: NSHomeDirectory())
    }

    func goToParent() {
        guard let focus, let i = displayScene.index[focus] else { return }
        let p = displayScene.nodes[Int(i)].parent
        guard p >= 0 else { return }
        let key = displayScene.nodes[Int(p)].key
        selection = [key]
        setFocus(key)
        ensureVisible(key)
    }

    // MARK: Keyboard navigation

    func moveSelection(_ direction: Direction) async {
        let s = displayScene
        guard !s.nodes.isEmpty else { return }
        guard let focus, let i = s.index[focus] else {
            if let r = s.roots.first { select(s.nodes[Int(r)].key) }
            return
        }
        let n = s.nodes[Int(i)]
        var next: SceneKey?
        let siblings: [Int32] = n.parent >= 0 ? s.nodes[Int(n.parent)].children : s.roots
        let pos = siblings.firstIndex(of: i) ?? 0
        switch (s.style, direction) {
        case (.tree, .right), (.nested, .down):
            if let first = n.children.first {
                next = s.nodes[Int(first)].key
            } else if let id = n.key.nodeID, nodes[id]?.isFolder == true, !expanded.contains(id) {
                await expand(id)
                if let ni = scene.index[n.key], let first = scene.nodes[Int(ni)].children.first {
                    next = scene.nodes[Int(first)].key
                }
            } else if case .group = n.key {
                clusters.toggle(n.key)
                relayout(animated: true)
                return
            }
        case (.tree, .left), (.nested, .up):
            if n.parent >= 0 { next = s.nodes[Int(n.parent)].key }
        case (.tree, .up), (.nested, .left):
            if pos > 0 { next = s.nodes[Int(siblings[pos - 1])].key }
        case (.tree, .down), (.nested, .right):
            if pos + 1 < siblings.count { next = s.nodes[Int(siblings[pos + 1])].key }
        }
        if let next {
            select(next)
            ensureVisible(next)
        }
    }

    /// The screen rectangle of a box right now.
    func screenRect(_ key: SceneKey) -> CGRect? {
        displayScene.rect(key).map { effectiveCamera.toScreen($0, in: viewSize) }
    }
}
