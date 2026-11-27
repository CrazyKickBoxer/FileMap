import AppKit
import Foundation

extension MapModel {
    enum SelectMode { case replace, toggle, extend }

    func hitTest(screen point: CGPoint) -> SceneKey? {
        let world = effectiveCamera.toWorld(point, in: viewSize)
        return displayScene.hitTest(world).map { displayScene.nodes[Int($0)].key }
    }

    func select(_ key: SceneKey?, mode: SelectMode = .replace) {
        guard let key else {
            if mode == .replace {
                selection = []
                setFocus(nil)
            }
            return
        }
        switch mode {
        case .replace:
            selection = [key]
        case .toggle:
            if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
        case .extend:
            selection.insert(key)
        }
        setFocus(selection.contains(key) ? key : selection.first)
    }

    func selectAll() {
        guard let focus, let i = displayScene.index[focus] else { return }
        let p = displayScene.nodes[Int(i)].parent
        let siblings = p >= 0 ? displayScene.nodes[Int(p)].children : displayScene.roots
        selection = Set(siblings.map { displayScene.nodes[Int($0)].key }.filter { $0.nodeID != nil })
    }

    /// Selects every file/folder box intersecting a screen rectangle.
    func selectBoxes(inScreenRect rect: CGRect, extend: Bool) {
        let world = effectiveCamera.toWorld(rect, in: viewSize)
        var found: Set<SceneKey> = []
        var stack = displayScene.roots
        while let i = stack.popLast() {
            let n = displayScene.nodes[Int(i)]
            guard n.bounds.intersects(world) else { continue }
            if n.rect.intersects(world), n.key.nodeID != nil, !(displayScene.style == .nested && n.rect.contains(world)) {
                found.insert(n.key)
            }
            stack.append(contentsOf: n.children)
        }
        selection = extend ? selection.union(found) : found
        if let f = focus, selection.contains(f) { return }
        setFocus(selection.first)
    }

    /// Single click on a box (after mouse up without dragging).
    func activate(_ key: SceneKey, wasSelected: Bool) async {
        switch key {
        case .node(let id):
            guard let node = await node(id: id), node.isFolder else { return }
            guard mode != .cluster else { return }
            if !expanded.contains(id) {
                await expand(id)
            } else if wasSelected {
                collapse(id)
            }
        case .more(let parent):
            moreGridParent = parent
        case .cluster, .group:
            clusters.toggle(key)
            relayout(animated: true)
        case .debug:
            break
        }
    }

    /// Double click / Return.
    func openFocused() async {
        guard let focus else { return }
        switch focus {
        case .node(let id):
            guard let node = await node(id: id) else { return }
            if node.isFolder, mode != .cluster {
                if !expanded.contains(id) { await expand(id) }
                fitSelection()
            } else {
                fileOps?.open(selectedNodes.isEmpty ? [node] : selectedNodes)
            }
        case .more(let parent):
            moreGridParent = parent
        case .cluster, .group:
            clusters.toggle(focus)
            relayout(animated: true)
        case .debug:
            break
        }
    }

    func beginRename() {
        guard let id = focus?.nodeID, let node = nodes[id] else { return }
        if let reason = ProtectedPaths.reasonBlocked(node) {
            report("Can't rename \(node.name)", message: reason)
            return
        }
        renaming = id
    }

    /// Whether a screen point lies on the title text of a box (click-to-rename).
    func isOnTitle(_ key: SceneKey, screen point: CGPoint) -> Bool {
        guard let r = screenRect(key), r.height >= 24 else { return false }
        let titleZone = CGRect(x: r.minX + r.height * 0.6 + 14, y: r.minY, width: r.width * 0.6, height: r.height * 0.55)
        return titleZone.contains(point)
    }
}
