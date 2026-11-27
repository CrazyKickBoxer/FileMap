import Foundation
@testable import FileMap

/// A throwaway folder under ~/.filemap-tests (not a system or Library path, so nothing is protected or ignored).
final class TempTree {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".filemap-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var path: String { root.path }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    deinit { try? FileManager.default.removeItem(at: root) }
}

enum TestIndex {
    static func makeStore() throws -> IndexStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("filemap-test-\(UUID().uuidString).sqlite")
        return try IndexStore(url: url)
    }

    /// Runs a full scan of `root` into a fresh store.
    static func scan(_ root: String, policy: ScanPolicy = ScanPolicy()) async throws -> IndexStore {
        let store = try makeStore()
        let scanner = Scanner(store: store)
        let (stream, continuation) = AsyncStream<ScanProgress.Phase>.makeStream()
        await scanner.start(roots: [root], policy: policy, resume: false, onProgress: { _ in }, onFinish: { phase in
            continuation.yield(phase)
            continuation.finish()
        })
        for await phase in stream {
            guard phase == .done else { throw TestError.scanFailed("\(phase)") }
        }
        return store
    }

    static func node(_ store: IndexStore, _ path: String) throws -> Node? {
        try store.readNow { db in try NodeQueries.node(db, path: path) }
    }

    /// Every folder's stored totals must equal the sum over its children.
    static func assertConsistent(_ store: IndexStore) throws -> [String] {
        try store.readNow { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.path, p.size, p.alloc_size, p.item_count,
                  COALESCE(SUM(c.size), 0), COALESCE(SUM(c.alloc_size), 0), COALESCE(SUM(c.item_count + 1), 0)
                FROM node p LEFT JOIN node c ON c.parent_id = p.id
                WHERE p.is_dir = 1 AND p.is_package = 0 GROUP BY p.id
                """)
            return rows.compactMap { r in
                let ok = (r[1] as Int64) == (r[4] as Int64) && (r[2] as Int64) == (r[5] as Int64) && (r[3] as Int64) == (r[6] as Int64)
                return ok ? nil : "\(r[0] as String): stored (\(r[1] as Int64), \(r[3] as Int64)) vs children (\(r[4] as Int64), \(r[6] as Int64))"
            }
        }
    }
}

import GRDB

enum TestError: Error { case scanFailed(String) }
