import Foundation
import GRDB

/// Finds project roots by marker files and tags every node inside with its project id.
enum ProjectDetector {
    /// Marker name → project type. Order in `priority` decides the type when several markers exist.
    static let exactMarkers: [String: String] = [
        ".git": "git", "Package.swift": "swift", "package.json": "node", "pyproject.toml": "python",
        "requirements.txt": "python", "Cargo.toml": "rust", "build.gradle": "gradle", "build.gradle.kts": "gradle",
        "project.godot": "godot", "CMakeLists.txt": "cmake",
    ]
    static let suffixMarkers: [String: String] = [".xcodeproj": "xcode", ".xcworkspace": "xcode"]
    static let priority = ["xcode", "swift", "rust", "godot", "node", "python", "gradle", "cmake", "git"]

    /// Path components that mean "this is a dependency or cache, not a project of yours".
    static let ignoredComponents: Set<String> = [
        "node_modules", ".build", "Pods", "Carthage", "DerivedData", "site-packages", "vendor", ".cargo", ".rustup",
        ".npm", ".pnpm-store", "Library", ".Trash", ".venv", "venv", "bower_components", ".gradle", "checkouts",
        "SourcePackages", ".swiftpm", "Caches",
    ]

    struct Candidate: Sendable, Equatable {
        var path: String
        var rootNodeID: Int64
        var type: String
    }

    /// Pure function so it can be unit-tested: picks outermost project roots from marker hits.
    static func chooseRoots(markers: [(parentID: Int64, parentPath: String, marker: String)]) -> [Candidate] {
        var byRoot: [String: (Int64, Set<String>)] = [:]
        for m in markers {
            guard let type = exactMarkers[m.marker] ?? suffixMarkers.first(where: { m.marker.hasSuffix($0.key) })?.value else { continue }
            if ScanPolicy.isSystem(m.parentPath) { continue }
            if m.parentPath.split(separator: "/").contains(where: { ignoredComponents.contains(String($0)) }) { continue }
            byRoot[m.parentPath, default: (m.parentID, [])].1.insert(type)
        }
        var result: [Candidate] = []
        var accepted: [String] = []
        for path in byRoot.keys.sorted() {
            if accepted.contains(where: { path.isInside($0) }) { continue }
            guard let (id, types) = byRoot[path] else { continue }
            let type = priority.first(where: types.contains) ?? "git"
            accepted.append(path)
            result.append(Candidate(path: path, rootNodeID: id, type: type))
        }
        return result
    }

    static func detect(store: IndexStore) throws {
        let names = exactMarkers.keys.map { "'\($0)'" }.joined(separator: ",")
        let markers = try store.readNow { db in
            try Row.fetchAll(db, sql: """
                SELECT n.parent_id, p.path, n.name FROM node n JOIN node p ON p.id = n.parent_id
                WHERE n.name IN (\(names)) OR n.name LIKE '%.xcodeproj' OR n.name LIKE '%.xcworkspace'
                """).map { (parentID: $0[0] as Int64, parentPath: $0[1] as String, marker: $0[2] as String) }
        }
        let roots = chooseRoots(markers: markers)
        try store.writeNow { db in
            try db.execute(sql: "UPDATE node SET project_id = NULL WHERE project_id IS NOT NULL")
            try db.execute(sql: "DELETE FROM project")
            for root in roots {
                try db.execute(sql: "INSERT INTO project (root_node_id, name, type) VALUES (?, ?, ?)",
                               arguments: [root.rootNodeID, root.path.lastPathComponentFast, root.type])
                let projectID = db.lastInsertedRowID
                let p = NodeQueries.subtreePredicate(root.path)
                var args: StatementArguments = [projectID]
                args += p.arguments
                try db.execute(sql: "UPDATE node SET project_id = ? WHERE \(p.sql)", arguments: args)
            }
        }
        Log.clusters.info("Detected \(roots.count) projects")
    }
}
