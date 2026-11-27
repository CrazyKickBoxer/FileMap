import CoreServices
import Foundation

/// Listens to FSEvents for the whole drive and patches the index as files change.
/// On launch it replays everything that changed while the app was closed.
actor Watcher {
    private let store: IndexStore
    private var patcher: IndexPatcher
    private var stream: FSEventStream?
    private var consumer: Task<Void, Never>?
    private let onChange: @Sendable (PatchResult) -> Void

    init(store: IndexStore, patcher: IndexPatcher, onChange: @escaping @Sendable (PatchResult) -> Void) {
        self.store = store
        self.patcher = patcher
        self.onChange = onChange
    }

    func updatePolicy(_ policy: ScanPolicy) {
        patcher.policy = policy
    }

    func start(paths: [String]) {
        guard stream == nil else { return }
        let lastID = (try? store.readNow { db in try Meta.get(db, "last_event_id") }).flatMap { $0 }.flatMap(UInt64.init)
        let stream = FSEventStream()
        guard stream.start(paths: paths, sinceEventID: lastID) else {
            Log.watcher.error("Could not start FSEvents stream")
            return
        }
        self.stream = stream
        Log.watcher.info("Watching \(paths, privacy: .public) since event \(lastID.map(String.init) ?? "now", privacy: .public)")
        consumer = Task { [weak self] in
            for await batch in stream.events {
                await self?.handle(batch)
            }
        }
    }

    func stop() {
        stream?.stop()
        stream = nil
        consumer?.cancel()
        consumer = nil
    }

    private func handle(_ batch: [FSEvent]) async {
        var plain: [String] = []
        var subtrees: [String] = []
        var lastID: FSEventStreamEventId = 0
        for event in batch {
            lastID = max(lastID, event.id)
            if event.historyDone || event.eventIDsWrapped { continue }
            if event.rootChanged { continue }
            if event.mustScanSubDirs {
                // History was lost or coalesced for this subtree: rescan just that part.
                subtrees.append(event.path)
            } else {
                plain.append(event.path)
            }
        }
        var result = PatchResult()
        do {
            if !subtrees.isEmpty {
                Log.watcher.info("Rescanning \(subtrees.count) subtrees after lost events")
                result.merge(try await patcher.patch(paths: subtrees, recursive: true))
            }
            if !plain.isEmpty {
                result.merge(try await patcher.patch(paths: plain))
            }
            if lastID > 0 {
                let id = String(lastID)
                try store.writeNow { db in try Meta.set(db, "last_event_id", id) }
            }
        } catch {
            Log.watcher.error("Patch failed: \(error.localizedDescription, privacy: .public)")
        }
        if !result.isEmpty { onChange(result) }
    }
}
