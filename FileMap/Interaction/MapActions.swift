import AppKit
import Foundation

/// Every user-facing command, shared by menus, the context menu, keyboard, and buttons.
@MainActor
struct MapActions {
    let model: MapModel

    private var fileOps: FileOperations? { model.fileOps }

    var hasSelection: Bool { !model.selectedNodes.isEmpty }

    /// Where "New Folder" and "Paste" put things: the focused folder, or the folder holding the focused file.
    var targetFolder: Node? {
        if let n = model.focusedNode {
            if n.isFolder { return n }
            if let p = n.parentID { return model.nodes[p] }
        }
        return model.rootID.flatMap { model.nodes[$0] }
    }

    func open() async { await model.openFocused() }

    func openWith(_ app: URL) { fileOps?.open(model.selectedNodes, withApplicationAt: app) }

    func quickLook() { model.quickLookHandler?() }

    func rename() { model.beginRename() }

    func trash() { fileOps?.trash(model.selectedNodes) }

    func copy() { fileOps?.copyToPasteboard(model.selectedNodes) }

    func paste() {
        guard let folder = targetFolder else { return }
        fileOps?.paste(into: folder)
    }

    func newFolder() async {
        guard let folder = targetFolder, let fileOps else { return }
        guard let url = await fileOps.newFolder(in: folder) else { return }
        await model.reveal(path: url.path)
        model.beginRename()
    }

    func revealInFinder() { fileOps?.revealInFinder(model.selectedNodes) }

    func copyPath() { fileOps?.copyPath(model.selectedNodes) }

    func openInTerminal() {
        guard let n = model.focusedNode else { return }
        fileOps?.openInTerminal(n)
    }

    func getInfo() { model.settings.showInfo.toggle() }

    func togglePin() async {
        guard let n = model.focusedNode else { return }
        await model.pins?.toggle(n)
        model.relayout(animated: false)
    }

    func showInTree() async {
        guard let id = model.focus?.nodeID else { return }
        await model.reveal(nodeID: id)
    }

    /// Builds the right-click menu for the current selection.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let nodes = model.selectedNodes
        guard let first = nodes.first else {
            menu.addItem(ActionMenuItem("Fit Whole Map") { model.fitAll() })
            return menu
        }
        let single = nodes.count == 1
        menu.addItem(ActionMenuItem("Open") { Task { await open() } })
        if single, !first.isFolder {
            let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for app in fileOps?.applications(toOpen: first).prefix(20) ?? [] {
                let item = ActionMenuItem(FileManager.default.displayName(atPath: app.path)) { openWith(app) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                sub.addItem(item)
            }
            if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")) }
            openWithItem.submenu = sub
            menu.addItem(openWithItem)
        }
        menu.addItem(ActionMenuItem("Quick Look") { quickLook() })
        menu.addItem(.separator())
        if single { menu.addItem(ActionMenuItem("Rename") { rename() }) }
        menu.addItem(ActionMenuItem("Move to Trash") { trash() })
        if single, first.isFolder { menu.addItem(ActionMenuItem("New Folder Inside") { Task { await newFolder() } }) }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Copy") { copy() })
        if single, first.isFolder { menu.addItem(ActionMenuItem("Paste Into Folder") { paste() }) }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Reveal in Finder") { revealInFinder() })
        menu.addItem(ActionMenuItem("Copy Path") { copyPath() })
        if single, first.isFolder { menu.addItem(ActionMenuItem("Open in Terminal") { openInTerminal() }) }
        menu.addItem(ActionMenuItem("Get Info") { model.settings.showInfo = true })
        if single {
            let pinned = model.pins?.isPinned(first.id) == true
            menu.addItem(ActionMenuItem(pinned ? "Unpin" : "Pin") { Task { await togglePin() } })
        }
        if model.mode == .cluster, single {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Show in Tree") { Task { await showInTree() } })
        }
        return menu
    }
}

/// An `NSMenuItem` that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() {
        let handler = self.handler
        MainActor.assumeIsolated { handler() }
    }
}
