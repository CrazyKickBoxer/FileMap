import Foundation
import GRDB

struct SearchFilters: Sendable, Equatable {
    var kind: FileKind?
    var minSize: Int64 = 0
    /// Only items modified within this many days (nil = any time).
    var modifiedWithinDays: Int?
}

enum SearchQueries {
    /// Name search. Uses the trigram FTS index for 3+ characters, an index-backed prefix match otherwise.
    static func search(_ db: Database, text: String, filters: SearchFilters, visibility: VisibilityFilter, limit: Int = 200,
                       now: Date = Date()) throws -> [Node] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        var conditions = visibility.sql(alias: "n")
        var args = StatementArguments()
        if let kind = filters.kind {
            conditions += " AND n.kind = ?"
            args += [kind.rawValue]
        }
        if filters.minSize > 0 {
            conditions += " AND n.size >= ?"
            args += [filters.minSize]
        }
        if let days = filters.modifiedWithinDays {
            conditions += " AND n.modified_at >= ?"
            args += [now.timeIntervalSince1970 - Double(days) * 86_400]
        }
        if term.count >= 3 {
            let phrase = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            var a: StatementArguments = [phrase]
            a += args
            a += [limit]
            return try Node.fetchAll(db, sql: """
                SELECT \(Node.columns(alias: "n")) FROM node_fts f JOIN node n ON n.id = f.rowid
                WHERE node_fts MATCH ?\(conditions)
                ORDER BY (lower(n.name) = lower(\(sqlLiteral(term)))) DESC, f.rank, length(n.path) LIMIT ?
                """, arguments: a)
        }
        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        var a: StatementArguments = [escaped + "%"]
        a += args
        a += [limit]
        return try Node.fetchAll(db, sql: """
            SELECT \(Node.columns(alias: "n")) FROM node n
            WHERE n.name LIKE ? ESCAPE '\\'\(conditions)
            ORDER BY length(n.name), length(n.path) LIMIT ?
            """, arguments: a)
    }

    private static func sqlLiteral(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
