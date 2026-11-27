import AppKit
import Foundation

extension InteractionView: NSDraggingSource {
    func beginFileDrag(event: NSEvent) {
        let nodes = model.selectedNodes
        guard !nodes.isEmpty else { return }
        let items: [NSDraggingItem] = nodes.map { node in
            let item = NSDraggingItem(pasteboardWriter: node.url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: node.path)
            icon.size = NSSize(width: 48, height: 48)
            let rect = model.screenRect(.node(node.id)) ?? CGRect(origin: convert(event.locationInWindow, from: nil), size: .zero)
            let frame = CGRect(x: rect.minX, y: rect.midY - 24, width: 48, height: 48)
            item.setDraggingFrame(frame, contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : [.copy, .move, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dragged out and moved/deleted by another app: bring the index up to date.
        guard operation.contains(.move) || operation.contains(.delete) else { return }
        let paths = model.selectedNodes.map(\.path)
        guard let patcher = model.fileOps?.patcher else { return }
        Task {
            if let result = try? await patcher.patch(paths: paths + paths.map(\.parentPath)) { model.apply(result) }
        }
    }

    // MARK: Destination

    private func dropFolder(at p: CGPoint) -> (SceneKey, Node)? {
        guard let key = model.hitTest(screen: p), let id = key.nodeID, let node = model.nodes[id] else { return nil }
        if node.isFolder { return (key, node) }
        if model.mode != .cluster, let parentID = node.parentID, let parent = model.nodes[parentID] { return (.node(parentID), parent) }
        return nil
    }

    private func operation(for info: NSDraggingInfo, into folder: Node) -> NSDragOperation {
        if ScanPolicy.isSystem(folder.path) { return [] }
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) { return .copy }
        if flags.contains(.command) { return .move }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let target = try? folder.url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let sameVolume = urls.allSatisfy { url in
            let v = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            return v != nil && v == target
        }
        return sameVolume ? .move : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        guard let (key, folder) = dropFolder(at: p) else {
            model.dropTarget = nil
            springTimer?.invalidate()
            springKey = nil
            return []
        }
        if model.dropTarget != key { model.dropTarget = key }
        if springKey != key {
            springKey = key
            springTimer?.invalidate()
            // Spring-loading: hovering over a closed folder opens it.
            springTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.springKey == key, let id = key.nodeID, !self.model.isExpanded(id) else { return }
                    Task { await self.model.expand(id) }
                }
            }
        }
        return operation(for: sender, into: folder)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model.dropTarget = nil
        springTimer?.invalidate()
        springKey = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { draggingExited(nil) }
        let p = convert(sender.draggingLocation, from: nil)
        guard let (_, folder) = dropFolder(at: p) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let op = operation(for: sender, into: folder)
        guard !op.isEmpty else {
            model.report("Can't drop here", message: ProtectedPaths.reasonBlocked(destination: folder.path) ?? "This folder is protected.")
            return false
        }
        model.fileOps?.transfer(urls, into: folder, copy: op == .copy)
        return true
    }
}
