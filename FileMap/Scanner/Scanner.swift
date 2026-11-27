import CoreServices
import Darwin
import Foundation
import GRDB

/// Runs the first full scan of the disk (and later full rescans).
///
/// The tree is split into "upper" folders (the first few levels, scanned by the coordinator) and
/// "units" (subtrees below them) which are walked in parallel by a capped number of workers.
/// Each finished unit adds its totals to its ancestors, so folder sizes grow live while scanning.
actor Scanner {
    static let splitDepth = 3
    static let maxWorkers = 6

    private let store: IndexStore
    private let gate = PauseGate()
    private let counters = ScanCounters()
    private var task: Task<Void, Never>?
    private var progress = ScanProgress()

    init(store: IndexStore) {
        self.store = store
    }

    var isRunning: Bool { task != nil }

    func pause() {
        gate.pause()
        progress.phase = .paused
    }

    func resume() {
        gate.resume()
        progress.phase = .scanning
    }

    func cancel() {
        task?.cancel()
        gate.resume()
    }

    /// Starts a scan. `resume` continues an interrupted scan instead of starting over.
    func start(
        roots: [String],
        policy: ScanPolicy,
        resume: Bool,
        onProgress: @escaping @Sendable (ScanProgress) -> Void,
        onFinish: @escaping @Sendable (ScanProgress.Phase) -> Void
    ) {
        guard task == nil else { return }
        counters.items.store(0, ordering: .relaxed)
        counters.bytes.store(0, ordering: .relaxed)
        progress = ScanProgress(phase: .preparing, estimatedTotalBytes: Self.estimateUsedBytes(roots: roots))
        let store = self.store
        let gate = self.gate
        let counters = self.counters
        let scanner = self
        task = Task.detached(priority: .utility) {
            let reporter = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    onProgress(await scanner.snapshot())
                }
            }
            let phase: ScanProgress.Phase
            do {
                try await Self.run(store: store, roots: roots, policy: policy, resume: resume, gate: gate, counters: counters) {
                    await scanner.setPhase($0)
                }
                phase = .done
            } catch is CancellationError {
                phase = .cancelled
            } catch {
                Log.scanner.error("Scan failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(error.localizedDescription)
            }
            reporter.cancel()
            await scanner.finish(phase: phase)
            onProgress(await scanner.snapshot())
            onFinish(phase)
        }
    }

    private func setPhase(_ phase: ScanProgress.Phase) {
        progress.phase = phase
    }

    private func finish(phase: ScanProgress.Phase) {
        progress.phase = phase
        task = nil
    }

    private func snapshot() -> ScanProgress {
        var p = progress
        p.items = counters.items.load(ordering: .relaxed)
        p.bytes = counters.bytes.load(ordering: .relaxed)
        p.currentPath = counters.currentPath
        if p.phase == .scanning, gate.isPaused { p.phase = .paused }
        return p
    }

    // MARK: The scan itself

    private struct Unit: Sendable {
        var id: Int64
        var parentID: Int64
        var path: String
        var isPackage: Bool
    }

    private static func run(
        store: IndexStore,
        roots: [String],
        policy: ScanPolicy,
        resume: Bool,
        gate: PauseGate,
        counters: ScanCounters,
        setPhase: @escaping @Sendable (ScanProgress.Phase) async -> Void
    ) async throws {
        // Never download iCloud placeholders just because we listed them.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let startEventID = FSEventsGetCurrentEventId()
        let started = Date()

        if !resume { try store.clearIndex() }
        try store.writeNow { db in
            try IndexStore.dropFTSTriggers(db)
            try Meta.set(db, "scan_state", "running")
            try Meta.setJSON(db, "scan_roots", roots)
            if try Meta.get(db, "scan_start_event") == nil {
                try Meta.set(db, "scan_start_event", String(startEventID))
            }
        }
        await setPhase(.scanning)

        let walker = SubtreeWalker(store: store, policy: policy, counters: counters, gate: gate, hardLinks: HardLinkSet())
        var units: [Unit] = []
        var upper: [(id: Int64, depth: Int)] = []

        for root in roots {
            guard let rootID = try ensureRoot(store: store, path: root) else { continue }
            var queue: [(Int64, String, Int)] = [(rootID, root, 0)]
            upper.append((rootID, 0))
            while !queue.isEmpty {
                let (dirID, dirPath, depth) = queue.removeFirst()
                try Task.checkCancellation()
                await gate.waitIfPaused()
                counters.currentPath = dirPath
                let found = try scanUpper(store: store, walker: walker, policy: policy, dirID: dirID, path: dirPath, counters: counters)
                for (childID, childPath, isPackage) in found {
                    if !isPackage && depth + 1 < splitDepth {
                        queue.append((childID, childPath, depth + 1))
                        upper.append((childID, depth + 1))
                    } else {
                        units.append(Unit(id: childID, parentID: dirID, path: childPath, isPackage: isPackage))
                    }
                }
            }
        }

        let done = try store.readNow { db in
            Set(try String.fetchAll(db, sql: "SELECT key FROM meta WHERE key LIKE 'unit:%'"))
        }
        let pending = units.filter { !done.contains("unit:\($0.id)") }
        Log.scanner.info("Scanning \(pending.count) units (\(units.count - pending.count) already done)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            func addNext() -> Bool {
                guard let unit = iterator.next() else { return false }
                group.addTask {
                    try await scanUnit(unit, store: store, walker: walker, resume: resume)
                }
                return true
            }
            for _ in 0..<maxWorkers where !addNext() { break }
            while try await group.next() != nil {
                _ = addNext()
            }
        }

        await setPhase(.finishing)
        try store.writeNow { db in
            // Recompute upper folders exactly (deepest first) as a final consistency pass.
            for entry in upper.sorted(by: { $0.depth > $1.depth }) {
                try db.execute(sql: """
                    UPDATE node SET
                      size = (SELECT COALESCE(SUM(size), 0) FROM node c WHERE c.parent_id = node.id),
                      alloc_size = (SELECT COALESCE(SUM(alloc_size), 0) FROM node c WHERE c.parent_id = node.id),
                      item_count = (SELECT COALESCE(SUM(item_count + 1), 0) FROM node c WHERE c.parent_id = node.id)
                    WHERE id = ?
                    """, arguments: [entry.id])
            }
            try IndexStore.rebuildFTS(db)
            try IndexStore.installFTSTriggers(db)
            let startEvent = try Meta.get(db, "scan_start_event") ?? String(startEventID)
            try Meta.set(db, "last_event_id", startEvent)
            try Meta.set(db, "scan_state", "complete")
            try Meta.set(db, "scan_start_event", nil)
            try Meta.set(db, "last_scan_seconds", String(Date().timeIntervalSince(started)))
            try db.execute(sql: "DELETE FROM meta WHERE key LIKE 'unit:%'")
        }
        try ProjectDetector.detect(store: store)
        try store.writeNow { db in try db.execute(sql: "PRAGMA optimize") }
        Log.scanner.info("Scan finished: \(counters.items.load(ordering: .relaxed)) items in \(Date().timeIntervalSince(started))s")
    }

    /// Returns the id of the root row, creating it if needed.
    private static func ensureRoot(store: IndexStore, path: String) throws -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return try store.writeNow { db in
            if let existing = try NodeQueries.node(db, path: path) { return existing.id }
            let name = path == "/" ? (volumeName(path) ?? "Macintosh HD") : path.lastPathComponentFast
            let row = NodeRow(
                id: store.ids.allocate(), parentID: nil, name: name, path: path, isDir: true, isPackage: false,
                isHidden: false, isSystem: false, isLink: false, size: 0, allocSize: 0, itemCount: 0,
                uti: "public.volume", kind: .folder, createdAt: Double(st.st_birthtimespec.tv_sec),
                modifiedAt: Double(st.st_mtimespec.tv_sec), openedAt: nil, hasAccess: true)
            try NodeWrites.insert(db, rows: [row])
            return row.id
        }
    }

    static func volumeName(_ path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
    }

    /// Scans one upper-level folder: writes its entries (reusing existing rows when resuming) and
    /// returns the sub-folders and packages found.
    private static func scanUpper(
        store: IndexStore, walker: SubtreeWalker, policy: ScanPolicy, dirID: Int64, path: String, counters: ScanCounters
    ) throws -> [(Int64, String, Bool)] {
        let entries: [BulkEntry]
        do {
            entries = try BulkDirectoryReader.read(directory: path)
        } catch .noAccess {
            try store.writeNow { db in try db.execute(sql: "UPDATE node SET access = 0 WHERE id = ?", arguments: [dirID]) }
            return []
        } catch {
            return []
        }
        var rows: [NodeRow] = []
        for entry in entries {
            let childPath = path.appendingPathComponentFast(entry.name)
            if policy.shouldSkip(childPath) { continue }
            guard let row = walker.makeRow(entry, path: childPath, parentID: dirID) else { continue }
            if entry.isMountPoint && !policy.shouldDescend(intoMountPoint: childPath) { continue }
            rows.append(row)
        }
        counters.add(items: rows.count, bytes: rows.reduce(0) { $0 + ($1.isDir ? 0 : $1.allocSize) })
        return try store.writeNow { db in
            var found: [(Int64, String, Bool)] = []
            var added = Totals()
            for row in rows {
                if let existing = try NodeQueries.node(db, path: row.path) {
                    if existing.isDir { found.append((existing.id, existing.path, existing.isPackage)) }
                    continue
                }
                try NodeWrites.insert(db, rows: [row])
                if row.isDir {
                    added.count += 1
                    found.append((row.id, row.path, row.isPackage))
                } else {
                    added = added + Totals(size: row.size, alloc: row.allocSize, count: 1)
                }
            }
            try NodeWrites.applyDelta(db, from: dirID, delta: added)
            return found
        }
    }

    /// Walks one unit and atomically records its totals and completion.
    private static func scanUnit(_ unit: Unit, store: IndexStore, walker: SubtreeWalker, resume: Bool) async throws {
        try Task.checkCancellation()
        if resume {
            try store.writeNow { db in try NodeWrites.deleteSubtree(db, path: unit.path, includeRoot: false) }
        }
        let totals: Totals
        var access = true
        if unit.isPackage {
            let measured = SubtreeWalker.measure(path: unit.path)
            totals = Totals(size: measured.size, alloc: measured.alloc, count: 0)
            walker.counters?.add(items: 1, bytes: measured.alloc)
        } else {
            let sink = BatchSink(store: store)
            let result = try await walker.walk(rootPath: unit.path, rootID: unit.id, sink: sink)
            try sink.flush()
            totals = result.totals
            access = result.access
        }
        try store.writeNow { db in
            // Packages measured by the upper pass already carry their size; replace, don't add twice.
            let previous = try NodeQueries.node(db, id: unit.id)
            let old = Totals(size: previous?.size ?? 0, alloc: previous?.allocSize ?? 0, count: previous?.itemCount ?? 0)
            try NodeWrites.setTotals(db, id: unit.id, totals: totals, access: access)
            try NodeWrites.applyDelta(db, from: unit.parentID, delta: totals - old)
            try Meta.set(db, "unit:\(unit.id)", "1")
        }
    }

    /// Rough number of bytes in use on the scanned volumes, for the progress percentage.
    static func estimateUsedBytes(roots: [String]) -> Int64 {
        var total: Int64 = 0
        var volumes = Set(roots)
        if roots.contains("/") {
            // External drives under /Volumes are scanned too.
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            for url in mounted where url.path.parentPath == "/Volumes" { volumes.insert(url.path) }
        }
        for root in volumes {
            let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
            if let v = try? URL(fileURLWithPath: root).resourceValues(forKeys: keys),
               let cap = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacity {
                total += Int64(cap - avail)
            }
        }
        return total
    }
}
