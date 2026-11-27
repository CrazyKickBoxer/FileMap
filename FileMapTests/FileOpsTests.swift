import Foundation
import Testing
@testable import FileMap

/// All file operations run inside a temporary folder only.
@MainActor
@Suite("File operations", .serialized)
struct FileOpsTests {
    let tree: TempTree
    let store: IndexStore
    let ops: FileOperations
    let undo: UndoManager
    var errors: [String] = []

    init() async throws {
        tree = try TempTree()
        try tree.file("src/a.txt", bytes: 100)
        try tree.file("src/b.txt", bytes: 200)
        try tree.file("dst/existing.txt", bytes: 50)
        try tree.file("dst/a.txt", bytes: 999)
        store = try await TestIndex.scan(tree.path)
        undo = UndoManager()
        undo.groupsByEvent = false
        ops = FileOperations(store: store, patcher: IndexPatcher(store: store, policy: ScanPolicy()), undoManager: undo, settings: AppSettings(defaults: UserDefaults(suiteName: "filemap-tests-\(UUID())")!))
        ops.resolver = FixedConflictResolver(choice: .keepBoth)
    }

    private func node(_ relative: String) throws -> Node {
        try #require(try TestIndex.node(store, tree.path + "/" + relative))
    }

    private func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: tree.path + "/" + relative) }

    private func run(_ body: () -> Task<Void, Never>?) async {
        undo.beginUndoGrouping()
        let task = body()
        undo.endUndoGrouping()
        await task?.value
    }

    private func undoLast() async {
        undo.undo()
        await ops.lastTask?.value
    }

    private func redoLast() async {
        undo.redo()
        await ops.lastTask?.value
    }

    @Test func renameUndoRedo() async throws {
        let a = try node("src/a.txt")
        await run { ops.rename(a, to: "renamed.txt") }
        #expect(exists("src/renamed.txt") && !exists("src/a.txt"))
        #expect(try node("src/renamed.txt").id == a.id)  // index updated in place, id kept
        await undoLast()
        #expect(exists("src/a.txt") && !exists("src/renamed.txt"))
        #expect(try TestIndex.node(store, tree.path + "/src/a.txt") != nil)
        await redoLast()
        #expect(exists("src/renamed.txt"))
        #expect(try TestIndex.assertConsistent(store).isEmpty)
    }

    @Test func moveWithConflictKeepsBoth() async throws {
        let dst = try node("dst")
        await run { ops.transfer([tree.url("src/a.txt")], into: dst, copy: false) }
        #expect(exists("dst/a 2.txt") && exists("dst/a.txt") && !exists("src/a.txt"))
        #expect(try node("dst").size == 1149)
        #expect(try node("src").size == 200)
        await undoLast()
        #expect(exists("src/a.txt") && !exists("dst/a 2.txt"))
        #expect(try TestIndex.assertConsistent(store).isEmpty)
    }

    @Test func moveSkipConflict() async throws {
        ops.resolver = FixedConflictResolver(choice: .skip)
        let dst = try node("dst")
        await run { ops.transfer([tree.url("src/a.txt"), tree.url("src/b.txt")], into: dst, copy: false) }
        #expect(exists("src/a.txt") && exists("dst/b.txt"))
    }

    @Test func copyAndUndo() async throws {
        let dst = try node("dst")
        await run { ops.transfer([tree.url("src/b.txt")], into: dst, copy: true) }
        #expect(exists("src/b.txt") && exists("dst/b.txt"))
        #expect(try node("dst/b.txt").size == 200)
        await undoLast()  // the copy goes to the Trash, never deleted outright
        #expect(!exists("dst/b.txt") && exists("src/b.txt"))
        #expect(try TestIndex.node(store, tree.path + "/dst/b.txt") == nil)
    }

    @Test func trashAndRestore() async throws {
        let b = try node("src/b.txt")
        await run { ops.trash([b]) }
        #expect(!exists("src/b.txt"))
        #expect(try node("src").size == 100)
        await undoLast()
        #expect(exists("src/b.txt"))
        // The test index doesn't contain ~/.Trash, so the restored row is re-created (in the app the Trash is indexed and ids survive).
        #expect(try node("src/b.txt").size == b.size)
        #expect(try node("src").size == 300)
        #expect(try TestIndex.assertConsistent(store).isEmpty)
    }

    @Test func newFolderAndUndo() async throws {
        let src = try node("src")
        undo.beginUndoGrouping()
        let created = await ops.newFolder(in: src)
        undo.endUndoGrouping()
        let url = try #require(created)
        #expect(url.lastPathComponent == "untitled folder")
        #expect(try TestIndex.node(store, url.path)?.isDir == true)
        await undoLast()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func refusesProtectedAndBadNames() async throws {
        var messages: [String] = []
        ops.onError = { title, _ in messages.append(title) }
        let fakeSystem = Node(id: -1, parentID: nil, name: "System", path: "/System", isDir: true, isPackage: false, isHidden: false,
                              isSystem: true, isLink: false, size: 0, allocSize: 0, itemCount: 0, uti: nil, kind: .folder,
                              createdAt: nil, modifiedAt: nil, openedAt: nil, projectID: nil, hasAccess: true)
        #expect(ops.trash([fakeSystem]) == nil)
        #expect(ops.rename(fakeSystem, to: "Nope") == nil)
        #expect(ops.rename(try node("src/a.txt"), to: "bad/name") == nil)
        #expect(ops.rename(try node("src/a.txt"), to: "b.txt") == nil)  // taken
        let src = try node("src")
        #expect(ops.transfer([tree.url("src")], into: src, copy: false) == nil)  // into itself
        #expect(messages.count == 5)
        #expect(exists("src/a.txt"))
    }

    @Test func largeTrashAsksFirst() async throws {
        ops.resolver = FixedConflictResolver(confirm: false)
        ops.settings.trashConfirmCount = 1
        let nodes = [try node("src/a.txt"), try node("src/b.txt")]
        #expect(ops.trash(nodes) == nil)
        #expect(exists("src/a.txt") && exists("src/b.txt"))
    }
}
