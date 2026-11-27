import Foundation
import Testing
@testable import FileMap

@Suite("Watcher patching")
struct PatcherTests {
    private func patcher(_ store: IndexStore) -> IndexPatcher {
        IndexPatcher(store: store, policy: ScanPolicy())
    }

    @Test("New, changed, and deleted files keep folder totals exact")
    func filesChange() async throws {
        let tree = try TempTree()
        try tree.file("a/one.txt", bytes: 1000)
        try tree.file("a/b/two.txt", bytes: 2000)
        let store = try await TestIndex.scan(tree.path)
        let p = patcher(store)

        let added = try tree.file("a/b/three.txt", bytes: 3000)
        var result = try await p.patch(paths: [added.path])
        #expect(result.changedParents.contains(try #require(try TestIndex.node(store, tree.path + "/a/b")).id))
        #expect(try TestIndex.node(store, tree.path)?.size == 6000)
        #expect(try TestIndex.node(store, tree.path)?.itemCount == 5)

        try Data(repeating: 1, count: 500).write(to: tree.url("a/one.txt"))
        _ = try await p.patch(paths: [tree.path + "/a/one.txt"])
        #expect(try TestIndex.node(store, tree.path + "/a")?.size == 5500)

        try FileManager.default.removeItem(at: tree.url("a/b"))
        result = try await p.patch(paths: [tree.path + "/a/b"])
        #expect(!result.removedNodes.isEmpty)
        #expect(try TestIndex.node(store, tree.path + "/a/b/two.txt") == nil)
        #expect(try TestIndex.node(store, tree.path)?.size == 500)
        #expect(try TestIndex.node(store, tree.path)?.itemCount == 2)
        #expect(try TestIndex.assertConsistent(store).isEmpty)
    }

    @Test("A new folder tree is walked; parents missing from the index are created")
    func newFolders() async throws {
        let tree = try TempTree()
        try tree.file("x.txt", bytes: 10)
        let store = try await TestIndex.scan(tree.path)
        try tree.file("new/inner/deep/file.bin", bytes: 4096)
        try tree.file("new/top.bin", bytes: 100)
        // Report only the deepest path, as FSEvents might.
        _ = try await patcher(store).patch(paths: [tree.path + "/new/inner/deep/file.bin"])
        #expect(try TestIndex.node(store, tree.path + "/new/top.bin") != nil)
        #expect(try TestIndex.node(store, tree.path)?.size == 4206)
        #expect(try TestIndex.assertConsistent(store).isEmpty)
    }

    @Test("Patching is idempotent")
    func idempotent() async throws {
        let tree = try TempTree()
        try tree.file("a/b.txt", bytes: 300)
        let store = try await TestIndex.scan(tree.path)
        let before = try TestIndex.node(store, tree.path)
        let result = try await patcher(store).patch(paths: [tree.path + "/a/b.txt", tree.path + "/a", tree.path])
        #expect(try TestIndex.node(store, tree.path)?.size == before?.size)
        #expect(try TestIndex.node(store, tree.path)?.itemCount == before?.itemCount)
        #expect(result.changedParents.isEmpty)
    }

    @Test("Recursive rescan after lost history matches a fresh scan")
    func subtreeRescan() async throws {
        let tree = try TempTree()
        try tree.file("a/1.txt", bytes: 100)
        let store = try await TestIndex.scan(tree.path)
        try tree.file("a/2.txt", bytes: 200)
        try tree.file("a/sub/3.txt", bytes: 300)
        try FileManager.default.removeItem(at: tree.url("a/1.txt"))
        _ = try await patcher(store).patch(paths: [tree.path + "/a"], recursive: true)
        let fresh = try await TestIndex.scan(tree.path)
        #expect(try TestIndex.node(store, tree.path)?.size == TestIndex.node(fresh, tree.path)?.size)
        #expect(try TestIndex.node(store, tree.path)?.itemCount == TestIndex.node(fresh, tree.path)?.itemCount)
        #expect(try TestIndex.assertConsistent(store).isEmpty)
    }

    @Test("Moves keep row ids and fix totals on both sides")
    func moveKeepsIDs() async throws {
        let tree = try TempTree()
        try tree.file("from/folder/f.txt", bytes: 700)
        try tree.dir("to")
        let store = try await TestIndex.scan(tree.path)
        let id = try #require(try TestIndex.node(store, tree.path + "/from/folder")).id
        try FileManager.default.moveItem(at: tree.url("from/folder"), to: tree.url("to/folder"))
        _ = try await patcher(store).applyMove(from: tree.path + "/from/folder", to: tree.path + "/to/folder")
        #expect(try TestIndex.node(store, tree.path + "/to/folder")?.id == id)
        #expect(try TestIndex.node(store, tree.path + "/to/folder/f.txt") != nil)
        #expect(try TestIndex.node(store, tree.path + "/from")?.size == 0)
        #expect(try TestIndex.node(store, tree.path + "/to")?.size == 700)
        #expect(try TestIndex.assertConsistent(store).isEmpty)
    }

    @Test("FSEvents data-volume paths are normalised")
    func normalise() {
        #expect(IndexPatcher.normalize("/System/Volumes/Data/Users/me/x") == "/Users/me/x")
        #expect(IndexPatcher.normalize("/Users/me/") == "/Users/me")
    }
}
