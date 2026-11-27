import Foundation
import Testing
@testable import FileMap

@Suite("Scanner")
struct ScannerTests {
    @Test("Sizes and counts roll up to every folder")
    func rollUps() async throws {
        let tree = try TempTree()
        try tree.file("a.txt", bytes: 1000)
        try tree.file("docs/b.txt", bytes: 2000)
        try tree.file("docs/deep/c.txt", bytes: 3000)
        try tree.file("docs/deep/d.txt", bytes: 4000)
        try tree.dir("empty")
        try tree.file("x/y/z/w/v/u/far.bin", bytes: 5000)

        let store = try await TestIndex.scan(tree.path)
        let root = try #require(try TestIndex.node(store, tree.path))
        #expect(root.size == 15_000)
        // a.txt, docs, b.txt, deep, c, d, empty, x, y, z, w, v, u, far.bin
        #expect(root.itemCount == 14)
        let docs = try #require(try TestIndex.node(store, tree.path + "/docs"))
        #expect(docs.size == 9000)
        #expect(docs.itemCount == 4)
        let deep = try #require(try TestIndex.node(store, tree.path + "/docs/deep"))
        #expect(deep.size == 7000)
        #expect(deep.itemCount == 2)
        let empty = try #require(try TestIndex.node(store, tree.path + "/empty"))
        #expect(empty.size == 0 && empty.itemCount == 0)
        #expect(try TestIndex.assertConsistent(store).isEmpty)
    }

    @Test("Packages are single items with their full size")
    func packages() async throws {
        let tree = try TempTree()
        try tree.file("Thing.app/Contents/MacOS/Thing", bytes: 7000)
        try tree.file("Thing.app/Contents/Info.plist", bytes: 500)
        let store = try await TestIndex.scan(tree.path)
        let app = try #require(try TestIndex.node(store, tree.path + "/Thing.app"))
        #expect(app.isPackage)
        #expect(app.size == 7500)
        #expect(app.kind == .app)
        #expect(try TestIndex.node(store, tree.path + "/Thing.app/Contents") == nil)
        let root = try #require(try TestIndex.node(store, tree.path))
        #expect(root.itemCount == 1)
        #expect(root.size == 7500)
    }

    @Test("Symlinks are recorded, not followed")
    func symlinks() async throws {
        let tree = try TempTree()
        try tree.file("real/data.bin", bytes: 9000)
        try FileManager.default.createSymbolicLink(atPath: tree.path + "/link", withDestinationPath: tree.path + "/real")
        let store = try await TestIndex.scan(tree.path)
        let link = try #require(try TestIndex.node(store, tree.path + "/link"))
        #expect(link.isLink)
        #expect(!link.isDir)
        #expect(try TestIndex.node(store, tree.path + "/link/data.bin") == nil)
    }

    @Test("Hard links count their disk space once")
    func hardLinks() async throws {
        let tree = try TempTree()
        let original = try tree.file("one/big.bin", bytes: 64_000)
        try tree.dir("two")
        try FileManager.default.linkItem(at: original, to: tree.url("two/big.bin"))
        let store = try await TestIndex.scan(tree.path)
        let root = try #require(try TestIndex.node(store, tree.path))
        let single = try #require(try TestIndex.node(store, tree.path + "/one/big.bin"))
        #expect(root.allocSize == single.allocSize)
        #expect(root.size == 128_000)  // logical size still counts both names
    }

    @Test("Folders without permission are marked and skipped quietly")
    func noAccess() async throws {
        let tree = try TempTree()
        try tree.file("open/a.txt", bytes: 100)
        let locked = try tree.dir("locked")
        try tree.file("locked/secret.txt", bytes: 100)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let store = try await TestIndex.scan(tree.path)
        let node = try #require(try TestIndex.node(store, locked.path))
        #expect(!node.hasAccess)
        #expect(try TestIndex.node(store, tree.path + "/open/a.txt") != nil)
    }

    @Test("Hidden files and kinds are classified")
    func classification() async throws {
        let tree = try TempTree()
        try tree.file(".hidden", bytes: 1)
        try tree.file("photo.jpg", bytes: 1)
        try tree.file("movie.mov", bytes: 1)
        try tree.file("song.mp3", bytes: 1)
        try tree.file("main.swift", bytes: 1)
        try tree.file("notes.pdf", bytes: 1)
        try tree.file("backup.zip", bytes: 1)
        let store = try await TestIndex.scan(tree.path)
        #expect(try TestIndex.node(store, tree.path + "/.hidden")?.isHidden == true)
        #expect(try TestIndex.node(store, tree.path + "/photo.jpg")?.kind == .picture)
        #expect(try TestIndex.node(store, tree.path + "/movie.mov")?.kind == .video)
        #expect(try TestIndex.node(store, tree.path + "/song.mp3")?.kind == .audio)
        #expect(try TestIndex.node(store, tree.path + "/main.swift")?.kind == .code)
        #expect(try TestIndex.node(store, tree.path + "/notes.pdf")?.kind == .document)
        #expect(try TestIndex.node(store, tree.path + "/backup.zip")?.kind == .archive)
    }

    @Test("Excluded folders are not scanned")
    func exclusions() async throws {
        let tree = try TempTree()
        try tree.file("keep/a.txt", bytes: 10)
        try tree.file("skip/b.txt", bytes: 10)
        let store = try await TestIndex.scan(tree.path, policy: ScanPolicy(excludedPaths: [tree.path + "/skip"]))
        #expect(try TestIndex.node(store, tree.path + "/skip") == nil)
        #expect(try TestIndex.node(store, tree.path + "/keep/a.txt") != nil)
    }

    @Test("System paths are flagged")
    func systemFlags() {
        #expect(ScanPolicy.isSystem("/System/Library"))
        #expect(ScanPolicy.isSystem("/usr"))
        #expect(!ScanPolicy.isSystem("/Users/someone"))
        #expect(!ScanPolicy.isSystem("/Systemic"))
        #expect(ScanPolicy().shouldSkip("/System/Volumes"))
        #expect(ScanPolicy().shouldSkip("/.nofollow"))
    }
}
