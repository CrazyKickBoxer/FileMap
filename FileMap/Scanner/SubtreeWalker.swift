import Foundation
import GRDB

/// Collects inserts and total updates, flushing them to the database in batches.
final class BatchSink {
    private let store: IndexStore
    private let batchSize: Int
    private var rows: [NodeRow] = []
    private var updates: [(Int64, Totals, Bool)] = []
    private let projectID: Int64?

    init(store: IndexStore, batchSize: Int = 4000, projectID: Int64? = nil) {
        self.store = store
        self.batchSize = batchSize
        self.projectID = projectID
    }

    func insert(_ row: NodeRow) throws {
        rows.append(row)
        if rows.count + updates.count >= batchSize { try flush() }
    }

    func setTotals(id: Int64, totals: Totals, access: Bool) throws {
        updates.append((id, totals, access))
        if rows.count + updates.count >= batchSize { try flush() }
    }

    func flush() throws {
        guard !rows.isEmpty || !updates.isEmpty else { return }
        let rows = self.rows
        let updates = self.updates
        let projectID = self.projectID
        self.rows.removeAll(keepingCapacity: true)
        self.updates.removeAll(keepingCapacity: true)
        try store.writeNow { db in
            try NodeWrites.insert(db, rows: rows, projectID: projectID)
            for (id, totals, access) in updates {
                try NodeWrites.setTotals(db, id: id, totals: totals, access: access)
            }
        }
    }
}

/// Walks a directory tree depth-first without recursion, writing a row per item and
/// rolling sizes and counts up to every folder it passes.
struct SubtreeWalker: Sendable {
    let store: IndexStore
    let policy: ScanPolicy
    var counters: ScanCounters?
    var gate: PauseGate?
    var hardLinks: HardLinkSet?
    private let classifier = TypeClassifier.shared

    init(store: IndexStore, policy: ScanPolicy, counters: ScanCounters? = nil, gate: PauseGate? = nil, hardLinks: HardLinkSet? = nil) {
        self.store = store
        self.policy = policy
        self.counters = counters
        self.gate = gate
        self.hardLinks = hardLinks
    }

    private struct Frame {
        var id: Int64
        var path: String
        var totals = Totals()
        var access = true
        var dirs: [(Int64, String)] = []
        var next = 0
    }

    /// Walks below an existing directory row. Every directory below `rootPath` gets its totals
    /// written; the root's totals are returned (not written) so the caller can apply them atomically.
    func walk(rootPath: String, rootID: Int64, sink: BatchSink) async throws -> (totals: Totals, access: Bool) {
        var stack: [Frame] = [try list(id: rootID, path: rootPath, sink: sink)]
        while var top = stack.popLast() {
            if top.next < top.dirs.count {
                let (childID, childPath) = top.dirs[top.next]
                top.next += 1
                stack.append(top)
                if let gate { await gate.waitIfPaused() }
                try Task.checkCancellation()
                stack.append(try list(id: childID, path: childPath, sink: sink))
                continue
            }
            if stack.isEmpty {
                return (top.totals, top.access)
            }
            try sink.setTotals(id: top.id, totals: top.totals, access: top.access)
            stack[stack.count - 1].totals = stack[stack.count - 1].totals + top.totals
        }
        return (Totals(), true)
    }

    /// Lists one directory: writes rows for its entries, measures packages, and returns a frame
    /// whose totals include the files (sub-directories are added as they finish).
    private func list(id: Int64, path: String, sink: BatchSink) throws -> Frame {
        var frame = Frame(id: id, path: path)
        counters?.currentPath = path
        let entries: [BulkEntry]
        do {
            entries = try BulkDirectoryReader.read(directory: path)
        } catch .noAccess {
            frame.access = false
            return frame
        } catch {
            return frame
        }
        var bytes: Int64 = 0
        for entry in entries {
            let childPath = path.appendingPathComponentFast(entry.name)
            if policy.shouldSkip(childPath) { continue }
            guard var row = makeRow(entry, path: childPath, parentID: id) else { continue }
            if row.isPackage {
                let measured = Self.measure(path: childPath)
                row.size = measured.size
                row.allocSize = measured.alloc
            }
            try sink.insert(row)
            if row.isDir && !row.isPackage {
                frame.totals.count += 1
                let descend = !entry.isMountPoint || policy.shouldDescend(intoMountPoint: childPath)
                if descend { frame.dirs.append((row.id, childPath)) }
            } else {
                frame.totals = frame.totals + Totals(size: row.size, alloc: row.allocSize, count: 1)
                bytes += row.allocSize
            }
        }
        counters?.add(items: entries.count, bytes: bytes)
        return frame
    }

    /// Builds a row for an entry (nil for objects we do not record, like sockets).
    func makeRow(_ entry: BulkEntry, path: String, parentID: Int64?) -> NodeRow? {
        let isDir = entry.type == .directory
        if entry.type == .other { return nil }
        let info = entry.type == .symlink
            ? TypeClassifier.Info(uti: "public.symlink", kind: .other, isPackage: false)
            : classifier.info(forName: entry.name, isDirectory: isDir)
        let isPackage = isDir && info.isPackage && policy.treatPackagesAsItems
        var alloc = entry.allocatedSize
        if entry.linkCount > 1, let hardLinks, !hardLinks.firstSighting(device: entry.device, fileID: entry.fileID) {
            alloc = 0  // another link to this file was already counted
        }
        return NodeRow(
            id: store.ids.allocate(),
            parentID: parentID,
            name: entry.name,
            path: path,
            isDir: isDir,
            isPackage: isPackage,
            isHidden: ScanPolicy.isHidden(name: entry.name, flags: entry.flags, path: path),
            isSystem: ScanPolicy.isSystem(path),
            isLink: entry.type == .symlink,
            size: entry.logicalSize,
            allocSize: alloc,
            itemCount: 0,
            uti: info.uti,
            kind: isDir && !isPackage ? .folder : info.kind,
            createdAt: entry.created,
            modifiedAt: entry.modified,
            openedAt: entry.accessed,
            hasAccess: true
        )
    }

    /// Total size of everything inside a package (no rows are written).
    static func measure(path: String) -> Totals {
        var totals = Totals()
        var stack = [path]
        while let dir = stack.popLast() {
            guard let entries = try? BulkDirectoryReader.read(directory: dir) else { continue }
            for e in entries {
                switch e.type {
                case .directory:
                    if !e.isMountPoint { stack.append(dir.appendingPathComponentFast(e.name)) }
                case .file, .symlink:
                    totals.size += e.logicalSize
                    totals.alloc += e.allocatedSize
                case .other:
                    break
                }
            }
        }
        return totals
    }
}
