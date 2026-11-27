import Foundation
import Testing
@testable import FileMap

@Suite("Clusters and projects")
struct ClusterTests {
    private func setModified(_ url: URL, daysAgo: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
    }

    @Test("Type clusters gather files from every folder")
    func byType() async throws {
        let tree = try TempTree()
        try tree.file("a/one.jpg", bytes: 100)
        try tree.file("b/c/two.png", bytes: 200)
        try tree.file("d/three.mp4", bytes: 300)
        try tree.file("e/notes.txt", bytes: 50)
        let store = try await TestIndex.scan(tree.path)
        let q = ClusterQuery(grouping: .type, dateColumn: "modified_at", filter: .everything, scopePath: tree.path)
        let groups = try store.readNow { db in try q.groups(db, path: []) }
        let pictures = try #require(groups.first { $0.value == "picture" })
        #expect(pictures.count == 2)
        #expect(pictures.size == 300)
        #expect(groups.first { $0.value == "video" }?.count == 1)
        // Sub-groups: year, then month; items at the bottom.
        let years = try store.readNow { db in try q.groups(db, path: ["picture"]) }
        #expect(years.count == 1)
        let year = try #require(years.first).value
        let months = try store.readNow { db in try q.groups(db, path: ["picture", year]) }
        let items = try store.readNow { db in try q.items(db, path: ["picture", year, try #require(months.first).value], limit: 10) }
        #expect(items.total == 2)
        #expect(items.nodes.first?.name == "two.png")  // biggest first
    }

    @Test("Date clusters bucket by today, this year, and older years")
    func byDate() async throws {
        let tree = try TempTree()
        try tree.file("now.txt", bytes: 1)
        try setModified(try tree.file("old.txt", bytes: 1), daysAgo: 800)
        let store = try await TestIndex.scan(tree.path)
        let q = ClusterQuery(grouping: .date, dateColumn: "modified_at", filter: .everything, scopePath: tree.path)
        let groups = try store.readNow { db in try q.groups(db, path: []) }
        #expect(groups.first?.value == "1today")
        #expect(groups.first?.title == "Today")
        let old = try #require(groups.last)
        #expect(old.value.hasPrefix("y"))
        #expect(old.count == 1)
    }

    @Test("Scope limits clustering to one folder")
    func scope() async throws {
        let tree = try TempTree()
        try tree.file("in/a.jpg", bytes: 1)
        try tree.file("out/b.jpg", bytes: 1)
        let store = try await TestIndex.scan(tree.path)
        let q = ClusterQuery(grouping: .type, dateColumn: "modified_at", filter: .everything, scopePath: tree.path + "/in")
        let groups = try store.readNow { db in try q.groups(db, path: []) }
        #expect(groups.first { $0.value == "picture" }?.count == 1)
    }

    @Test("Project roots: outermost wins, dependencies are ignored, type by priority")
    func chooseRoots() {
        let roots = ProjectDetector.chooseRoots(markers: [
            (1, "/Users/me/code/app", ".git"),
            (1, "/Users/me/code/app", "App.xcodeproj"),
            (2, "/Users/me/code/app/Packages/Kit", "Package.swift"),
            (3, "/Users/me/code/web", "package.json"),
            (4, "/Users/me/code/web/node_modules/left-pad", "package.json"),
            (5, "/Users/me/Library/Caches/thing", "Cargo.toml"),
            (6, "/usr/local/lib/x", "CMakeLists.txt"),
        ])
        #expect(roots.map(\.path) == ["/Users/me/code/app", "/Users/me/code/web"])
        #expect(roots.first?.type == "xcode")
        #expect(roots.last?.type == "node")
    }

    @Test("Detected projects tag their files and cluster together")
    func detectAndCluster() async throws {
        let tree = try TempTree()
        try tree.file("Game/project.godot", bytes: 10)
        try tree.file("Game/scenes/main.tscn", bytes: 20)
        try tree.file("Tool/Cargo.toml", bytes: 5)
        try tree.file("Tool/src/main.rs", bytes: 40)
        try tree.file("loose.txt", bytes: 1)
        let store = try await TestIndex.scan(tree.path)
        let game = try #require(try TestIndex.node(store, tree.path + "/Game/scenes/main.tscn"))
        let tool = try #require(try TestIndex.node(store, tree.path + "/Tool/src/main.rs"))
        #expect(game.projectID != nil)
        #expect(tool.projectID != nil && tool.projectID != game.projectID)
        #expect(try TestIndex.node(store, tree.path + "/loose.txt")?.projectID == nil)
        let q = ClusterQuery(grouping: .project, dateColumn: "modified_at", filter: .everything, scopePath: tree.path)
        let groups = try store.readNow { db in try q.groups(db, path: []) }
        #expect(Set(groups.map(\.title)) == ["Game", "Tool", "No Project"])
        #expect(groups.last?.title == "No Project")
        #expect(groups.first { $0.title == "Game" }?.count == 2)
    }
}
