import Foundation
import GRDB

/// One row of the `node` table.
struct Node: Sendable, Hashable, Identifiable {
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
    var projectID: Int64?
    var hasAccess: Bool

    /// A directory the map can expand (packages are single items).
    var isFolder: Bool { isDir && !isPackage }
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDir) }

    static let columns = """
        id, parent_id, name, path, is_dir, is_package, is_hidden, is_system, is_link, size, alloc_size, \
        item_count, uti, kind, created_at, modified_at, opened_at, project_id, access
        """

    /// Same columns prefixed with a table alias, for joins.
    static func columns(alias: String) -> String {
        columns.split(separator: ",").map { "\(alias).\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")
    }
}

extension Node: FetchableRecord {
    init(row: Row) {
        id = row[0]
        parentID = row[1]
        name = row[2]
        path = row[3]
        isDir = row[4]
        isPackage = row[5]
        isHidden = row[6]
        isSystem = row[7]
        isLink = row[8]
        size = row[9]
        allocSize = row[10]
        itemCount = row[11]
        uti = row[12]
        kind = FileKind(raw: row[13])
        createdAt = row[14]
        modifiedAt = row[15]
        openedAt = row[16]
        projectID = row[17]
        hasAccess = row[18]
    }
}

/// What the user has chosen to see.
struct VisibilityFilter: Sendable, Equatable {
    var showHidden: Bool
    var showSystem: Bool

    static let everything = VisibilityFilter(showHidden: true, showSystem: true)

    /// SQL predicate fragment (starts with " AND" or is empty).
    func sql(alias: String = "") -> String {
        let p = alias.isEmpty ? "" : alias + "."
        var s = ""
        if !showHidden { s += " AND \(p)is_hidden = 0" }
        if !showSystem { s += " AND \(p)is_system = 0" }
        return s
    }
}

/// A page of children for one folder.
struct ChildPage: Sendable, Equatable {
    var nodes: [Node]
    var total: Int
    var truncated: Bool { total > nodes.count }
}
