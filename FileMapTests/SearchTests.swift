import Foundation
import Testing
@testable import FileMap

@Suite("Search")
struct SearchTests {
    @Test("Finds names by substring, short prefixes, and filters")
    func search() async throws {
        let tree = try TempTree()
        try tree.file("reports/Quarterly Report.pdf", bytes: 5_000)
        try tree.file("misc/report-draft.txt", bytes: 10)
        try tree.file("misc/photo.jpg", bytes: 2_000_000)
        try tree.file("ab.txt", bytes: 1)
        let store = try await TestIndex.scan(tree.path)
        let results = try store.readNow { db in
            try SearchQueries.search(db, text: "port", filters: SearchFilters(), visibility: .everything)
        }
        #expect(Set(results.map(\.name)).isSuperset(of: ["reports", "Quarterly Report.pdf", "report-draft.txt"]))
        let short = try store.readNow { db in try SearchQueries.search(db, text: "ab", filters: SearchFilters(), visibility: .everything) }
        #expect(short.contains { $0.name == "ab.txt" })
        let docs = try store.readNow { db in
            try SearchQueries.search(db, text: "report", filters: SearchFilters(kind: .document), visibility: .everything)
        }
        #expect(docs.allSatisfy { $0.kind == .document } && !docs.isEmpty)
        let big = try store.readNow { db in
            try SearchQueries.search(db, text: "pho", filters: SearchFilters(minSize: 1_000_000), visibility: .everything)
        }
        #expect(big.map(\.name) == ["photo.jpg"])
    }

    @Test("Search stays fast on a large index")
    func speed() async throws {
        let store = try TestIndex.makeStore()
        try store.writeNow { db in
            var rows: [NodeRow] = []
            for i in 0..<200_000 {
                rows.append(NodeRow(id: Int64(i + 1), parentID: i == 0 ? nil : 1, name: "file-\(i)-\(i % 97).dat", path: "/t/\(i)", isDir: i == 0,
                                    isPackage: false, isHidden: false, isSystem: false, isLink: false, size: Int64(i), allocSize: Int64(i),
                                    itemCount: 0, uti: nil, kind: .other, createdAt: nil, modifiedAt: nil, openedAt: nil, hasAccess: true))
            }
            try NodeWrites.insert(db, rows: rows)
        }
        let start = CFAbsoluteTimeGetCurrent()
        let results = try store.readNow { db in try SearchQueries.search(db, text: "123-", filters: SearchFilters(), visibility: .everything) }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        #expect(!results.isEmpty)
        #expect(ms < 50, "search took \(ms) ms")
    }
}
