import Foundation
import GRDB

/// A row ready to insert (produced by the scanner and the patcher).
struct NodeRow: Sendable {
    var id: Int64
    var parentID: Int64?
    var name: String
    var path: String
    var isDir: Bool
    var isPackage: Bool
    var isHidden: Bool
    var isSystem: Bool
    var isLink: Bool
    var size: Int64
    var allocSize: Int64
    var itemCount: Int64
    var uti: String?
    var kind: FileKind
    var createdAt: Double?
    var modifiedAt: Double?
    var openedAt: Double?
    var hasAccess: Bool
}

/// Size/count contribution of a subtree to its ancestors.
struct Totals: Sendable, Equatable {
    var size: Int64 = 0
    var alloc: Int64 = 0
    var count: Int64 = 0

    static func + (a: Totals, b: Totals) -> Totals { Totals(size: a.size + b.size, alloc: a.alloc + b.alloc, count: a.count + b.count) }
    static func - (a: Totals, b: Totals) -> Totals { Totals(size: a.size - b.size, alloc: a.alloc - b.alloc, count: a.count - b.count) }
    static prefix func - (a: Totals) -> Totals { Totals(size: -a.size, alloc: -a.alloc, count: -a.count) }
    var isZero: Bool { size == 0 && alloc == 0 && count == 0 }

    /// What a node adds to its parent: its own totals plus one for itself.
    static func contribution(of node: Node) -> Totals {
        Totals(size: node.size, alloc: node.allocSize, count: node.itemCount + 1)
    }
}

enum NodeWrites {
    static let insertSQL = """
        INSERT OR IGNORE INTO node (id, parent_id, name, path, is_dir, is_package, is_hidden, is_system, is_link,
          size, alloc_size, item_count, uti, kind, created_at, modified_at, opened_at, access, project_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    static func insert(_ db: Database, rows: [NodeRow], projectID: Int64? = nil) throws {
        guard !rows.isEmpty else { return }
        let stmt = try db.cachedStatement(sql: insertSQL)
        for r in rows {
            try stmt.execute(arguments: [
                r.id, r.parentID, r.name, r.path, r.isDir, r.isPackage, r.isHidden, r.isSystem, r.isLink,
                r.size, r.allocSize, r.itemCount, r.uti, r.kind.rawValue, r.createdAt, r.modifiedAt, r.openedAt,
                r.hasAccess, projectID,
            ])
        }
    }

    static func setTotals(_ db: Database, id: Int64, totals: Totals, access: Bool = true) throws {
        try db.execute(sql: "UPDATE node SET size = ?, alloc_size = ?, item_count = ?, access = ? WHERE id = ?",
                       arguments: [totals.size, totals.alloc, totals.count, access, id])
    }

    /// Adds `delta` to the node `startID` and every ancestor above it.
    static func applyDelta(_ db: Database, from startID: Int64?, delta: Totals) throws {
        guard let startID, !delta.isZero else { return }
        try db.execute(sql: """
            WITH RECURSIVE up(id) AS (
              SELECT ?
              UNION ALL
              SELECT n.parent_id FROM node n JOIN up ON n.id = up.id WHERE n.parent_id IS NOT NULL
            )
            UPDATE node SET size = size + ?, alloc_size = alloc_size + ?, item_count = item_count + ?
            WHERE id IN (SELECT id FROM up)
            """, arguments: [startID, delta.size, delta.alloc, delta.count])
    }

    /// Ids of `startID` and its ancestors.
    static func lineageIDs(_ db: Database, from startID: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            WITH RECURSIVE up(id) AS (
              SELECT ? UNION ALL SELECT n.parent_id FROM node n JOIN up ON n.id = up.id WHERE n.parent_id IS NOT NULL
            ) SELECT id FROM up
            """, arguments: [startID])
    }

    /// Deletes the descendants of `path` (and the node itself if `includeRoot`).
    static func deleteSubtree(_ db: Database, path: String, includeRoot: Bool) throws {
        let p = includeRoot ? NodeQueries.subtreePredicate(path) : NodeQueries.descendantsPredicate(path)
        try db.execute(sql: "DELETE FROM node WHERE \(p.sql)", arguments: p.arguments)
    }

    /// Re-homes a subtree after a move or rename, keeping row ids (so pins follow).
    static func moveSubtree(_ db: Database, node: Node, toPath newPath: String, newParentID: Int64) throws {
        let oldPath = node.path
        let d = NodeQueries.descendantsPredicate(oldPath)
        // Rewrite descendants' paths: newPath + suffix after oldPath.
        var args: StatementArguments = [newPath, oldPath.count + 1]
        args += d.arguments
        try db.execute(sql: "UPDATE node SET path = ? || substr(path, ?) WHERE \(d.sql)", arguments: args)
        try db.execute(sql: "UPDATE node SET path = ?, name = ?, parent_id = ? WHERE id = ?",
                       arguments: [newPath, newPath.lastPathComponentFast, newParentID, node.id])
    }
}

/// Small key/value table for scan state and the last FSEvents id.
enum Meta {
    static func get(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    static func set(_ db: Database, _ key: String, _ value: String?) throws {
        if let value {
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
        }
    }

    static func getJSON<T: Decodable>(_ db: Database, _ key: String, as type: T.Type) throws -> T? {
        guard let s = try get(db, key), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func setJSON<T: Encodable>(_ db: Database, _ key: String, _ value: T) throws {
        let data = try JSONEncoder().encode(value)
        try set(db, key, String(decoding: data, as: UTF8.self))
    }
}
