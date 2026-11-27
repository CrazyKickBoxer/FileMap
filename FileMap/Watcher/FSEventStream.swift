import CoreServices
import Foundation

/// One file-system event.
struct FSEvent: Sendable {
    var path: String
    var flags: FSEventStreamEventFlags
    var id: FSEventStreamEventId

    var mustScanSubDirs: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
    var historyDone: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 }
    var rootChanged: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }
    var eventIDsWrapped: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 }
}

/// Thin wrapper over the FSEvents C API that delivers batches through an `AsyncStream`.
final class FSEventStream: @unchecked Sendable {
    let events: AsyncStream<[FSEvent]>
    private let continuation: AsyncStream<[FSEvent]>.Continuation
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.filemap.fsevents", qos: .utility)

    init() {
        (events, continuation) = AsyncStream.makeStream(of: [FSEvent].self, bufferingPolicy: .unbounded)
    }

    /// Starts watching `paths` with file-level events, replaying history since `sinceEventID`.
    func start(paths: [String], sinceEventID: FSEventStreamEventId?, latency: TimeInterval = 0.5) -> Bool {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
            guard let info else { return }
            let me = Unmanaged<FSEventStream>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self)
            var batch: [FSEvent] = []
            batch.reserveCapacity(count)
            for i in 0..<count {
                guard let path = paths[i] as? String else { continue }
                batch.append(FSEvent(path: path, flags: rawFlags[i], id: rawIDs[i]))
            }
            me.continuation.yield(batch)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            sinceEventID ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return false }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        return FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        continuation.finish()
    }

    deinit { stop() }
}
