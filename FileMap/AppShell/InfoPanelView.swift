import SwiftUI

/// Get Info side panel.
struct InfoPanelView: View {
    let map: MapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let node = map.infoNode {
                HStack(spacing: 10) {
                    GlyphText(glyph: GlyphTable.glyph(name: node.name, uti: node.uti, kind: node.kind, isFolder: node.isFolder), size: 26,
                              color: Theme(.dark).accent(node.isFolder ? .folder : node.kind))
                    Text(node.name).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Kind", kindText(node))
                    row("Size", Format.bytes(node.size))
                    row("On disk", Format.bytes(node.allocSize))
                    if node.isFolder { row("Items", Format.count(node.itemCount)) }
                    row("Created", Format.dateTime(node.createdAt))
                    row("Modified", Format.dateTime(node.modifiedAt))
                    row("Opened", Format.dateTime(node.openedAt))
                    if node.isSystem { row("Protection", "System location") }
                    if !node.hasAccess { row("Access", "No permission to read") }
                }
                .font(.callout)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where").font(.caption).foregroundStyle(.secondary)
                    Text(node.path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(6)
                }
                HStack {
                    Button("Open") { map.fileOps?.open([node]) }
                    Button("Reveal") { map.fileOps?.revealInFinder([node]) }
                    Button("Copy Path") { map.fileOps?.copyPath([node]) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                if map.mode == .cluster {
                    Button {
                        Task { await map.reveal(nodeID: node.id) }
                    } label: {
                        Label("Show in Tree", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(.glassProminent)
                }
            } else {
                Text("Nothing selected").foregroundStyle(.secondary)
                Text("Select a file or folder to see its details.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 290, alignment: .leading)
        .glassPanel(cornerRadius: 20)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func kindText(_ node: Node) -> String {
        if node.isFolder { return "Folder" }
        if node.isLink { return "Symbolic link" }
        if let uti = node.uti, let type = UTTypeLookup.description(uti) { return type }
        return node.kind.displayName
    }
}

import UniformTypeIdentifiers

enum UTTypeLookup {
    static func description(_ identifier: String) -> String? {
        UTType(identifier)?.localizedDescription
    }
}
