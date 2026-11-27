import Foundation
import GRDB
import Synchronization

/// Owns the SQLite database (WAL mode via `DatabasePool`).
final class IndexStore: Sendable {
    let pool: DatabasePool
    let url: URL
    let ids: IDAllocator

    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("FileMap", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.sqlite")
    }

    /// The folder holding the database; the watcher ignores events from it.
    var directoryPath: String { url.deletingLastPathComponent().path }

    init(url: URL) throws {
        self.url = url
        var config = Configuration()
        config.foreignKeysEnabled = false  // bulk inserts are faster; integrity is maintained by the scanner
        config.label = "FileMapIndex"
        config.maximumReaderCount = 6
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA cache_size = -65536")
        }
        pool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(pool)
        let maxID = try pool.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM node") ?? 0 }
        ids = IDAllocator(start: maxID + 1)
    }

    // MARK: Access helpers

    /// Synchronous read, for background actors and tasks (never call on the main actor).
    func readNow<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.read(body)
    }

    /// Synchronous write, for background actors and tasks.
    func writeNow<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.write(body)
    }

    func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await pool.read(body)
    }

    func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await pool.write(body)
    }

    // MARK: Schema

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE project (id INTEGER PRIMARY KEY, root_node_id INTEGER, name TEXT, type TEXT);
                CREATE TABLE node (
                  id            INTEGER PRIMARY KEY,
                  parent_id     INTEGER REFERENCES node(id),
                  name          TEXT NOT NULL,
                  path          TEXT NOT NULL UNIQUE,
                  is_dir        INTEGER NOT NULL,
                  is_package    INTEGER NOT NULL DEFAULT 0,
                  is_hidden     INTEGER NOT NULL DEFAULT 0,
                  is_system     INTEGER NOT NULL DEFAULT 0,
                  is_link       INTEGER NOT NULL DEFAULT 0,
                  size          INTEGER NOT NULL DEFAULT 0,
                  alloc_size    INTEGER NOT NULL DEFAULT 0,
                  item_count    INTEGER NOT NULL DEFAULT 0,
                  uti           TEXT,
                  kind          TEXT,
                  created_at    REAL,
                  modified_at   REAL,
                  opened_at     REAL,
                  project_id    INTEGER REFERENCES project(id),
                  access        INTEGER NOT NULL DEFAULT 1
                );
                CREATE INDEX node_parent ON node(parent_id);
                CREATE INDEX node_kind ON node(kind);
                CREATE INDEX node_modified ON node(modified_at);
                CREATE INDEX node_name ON node(name COLLATE NOCASE);
                CREATE INDEX node_project ON node(project_id);
                CREATE VIRTUAL TABLE node_fts USING fts5(name, content='node', content_rowid='id', tokenize='trigram');
                CREATE TABLE pin (id INTEGER PRIMARY KEY, node_id INTEGER, label TEXT, sort INTEGER, path TEXT, bookmark BLOB);
                CREATE TABLE layout_cache (node_id INTEGER PRIMARY KEY, x REAL, y REAL, w REAL, h REAL);
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
                """)
            try installFTSTriggers(db)
        }
        m.registerMigration("v2-cluster-index") { db in
            // Covering index so cluster grouping never touches the main table.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS node_cluster ON node(kind, is_dir, is_package, is_hidden, is_system, modified_at, size)")
        }
        return m
    }

    static func installFTSTriggers(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS node_ai AFTER INSERT ON node BEGIN
              INSERT INTO node_fts(rowid, name) VALUES (new.id, new.name);
            END;
            CREATE TRIGGER IF NOT EXISTS node_ad AFTER DELETE ON node BEGIN
              INSERT INTO node_fts(node_fts, rowid, name) VALUES ('delete', old.id, old.name);
            END;
            CREATE TRIGGER IF NOT EXISTS node_au AFTER UPDATE OF name ON node BEGIN
              INSERT INTO node_fts(node_fts, rowid, name) VALUES ('delete', old.id, old.name);
              INSERT INTO node_fts(rowid, name) VALUES (new.id, new.name);
            END;
            """)
    }

    static func dropFTSTriggers(_ db: Database) throws {
        try db.execute(sql: "DROP TRIGGER IF EXISTS node_ai; DROP TRIGGER IF EXISTS node_ad; DROP TRIGGER IF EXISTS node_au;")
    }

    /// Rebuilds the search index from the node table (used after a bulk scan).
    static func rebuildFTS(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO node_fts(node_fts) VALUES ('rebuild')")
    }

    /// Deletes everything except pins.
    func clearIndex() throws {
        try writeNow { db in
            try Self.dropFTSTriggers(db)
            try db.execute(sql: "DELETE FROM node; DELETE FROM project; DELETE FROM layout_cache; DELETE FROM node_fts;")
            try db.execute(sql: "DELETE FROM meta WHERE key IN ('scan_state', 'scan_units_done', 'last_event_id', 'expanded_paths', 'scan_roots')")
            try Self.installFTSTriggers(db)
        }
        ids.reset(to: 1)
    }
}

/// Hands out unique row ids to the scanner and the watcher.
final class IDAllocator: Sendable {
    private let next: Mutex<Int64>

    init(start: Int64) { next = Mutex(start) }

    func allocate() -> Int64 {
        next.withLock { value in
            defer { value += 1 }
            return value
        }
    }

    func reset(to value: Int64) { next.withLock { $0 = value } }
}
