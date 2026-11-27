import Foundation
import GRDB

/// Read queries against the `node` table. All functions take a `Database` so they can be
/// composed inside one read transaction.
enum NodeQueries {
    /// Folders with more children than this show only the biggest ones plus a "+ N more" box.
    static let childDisplayLimit = 60
    /// How many children to show when a folder is over the limit.
    static let truncatedShowCount = 40

    static func node(_ db: Database, id: Int64) throws -> Node? {
        try Node.fetchOne(db, sql: "SELECT \(Node.columns) FROM node WHERE id = ?", arguments: [id])
    }

    static func node(_ db: Database, path: String) throws -> Node? {
        try Node.fetchOne(db, sql: "SELECT \(Node.columns) FROM node WHERE path = ?", arguments: [path])
    }

    static func nodes(_ db: Database, ids: [Int64]) throws -> [Node] {
        guard !ids.isEmpty else { return [] }
        var result: [Node] = []
        for chunk in stride(from: 0, to: ids.count, by: 500) {
            let slice = Array(ids[chunk..<min(chunk + 500, ids.count)])
            let marks = Array(repeating: "?", count: slice.count).joined(separator: ",")
            result += try Node.fetchAll(db, sql: "SELECT \(Node.columns) FROM node WHERE id IN (\(marks))", arguments: StatementArguments(slice))
        }
        return result
    }

    /// The top-level node (the volume root, or the scan root in tests).
    static func root(_ db: Database) throws -> Node? {
        try Node.fetchOne(db, sql: "SELECT \(Node.columns) FROM node WHERE parent_id IS NULL ORDER BY length(path) LIMIT 1")
    }

    /// Children shown on the map: all of them, or the biggest ones if there are too many.
    static func children(_ db: Database, of parentID: Int64, filter: VisibilityFilter) throws -> ChildPage {
        let total = try childCount(db, of: parentID, filter: filter)
        let nodes: [Node]
        if total <= childDisplayLimit {
            nodes = try Node.fetchAll(db, sql: """
                SELECT \(Node.columns) FROM node WHERE parent_id = ?\(filter.sql())
                """, arguments: [parentID])
        } else {
            nodes = try Node.fetchAll(db, sql: """
                SELECT \(Node.columns) FROM node WHERE parent_id = ?\(filter.sql())
                ORDER BY alloc_size DESC, modified_at DESC LIMIT ?
                """, arguments: [parentID, truncatedShowCount])
        }
        return ChildPage(nodes: sortForDisplay(nodes), total: total)
    }

    /// A page of all children, sorted by name, for the "+ N more" grid.
    static func childrenPage(_ db: Database, of parentID: Int64, filter: VisibilityFilter, offset: Int, limit: Int) throws -> [Node] {
        try Node.fetchAll(db, sql: """
            SELECT \(Node.columns) FROM node WHERE parent_id = ?\(filter.sql())
            ORDER BY is_dir DESC, name COLLATE NOCASE LIMIT ? OFFSET ?
            """, arguments: [parentID, limit, offset])
    }

    static func childCount(_ db: Database, of parentID: Int64, filter: VisibilityFilter) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node WHERE parent_id = ?\(filter.sql())", arguments: [parentID]) ?? 0
    }

    /// Folders first, then by name (case-insensitive, numeric-aware).
    static func sortForDisplay(_ nodes: [Node]) -> [Node] {
        nodes.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Ancestors from the root down to (and including) the node itself.
    static func lineage(_ db: Database, of id: Int64) throws -> [Node] {
        let rows = try Node.fetchAll(db, sql: """
            WITH RECURSIVE up(id, depth) AS (
              SELECT ?, 0
              UNION ALL
              SELECT n.parent_id, up.depth + 1 FROM node n JOIN up ON n.id = up.id WHERE n.parent_id IS NOT NULL
            )
            SELECT \(Node.columns(alias: "n")) FROM up JOIN node n ON n.id = up.id ORDER BY up.depth DESC
            """, arguments: [id])
        return rows
    }

    /// SQL predicate selecting strict descendants of `path` (uses the UNIQUE index on path).
    static func descendantsPredicate(_ path: String, column: String = "path") -> (sql: String, arguments: StatementArguments) {
        if path == "/" { return ("\(column) > '/'", []) }
        return ("(\(column) >= ? AND \(column) < ?)", [path + "/", path + "0"])
    }

    /// Predicate selecting `path` itself and its descendants.
    static func subtreePredicate(_ path: String, column: String = "path") -> (sql: String, arguments: StatementArguments) {
        if path == "/" { return ("1", []) }
        let d = descendantsPredicate(path, column: column)
        var args: StatementArguments = [path]
        args += d.arguments
        return ("(\(column) = ? OR \(d.sql))", args)
    }
}
