import CoreGraphics
import Foundation

/// A synthetic tree for stress-testing the renderer (Debug ▸ Build 1M-Node Test Tree).
enum DebugTree {
    static func makeScene(fanout: Int, depth: Int) -> MapScene {
        var input = LayoutInput()
        input.entries.reserveCapacity(Int(pow(Double(fanout), Double(depth))) * 2)
        let kinds = FileKind.fileKinds
        var frontier: [Int32] = [input.add(entry(0, kind: .folder, folder: true, depth: 0), parent: nil)]
        for level in 1...depth {
            var next: [Int32] = []
            next.reserveCapacity(frontier.count * fanout)
            for parent in frontier {
                for k in 0..<fanout {
                    let id = Int32(input.entries.count)
                    let isFolder = level < depth
                    let kind = isFolder ? FileKind.folder : kinds[(Int(id) + k) % kinds.count]
                    next.append(input.add(entry(id, kind: kind, folder: isFolder, depth: level), parent: parent))
                }
            }
            frontier = next
        }
        return TidyTreeLayout.layout(input)
    }

    private static func entry(_ id: Int32, kind: FileKind, folder: Bool, depth: Int) -> LayoutInput.Entry {
        let display = NodeDisplay(role: folder ? (depth == 0 ? .root : .folder) : .file,
                                  title: folder ? "Folder \(id)" : "File \(id)",
                                  subtitle: folder ? "Test folder" : "\(id % 997) KB",
                                  modifiedAt: nil, glyph: GlyphTable.byKind[kind] ?? "", kind: kind,
                                  flags: folder ? [.expanded, .hasChildren] : [])
        let size = folder ? TreeInputBuilder.folderSize : TreeInputBuilder.fileSize
        return LayoutInput.Entry(key: .debug(id), size: size, display: display)
    }
}
