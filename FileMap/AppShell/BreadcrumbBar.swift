import SwiftUI

/// Path of the selection; each crumb flies to that folder.
struct BreadcrumbBar: View {
    let map: MapModel

    var body: some View {
        if !map.breadcrumb.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(map.breadcrumb.enumerated()), id: \.element.id) { n, node in
                        if n > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).font(.caption)
                        }
                        Button {
                            Task { await map.reveal(nodeID: node.id) }
                        } label: {
                            HStack(spacing: 5) {
                                GlyphText(glyph: n == 0 ? GlyphTable.volume : GlyphTable.glyph(name: node.name, uti: node.uti, kind: node.kind, isFolder: node.isFolder),
                                          size: 12)
                                Text(node.name).lineLimit(1)
                            }
                            .font(.callout)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Go to \(node.name)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 760, alignment: .leading)
            .glassCapsule()
        }
    }
}
