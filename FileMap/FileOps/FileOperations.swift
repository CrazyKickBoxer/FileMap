import AppKit
import Foundation

/// One reversible file-system step.
enum FileStep: Sendable, Equatable {
    case move(from: URL, to: URL)
    case copy(from: URL, to: URL)
    case trash(URL)
    case untrash(from: URL, to: URL)
    case makeDirectory(URL)
}

/// Holds the inverse of an operation that may still be running when it is registered for undo.
@MainActor
final class InverseBox {
    var steps: [FileStep] = []
    var finished = false
}

/// Every file action the map offers. Disk work runs off the main actor; undo/redo go through
/// `UndoManager`; the index is patched right after each action so the map never waits for FSEvents.
@MainActor
final class FileOperations {
    let store: IndexStore
    var patcher: IndexPatcher
    let undoManager: UndoManager
    let settings: AppSettings
    var resolver: ConflictResolving = AlertConflictResolver()
    var onPatch: (PatchResult) -> Void = { _ in }
    var onError: (String, String) -> Void = { _, _ in }
    /// The most recent operation (tests await it).
    private(set) var lastTask: Task<Void, Never>?

    init(store: IndexStore, patcher: IndexPatcher, undoManager: UndoManager, settings: AppSettings) {
        self.store = store
        self.patcher = patcher
        self.undoManager = undoManager
        self.settings = settings
    }

    // MARK: Opening

    func open(_ nodes: [Node]) {
        for node in nodes where !NSWorkspace.shared.open(node.url) {
            onError("Couldn't open “\(node.name)”", "No application is available to open it.")
        }
    }

    func applications(toOpen node: Node) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: node.url)
    }

    func open(_ nodes: [Node], withApplicationAt app: URL) {
        let urls = nodes.map(\.url)
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.onError("Couldn't open with \(app.deletingPathExtension().lastPathComponent)", error.localizedDescription) }
        }
    }

    func revealInFinder(_ nodes: [Node]) {
        NSWorkspace.shared.activateFileViewerSelecting(nodes.map(\.url))
    }

    func copyPath(_ nodes: [Node]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(nodes.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func openInTerminal(_ node: Node) {
        let folder = node.isFolder ? node.url : node.url.deletingLastPathComponent()
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.onError("Couldn't open Terminal", error.localizedDescription) }
        }
    }

    // MARK: Pasteboard

    func copyToPasteboard(_ nodes: [Node]) {
        guard !nodes.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(nodes.map { $0.url as NSURL })
    }

    @discardableResult
    func paste(into folder: Node) -> Task<Void, Never>? {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return nil }
        return transfer(urls, into: folder, copy: true)
    }

    // MARK: Changing things

    @discardableResult
    func rename(_ node: Node, to newName: String) -> Task<Void, Never>? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != node.name else { return nil }
        if let reason = ProtectedPaths.reasonBlocked(node) {
            onError("Can't rename “\(node.name)”", reason)
            return nil
        }
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            onError("That name can't be used", "Names can't be empty or contain a slash (/).")
            return nil
        }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(name)
        // Allow case-only renames; otherwise refuse to overwrite.
        if FileManager.default.fileExists(atPath: destination.path), name.lowercased() != node.name.lowercased() {
            onError("The name “\(name)” is already taken", "Please choose a different name.")
            return nil
        }
        return perform([.move(from: node.url, to: destination)], actionName: "Rename")
    }

    /// Moves or copies URLs (from the map, Finder, or the pasteboard) into a folder.
    @discardableResult
    func transfer(_ urls: [URL], into folder: Node, copy: Bool) -> Task<Void, Never>? {
        guard folder.isFolder else { return nil }
        if let reason = ProtectedPaths.reasonBlocked(destination: folder.path) {
            onError("Can't put items in “\(folder.name)”", reason)
            return nil
        }
        var steps: [FileStep] = []
        var blocked: [String] = []
        var policy: ConflictChoice?
        let fm = FileManager.default
        let candidates = urls.filter { url in
            let path = url.standardizedFileURL.path
            if folder.path.isInside(path) {
                blocked.append("“\(url.lastPathComponent)” can't be put inside itself.")
                return false
            }
            if !copy, ProtectedPaths.isProtected(path) {
                blocked.append("“\(url.lastPathComponent)” is a protected location.")
                return false
            }
            if !copy, path.parentPath == folder.path { return false }  // already there
            return true
        }
        for (n, url) in candidates.enumerated() {
            var destination = folder.url.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                var choice = policy
                if copy && url.standardizedFileURL.path.parentPath == folder.path { choice = .keepBoth }
                if choice == nil {
                    let answer = resolver.resolve(name: url.lastPathComponent, destination: folder.path, remaining: candidates.count - n)
                    choice = answer.0
                    if answer.applyToAll { policy = answer.0 }
                }
                switch choice ?? .skip {
                case .keepBoth: destination = NameCollision.uniqueURL(for: destination)
                case .replace: steps.append(.trash(destination))
                case .skip: continue
                case .cancel: return nil
                }
            }
            steps.append(copy ? .copy(from: url, to: destination) : .move(from: url, to: destination))
        }
        if !blocked.isEmpty { onError("Some items weren't moved", blocked.joined(separator: "\n")) }
        guard !steps.isEmpty else { return nil }
        let count = steps.filter { if case .trash = $0 { false } else { true } }.count
        return perform(steps, actionName: copy ? "Copy \(Format.items(Int64(count)))" : "Move \(Format.items(Int64(count)))")
    }

    /// Always moves to the Trash; never deletes permanently.
    @discardableResult
    func trash(_ nodes: [Node]) -> Task<Void, Never>? {
        guard !nodes.isEmpty else { return nil }
        let blocked = nodes.compactMap { ProtectedPaths.reasonBlocked($0) }
        if let first = blocked.first {
            onError(nodes.count == 1 ? "Can't move “\(nodes[0].name)” to the Trash" : "Some items can't be moved to the Trash", first)
            return nil
        }
        let bytes = nodes.reduce(Int64(0)) { $0 + $1.size }
        let count = nodes.reduce(0) { $0 + 1 + Int($1.itemCount) }
        if count > settings.trashConfirmCount || bytes > settings.trashConfirmBytes {
            guard resolver.confirmTrash(count: count, bytes: bytes) else { return nil }
        }
        return perform(nodes.map { .trash($0.url) }, actionName: "Move to Trash")
    }

    /// Creates "untitled folder" (or "untitled folder 2", …) and returns its URL when done.
    func newFolder(in folder: Node) async -> URL? {
        guard folder.isFolder else { return nil }
        if let reason = ProtectedPaths.reasonBlocked(destination: folder.path) {
            onError("Can't create a folder in “\(folder.name)”", reason)
            return nil
        }
        let url = NameCollision.uniqueURL(for: folder.url.appendingPathComponent("untitled folder"))
        await perform([.makeDirectory(url)], actionName: "New Folder").value
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Engine

    /// Runs steps and registers their inverse for undo. Called again (with the inverse) by undo,
    /// which makes the registration inside it a redo.
    @discardableResult
    func perform(_ steps: [FileStep], actionName: String) -> Task<Void, Never> {
        let box = InverseBox()
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.performInverse(box, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        let patcher = self.patcher
        let task = Task {
            let outcome = await Self.execute(steps)
            box.steps = outcome.inverse
            box.finished = true
            if !outcome.errors.isEmpty {
                onError("\(actionName) didn't fully succeed", outcome.errors.joined(separator: "\n"))
            }
            do {
                var result = PatchResult()
                for change in outcome.changes {
                    switch change {
                    case let .moved(from, to): result.merge(try await patcher.applyMove(from: from, to: to))
                    case let .appeared(path): result.merge(try await patcher.patch(paths: [path]))
                    }
                }
                onPatch(result)
            } catch {
                Log.fileOps.error("Index update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        lastTask = task
        return task
    }

    private func performInverse(_ box: InverseBox, actionName: String) {
        guard box.finished else {
            onError("Still working", "“\(actionName)” hasn't finished yet, so it can't be undone right now.")
            return
        }
        guard !box.steps.isEmpty else { return }
        perform(box.steps, actionName: actionName)
    }

    enum Change: Sendable {
        case moved(String, String)
        case appeared(String)
    }

    struct Outcome: Sendable {
        var inverse: [FileStep] = []
        var changes: [Change] = []
        var errors: [String] = []
    }

    /// Performs steps on a background thread, stopping at the first failure.
    nonisolated static func execute(_ steps: [FileStep]) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            var outcome = Outcome()
            let fm = FileManager.default
            for step in steps {
                do {
                    switch step {
                    case let .move(from, to):
                        try fm.moveItem(at: from, to: to)
                        outcome.inverse.insert(.move(from: to, to: from), at: 0)
                        outcome.changes.append(.moved(from.path, to.path))
                    case let .copy(from, to):
                        try fm.copyItem(at: from, to: to)
                        outcome.inverse.insert(.trash(to), at: 0)
                        outcome.changes.append(.appeared(to.path))
                    case let .trash(url):
                        var result: NSURL?
                        try fm.trashItem(at: url, resultingItemURL: &result)
                        if let trashed = result as URL? {
                            outcome.inverse.insert(.untrash(from: trashed, to: url), at: 0)
                            outcome.changes.append(.moved(url.path, trashed.path))
                        } else {
                            outcome.changes.append(.appeared(url.path))
                        }
                    case let .untrash(from, to):
                        guard !fm.fileExists(atPath: to.path) else {
                            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to.path])
                        }
                        try fm.moveItem(at: from, to: to)
                        outcome.inverse.insert(.trash(to), at: 0)
                        outcome.changes.append(.moved(from.path, to.path))
                    case let .makeDirectory(url):
                        try fm.createDirectory(at: url, withIntermediateDirectories: false)
                        outcome.inverse.insert(.trash(url), at: 0)
                        outcome.changes.append(.appeared(url.path))
                    }
                } catch {
                    outcome.errors.append(error.localizedDescription)
                    break
                }
            }
            return outcome
        }.value
    }
}
