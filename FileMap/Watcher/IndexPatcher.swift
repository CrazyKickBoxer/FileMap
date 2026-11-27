import Darwin
import Foundation
import GRDB

/// What changed in the index after a patch, so the map can refresh just those parts.
struct PatchResult: Sendable {
    /// Folders whose list of children changed.
    var changedParents: Set<Int64> = []
    /// Nodes whose own values (size, dates) changed, including every ancestor whose totals moved.
    var changedNodes: Set<Int64> = []
    /// Nodes that no longer exist.
    var removedNodes: Set<Int64> = []

    mutating func merge(_ other: PatchResult) {
        changedParents.formUnion(other.changedParents)
        changedNodes.formUnion(other.changedNodes)
        removedNodes.formUnion(other.removedNodes)
    }

    var isEmpty: Bool { changedParents.isEmpty && changedNodes.isEmpty && removedNodes.isEmpty }
}

/// Brings index rows in line with the disk for specific paths. Idempotent: patching a path that
/// already matches the disk changes nothing. Used by the watcher and right after file operations.
struct IndexPatcher: Sendable {
    let store: IndexStore
    var policy: ScanPolicy
    /// Paths whose events are ignored (our own database folder).
    var ignoredPrefixes: [String] = []

    /// Patches each path. `recursive` re-walks directories (used when FSEvents asks for a subtree rescan).
    func patch(paths: [String], recursive: Bool = false) async throws -> PatchResult {
        var result = PatchResult()
        let unique = Array(Set(paths.map(Self.normalize))).sorted()
        for path in unique {
            if ignoredPrefixes.contains(where: { path.isInside($0) }) { continue }
            if policy.shouldSkip(path) { continue }
            result.merge(try await patchOne(path, recursive: recursive))
        }
        return result
    }

    /// FSEvents may report data-volume paths through the firmlink mount; map them back.
    static func normalize(_ path: String) -> String {
        let dataPrefix = "/System/Volumes/Data"
        var p = path
        if p.hasPrefix(dataPrefix + "/") { p = String(p.dropFirst(dataPrefix.count)) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private func patchOne(_ path: String, recursive: Bool) async throws -> PatchResult {
        var result = PatchResult()
        let existing = try store.readNow { db in try NodeQueries.node(db, path: path) }
        var st = stat()
        let exists = lstat(path, &st) == 0

        guard exists else {
            guard let existing else { return result }
            try store.writeNow { db in
                try NodeWrites.deleteSubtree(db, path: existing.path, includeRoot: true)
                try NodeWrites.applyDelta(db, from: existing.parentID, delta: -Totals.contribution(of: existing))
            }
            result.removedNodes.insert(existing.id)
            if let parentID = existing.parentID {
                result.changedParents.insert(parentID)
                result.changedNodes.formUnion(try store.readNow { db in try NodeWrites.lineageIDs(db, from: parentID) })
            }
            return result
        }

        // Make sure the parent is indexed; if not, patch the parent instead (it will include us).
        let parentPath = path.parentPath
        guard path != "/", let parent = try store.readNow({ db in try NodeQueries.node(db, path: parentPath) }) else {
            if path != "/", parentPath != path { return try await patchOne(parentPath, recursive: true) }
            return result
        }
        if !parent.isFolder { return try await remeasurePackageIfNeeded(parent) }  // inside a package

        let entry = Self.entry(from: st, name: path.lastPathComponentFast)
        let walker = SubtreeWalker(store: store, policy: policy)
        guard var row = walker.makeRow(entry, path: path, parentID: parent.id) else { return result }

        // Type changed (file ↔ folder): drop the old row first.
        var old = existing
        if let e = existing, e.isDir != row.isDir || e.isPackage != row.isPackage {
            try store.writeNow { db in
                try NodeWrites.deleteSubtree(db, path: e.path, includeRoot: true)
                try NodeWrites.applyDelta(db, from: e.parentID, delta: -Totals.contribution(of: e))
            }
            result.removedNodes.insert(e.id)
            old = nil
        }

        if row.isDir && !row.isPackage {
            if let old {
                // Folder metadata changed. Only re-walk when asked to.
                try store.writeNow { db in
                    try db.execute(sql: "UPDATE node SET modified_at = ?, created_at = ?, opened_at = ?, is_hidden = ? WHERE id = ?",
                                   arguments: [row.modifiedAt, row.createdAt, row.openedAt, row.isHidden, old.id])
                }
                result.changedNodes.insert(old.id)
                if recursive {
                    try store.writeNow { db in try NodeWrites.deleteSubtree(db, path: old.path, includeRoot: false) }
                    let sink = BatchSink(store: store, projectID: old.projectID)
                    let walked = try await walker.walk(rootPath: path, rootID: old.id, sink: sink)
                    try sink.flush()
                    let oldTotals = Totals(size: old.size, alloc: old.allocSize, count: old.itemCount)
                    try store.writeNow { db in
                        try NodeWrites.setTotals(db, id: old.id, totals: walked.totals, access: walked.access)
                        try NodeWrites.applyDelta(db, from: old.parentID, delta: walked.totals - oldTotals)
                    }
                    result.changedParents.insert(old.id)
                    result.changedNodes.formUnion(try store.readNow { db in try NodeWrites.lineageIDs(db, from: old.id) })
                }
                return result
            }
            // New folder: insert it, then walk everything inside.
            row.itemCount = 0
            let insertRow = row
            try store.writeNow { db in
                try NodeWrites.insert(db, rows: [insertRow], projectID: parent.projectID)
            }
            let sink = BatchSink(store: store, projectID: parent.projectID)
            let walked = try await walker.walk(rootPath: path, rootID: row.id, sink: sink)
            try sink.flush()
            try store.writeNow { db in
                try NodeWrites.setTotals(db, id: insertRow.id, totals: walked.totals, access: walked.access)
                try NodeWrites.applyDelta(db, from: parent.id, delta: walked.totals + Totals(count: 1))
            }
            result.changedParents.insert(parent.id)
            result.changedNodes.formUnion(try store.readNow { db in try NodeWrites.lineageIDs(db, from: parent.id) })
            return result
        }

        // File, symlink, or package.
        if row.isPackage {
            let measured = SubtreeWalker.measure(path: path)
            row.size = measured.size
            row.allocSize = measured.alloc
        }
        let newRow = row
        if let old {
            let delta = Totals(size: newRow.size - old.size, alloc: newRow.allocSize - old.allocSize, count: 0)
            let unchanged = delta.isZero && old.modifiedAt == newRow.modifiedAt && old.isHidden == newRow.isHidden
            if unchanged { return result }
            try store.writeNow { db in
                try db.execute(sql: """
                    UPDATE node SET size = ?, alloc_size = ?, modified_at = ?, created_at = ?, opened_at = ?, is_hidden = ?
                    WHERE id = ?
                    """, arguments: [newRow.size, newRow.allocSize, newRow.modifiedAt, newRow.createdAt, newRow.openedAt, newRow.isHidden, old.id])
                try NodeWrites.applyDelta(db, from: parent.id, delta: delta)
            }
            result.changedNodes.insert(old.id)
        } else {
            try store.writeNow { db in
                try NodeWrites.insert(db, rows: [newRow], projectID: parent.projectID)
                try NodeWrites.applyDelta(db, from: parent.id, delta: Totals(size: newRow.size, alloc: newRow.allocSize, count: 1))
            }
            result.changedParents.insert(parent.id)
        }
        result.changedNodes.formUnion(try store.readNow { db in try NodeWrites.lineageIDs(db, from: parent.id) })
        return result
    }

    /// When something changes inside a package, re-measure the package as a whole.
    private func remeasurePackageIfNeeded(_ node: Node) async throws -> PatchResult {
        var result = PatchResult()
        guard node.isPackage else { return result }
        let measured = SubtreeWalker.measure(path: node.path)
        let delta = Totals(size: measured.size - node.size, alloc: measured.alloc - node.allocSize, count: 0)
        guard !delta.isZero else { return result }
        try store.writeNow { db in
            try db.execute(sql: "UPDATE node SET size = ?, alloc_size = ? WHERE id = ?", arguments: [measured.size, measured.alloc, node.id])
            try NodeWrites.applyDelta(db, from: node.parentID, delta: delta)
        }
        result.changedNodes.formUnion(try store.readNow { db in try NodeWrites.lineageIDs(db, from: node.id) })
        return result
    }

    /// Moves index rows for a same-volume move or rename, keeping ids (pins follow), then
    /// refreshes metadata at the destination.
    func applyMove(from source: String, to destination: String) async throws -> PatchResult {
        var result = PatchResult()
        let src = Self.normalize(source), dst = Self.normalize(destination)
        let moved: Bool = try store.writeNow { db in
            guard let node = try NodeQueries.node(db, path: src),
                  let newParent = try NodeQueries.node(db, path: dst.parentPath),
                  try NodeQueries.node(db, path: dst) == nil else { return false }
            let contribution = Totals.contribution(of: node)
            try NodeWrites.applyDelta(db, from: node.parentID, delta: -contribution)
            try NodeWrites.moveSubtree(db, node: node, toPath: dst, newParentID: newParent.id)
            try NodeWrites.applyDelta(db, from: newParent.id, delta: contribution)
            // Hidden/system flags follow the new location.
            let p = NodeQueries.subtreePredicate(dst)
            var args: StatementArguments = [ScanPolicy.isSystem(dst)]
            args += p.arguments
            try db.execute(sql: "UPDATE node SET is_system = ? WHERE \(p.sql)", arguments: args)
            try db.execute(sql: "UPDATE node SET is_hidden = ? WHERE id = ?",
                           arguments: [dst.lastPathComponentFast.hasPrefix("."), node.id])
            if let old = node.parentID { result.changedParents.insert(old) }
            result.changedParents.insert(newParent.id)
            result.changedNodes.insert(node.id)
            if let old = node.parentID { result.changedNodes.formUnion(try NodeWrites.lineageIDs(db, from: old)) }
            result.changedNodes.formUnion(try NodeWrites.lineageIDs(db, from: newParent.id))
            return true
        }
        if moved {
            result.merge(try await patch(paths: [dst]))
        } else {
            result.merge(try await patch(paths: [src, dst]))
        }
        return result
    }

    static func entry(from st: stat, name: String) -> BulkEntry {
        let mode = st.st_mode & S_IFMT
        let type: BulkEntry.ObjectType = mode == S_IFDIR ? .directory : mode == S_IFREG ? .file : mode == S_IFLNK ? .symlink : .other
        func t(_ ts: timespec) -> Double { Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 }
        return BulkEntry(
            name: name, type: type, device: st.st_dev, created: t(st.st_birthtimespec), modified: t(st.st_mtimespec),
            accessed: t(st.st_atimespec), flags: st.st_flags, fileID: st.st_ino, isMountPoint: false,
            logicalSize: type == .directory ? 0 : Int64(st.st_size), allocatedSize: type == .directory ? 0 : Int64(st.st_blocks) * 512)
    }
}
