import Foundation
import GRDB

enum ClusterGrouping: String, CaseIterable, Identifiable, Sendable {
    case type, date, project
    var id: String { rawValue }
    var title: String {
        switch self {
        case .type: "Type"
        case .date: "Date"
        case .project: "Project"
        }
    }
}

/// One cluster or sub-group with its totals.
struct GroupSummary: Sendable, Equatable {
    var value: String
    var title: String
    var size: Int64
    var count: Int64
}

/// SQL for cluster view. Everything runs against the index; nothing walks the disk.
struct ClusterQuery: Sendable {
    enum Level: Sendable { case kind, year, month, dateBucket, project }

    var grouping: ClusterGrouping
    var dateColumn: String
    var filter: VisibilityFilter
    var scopePath: String?
    var now = Date()

    /// The levels of nesting for each grouping (items sit below the last one).
    var levels: [Level] {
        switch grouping {
        case .type: [.kind, .year, .month]
        case .date: [.dateBucket, .kind]
        case .project: [.project, .kind]
        }
    }

    func expression(_ level: Level) -> String {
        switch level {
        case .kind: return "kind"
        case .year: return "COALESCE(strftime('%Y', \(dateColumn), 'unixepoch', 'localtime'), 'Unknown')"
        case .month: return "COALESCE(strftime('%m', \(dateColumn), 'unixepoch', 'localtime'), '00')"
        case .project: return "COALESCE(project_id, 0)"
        case .dateBucket:
            let cal = Calendar.current
            let today = cal.startOfDay(for: now).timeIntervalSince1970
            let week = (cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now).timeIntervalSince1970
            let month = (cal.dateInterval(of: .month, for: now)?.start ?? now).timeIntervalSince1970
            let year = (cal.dateInterval(of: .year, for: now)?.start ?? now).timeIntervalSince1970
            let c = dateColumn
            return """
                (CASE WHEN \(c) IS NULL THEN 'none' WHEN \(c) >= \(today) THEN '1today' WHEN \(c) >= \(week) THEN '2week' \
                WHEN \(c) >= \(month) THEN '3month' WHEN \(c) >= \(year) THEN '4year' \
                ELSE 'y' || strftime('%Y', \(c), 'unixepoch', 'localtime') END)
                """
        }
    }

    /// WHERE clause for items matching the given parent values.
    func whereClause(path: [String]) -> (String, StatementArguments) {
        var sql = "(is_dir = 0 OR is_package = 1)" + filter.sql()
        var args = StatementArguments()
        if let scopePath {
            let p = NodeQueries.descendantsPredicate(scopePath)
            sql += " AND " + p.sql
            args += p.arguments
        }
        for (level, value) in zip(levels, path) {
            sql += " AND \(expression(level)) = ?"
            if level == .project { args += [Int64(value) ?? 0] } else { args += [value] }
        }
        return (sql, args)
    }

    /// Sub-groups one level below `path` (clusters when `path` is empty).
    func groups(_ db: Database, path: [String]) throws -> [GroupSummary] {
        guard path.count < levels.count else { return [] }
        let level = levels[path.count]
        let (w, args) = whereClause(path: path)
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(expression(level)) AS g, SUM(size), COUNT(*) FROM node WHERE \(w) GROUP BY g
            """, arguments: args)
        var projects: [Int64: String] = [:]
        if level == .project {
            for r in try Row.fetchAll(db, sql: "SELECT id, name FROM project") { projects[r[0]] = r[1] }
        }
        var result = rows.map { row -> GroupSummary in
            let value: String = level == .project ? String(row[0] as Int64) : (row[0] as String? ?? "")
            return GroupSummary(value: value, title: title(level, value: value, path: path, projects: projects),
                                size: row[1] ?? 0, count: row[2] ?? 0)
        }
        result.sort { a, b in sortKey(level, a) < sortKey(level, b) }
        return result
    }

    func items(_ db: Database, path: [String], limit: Int) throws -> (nodes: [Node], total: Int) {
        let (w, args) = whereClause(path: path)
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node WHERE \(w)", arguments: args) ?? 0
        var a = args
        a += [limit]
        let nodes = try Node.fetchAll(db, sql: "SELECT \(Node.columns) FROM node WHERE \(w) ORDER BY size DESC LIMIT ?", arguments: a)
        return (nodes, total)
    }

    private func sortKey(_ level: Level, _ g: GroupSummary) -> String {
        switch level {
        case .kind: return String(format: "%02d", FileKind.fileKinds.firstIndex(of: FileKind(raw: g.value)) ?? 99)
        case .year, .month: return String(9999 - (Int(g.value) ?? 0))  // newest first
        case .dateBucket:
            if g.value == "none" { return "z" }
            if g.value.hasPrefix("y") { return "5" + String(9999 - (Int(g.value.dropFirst()) ?? 0)) }
            return g.value
        case .project: return g.value == "0" ? "~" : g.title.lowercased()  // "No project" last
        }
    }

    private func title(_ level: Level, value: String, path: [String], projects: [Int64: String]) -> String {
        switch level {
        case .kind: return FileKind(raw: value).displayName
        case .year: return value
        case .month:
            guard let m = Int(value), m >= 1, m <= 12 else { return "Unknown" }
            let year = path.last ?? ""
            return "\(DateFormatter().monthSymbols[m - 1]) \(year)"
        case .dateBucket:
            switch value {
            case "1today": return "Today"
            case "2week": return "This Week"
            case "3month": return "This Month"
            case "4year": return "This Year"
            case "none": return "No Date"
            default: return String(value.dropFirst())
            }
        case .project:
            let id = Int64(value) ?? 0
            return id == 0 ? "No Project" : (projects[id] ?? "Project \(id)")
        }
    }
}
