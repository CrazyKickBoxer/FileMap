import Foundation
import Synchronization

/// Snapshot of scan progress for the UI.
struct ScanProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case preparing, scanning, paused, finishing, done, cancelled
        case failed(String)
    }

    var phase: Phase = .preparing
    var items = 0
    var bytes: Int64 = 0
    var estimatedTotalBytes: Int64 = 0
    var currentPath = ""
    var startedAt = Date()

    var fraction: Double {
        if phase == .done { return 1 }
        guard estimatedTotalBytes > 0 else { return 0 }
        return min(0.99, Double(bytes) / Double(estimatedTotalBytes))
    }

    var isActive: Bool {
        switch phase {
        case .preparing, .scanning, .paused, .finishing: true
        default: false
        }
    }
}

/// Lock-free counters shared by scan workers.
final class ScanCounters: Sendable {
    let items = Atomic<Int>(0)
    let bytes = Atomic<Int64>(0)
    private let current = Mutex<String>("")

    func add(items n: Int, bytes b: Int64) {
        items.add(n, ordering: .relaxed)
        bytes.add(b, ordering: .relaxed)
    }

    var currentPath: String {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

/// Lets workers park between directories while the scan is paused.
final class PauseGate: Sendable {
    private struct State {
        var paused = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var isPaused: Bool { state.withLock { $0.paused } }

    func pause() { state.withLock { $0.paused = true } }

    func resume() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.paused = false
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func waitIfPaused() async {
        guard isPaused else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.paused {
                    s.waiters.append(c)
                    return false
                }
                return true
            }
            if resumeNow { c.resume() }
        }
    }
}

/// Remembers hard-linked files already counted, so their disk space is only added once (like `du`).
final class HardLinkSet: Sendable {
    private let seen = Mutex<Set<UInt64>>([])

    /// Returns true the first time a (device, file id) pair is seen.
    func firstSighting(device: Int32, fileID: UInt64) -> Bool {
        let key = UInt64(UInt32(bitPattern: device)) &<< 40 ^ fileID
        return seen.withLock { $0.insert(key).inserted }
    }
}
