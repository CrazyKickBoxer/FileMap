import Foundation
import GRDB

/// Command-line helpers for testing without the UI.
///
///     FileMap --scan <root> --db <file>          scan a folder into a database and print totals
///     FileMap --verify <path> [--db <file>]      compare index totals with `du -sk`
enum HeadlessCommands {
    /// Returns true if a headless command ran (the app should then exit).
    static func run(_ args: [String]) -> Bool {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let root = value("--scan") {
            let db = value("--db") ?? NSTemporaryDirectory() + "filemap-headless.sqlite"
            blocking { await scan(root: root, dbPath: db) }
            return true
        }
        if let path = value("--verify") {
            let db = value("--db")
            blocking { verify(paths: [path] + extra(args), dbPath: db) }
            return true
        }
        return false
    }

    private static func extra(_ args: [String]) -> [String] {
        guard let i = args.firstIndex(of: "--verify") else { return [] }
        return args.dropFirst(i + 2).prefix { !$0.hasPrefix("--") }.map { $0 }
    }

    private static func blocking(_ work: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await work()
            done.signal()
        }
        done.wait()
    }

    private static func scan(root: String, dbPath: String) async {
        do {
            try? FileManager.default.removeItem(atPath: dbPath)
            let store = try IndexStore(url: URL(fileURLWithPath: dbPath))
            let scanner = Scanner(store: store)
            let start = Date()
            let finished = AsyncStream<ScanProgress.Phase>.makeStream()
            await scanner.start(roots: [root], policy: ScanPolicy(), resume: false, onProgress: { p in
                FileHandle.standardError.write(Data("\r\(p.items) items…".utf8))
            }, onFinish: { phase in
                finished.continuation.yield(phase)
                finished.continuation.finish()
            })
            var phase: ScanProgress.Phase = .done
            for await p in finished.stream { phase = p }
            let elapsed = Date().timeIntervalSince(start)
            let stats = try store.readNow { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node") ?? 0, try NodeQueries.root(db))
            }
            print("\nScan \(phase) in \(String(format: "%.2f", elapsed)) s: \(stats.0) rows → \(dbPath)")
            if let r = stats.1 {
                print("\(r.path): \(Format.bytes(r.size)) logical, \(Format.bytes(r.allocSize)) on disk, \(r.itemCount) items")
            }
        } catch {
            print("Scan failed: \(error)")
        }
    }

    private static func verify(paths: [String], dbPath: String?) {
        do {
            let url = try dbPath.map { URL(fileURLWithPath: $0) } ?? IndexStore.defaultURL()
            let store = try IndexStore(url: url)
            print(String(repeating: " ", count: 0) + "path\tindex (KB on disk)\tdu -sk\tdiff")
            for path in paths {
                let node = try store.readNow { db in try NodeQueries.node(db, path: path) }
                let indexKB = (node?.allocSize ?? 0) / 1024
                let du = Process()
                du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                du.arguments = ["-sk", path]
                let pipe = Pipe()
                du.standardOutput = pipe
                du.standardError = FileHandle.nullDevice
                try du.run()
                du.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let duKB = Int64(out.split(separator: "\t").first ?? "") ?? -1
                let diff = duKB > 0 ? String(format: "%+.2f%%", Double(indexKB - duKB) / Double(duKB) * 100) : "n/a"
                print("\(path)\t\(indexKB)\t\(duKB)\t\(diff)\t(\(node?.itemCount ?? 0) items)")
            }
        } catch {
            print("Verify failed: \(error)")
        }
    }
}
