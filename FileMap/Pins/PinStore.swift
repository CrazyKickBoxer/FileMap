import Foundation
import GRDB
import Observation

struct PinItem: Identifiable, Sendable, Equatable {
    var id: Int64
    var nodeID: Int64?
    var label: String
    var path: String
    var sort: Int
    var isBroken: Bool
}

/// Pinned files and folders. Each pin keeps a bookmark so it can follow its target after a move.
@MainActor
@Observable
final class PinStore {
    @ObservationIgnored private let store: IndexStore
    private(set) var pins: [PinItem] = []

    init(store: IndexStore) {
        self.store = store
    }

    var pinnedNodeIDs: Set<Int64> { Set(pins.compactMap(\.nodeID)) }

    func isPinned(_ nodeID: Int64) -> Bool { pins.contains { $0.nodeID == nodeID } }

    /// Loads pins and re-resolves any whose target moved.
    func load() async {
        do {
            pins = try await store.write { db in
                let rows = try Row.fetchAll(db, sql: "SELECT id, node_id, label, sort, path, bookmark FROM pin ORDER BY sort, id")
                var result: [PinItem] = []
                for row in rows {
                    let id: Int64 = row[0]
                    var nodeID: Int64? = row[1]
                    let label: String = row[2] ?? ""
                    let sort: Int = row[3] ?? 0
                    var path: String = row[4] ?? ""
                    let bookmark: Data? = row[5]
                    var broken = false
                    let current = try nodeID.flatMap { try NodeQueries.node(db, id: $0) }
                    if current?.path != path || !FileManager.default.fileExists(atPath: path) {
                        // Target moved or vanished: try the bookmark, then the stored path.
                        if let resolved = Self.resolve(bookmark), let node = try NodeQueries.node(db, path: resolved) {
                            nodeID = node.id
                            path = resolved
                        } else if let node = try NodeQueries.node(db, path: path), FileManager.default.fileExists(atPath: path) {
                            nodeID = node.id
                        } else if let current, FileManager.default.fileExists(atPath: current.path) {
                            path = current.path
                        } else {
                            broken = true
                        }
                        try db.execute(sql: "UPDATE pin SET node_id = ?, path = ? WHERE id = ?", arguments: [nodeID, path, id])
                    }
                    result.append(PinItem(id: id, nodeID: broken ? nil : nodeID, label: label, path: path, sort: sort, isBroken: broken))
                }
                return result
            }
        } catch {
            Log.pins.error("Could not load pins: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func resolve(_ bookmark: Data?) -> String? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) else { return nil }
        return url.path
    }

    func toggle(_ node: Node) async {
        if let existing = pins.first(where: { $0.nodeID == node.id }) {
            await remove(existing)
        } else {
            await add(node)
        }
    }

    func add(_ node: Node) async {
        let bookmark = try? node.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let sort = (pins.map(\.sort).max() ?? 0) + 1
        do {
            try await store.write { db in
                try db.execute(sql: "INSERT INTO pin (node_id, label, sort, path, bookmark) VALUES (?, ?, ?, ?, ?)",
                               arguments: [node.id, node.name, sort, node.path, bookmark])
            }
        } catch {
            Log.pins.error("Could not add pin: \(error.localizedDescription, privacy: .public)")
        }
        await load()
    }

    func remove(_ pin: PinItem) async {
        _ = try? await store.write { db in try db.execute(sql: "DELETE FROM pin WHERE id = ?", arguments: [pin.id]) }
        await load()
    }

    func rename(_ pin: PinItem, to label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await store.write { db in try db.execute(sql: "UPDATE pin SET label = ? WHERE id = ?", arguments: [trimmed, pin.id]) }
        await load()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var reordered = pins
        reordered.move(fromOffsets: source, toOffset: destination)
        pins = reordered
        let ids = reordered.map(\.id)
        _ = try? await store.write { db in
            for (n, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE pin SET sort = ? WHERE id = ?", arguments: [n, id])
            }
        }
    }
}
