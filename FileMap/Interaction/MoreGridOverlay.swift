import SwiftUI

/// Scrollable grid of every child in a crowded folder, opened from its "+ N more" box.
struct MoreGridOverlay: View {
    let map: MapModel
    let parentID: Int64
    @State private var items: [Node] = []
    @State private var total = 0
    @State private var loading = false
    private let pageSize = 300
    private let panel = CGSize(width: 460, height: 380)

    var body: some View {
        GeometryReader { geo in
            let anchor = map.screenRect(.more(parentID)) ?? CGRect(x: geo.size.width / 2, y: geo.size.height / 2, width: 0, height: 0)
            let x = min(max(panel.width / 2 + 12, anchor.maxX + 20 + panel.width / 2), geo.size.width - panel.width / 2 - 12)
            let y = min(max(panel.height / 2 + 60, anchor.midY), geo.size.height - panel.height / 2 - 12)
            content
                .frame(width: panel.width, height: panel.height)
                .glassPanel(cornerRadius: 20)
                .position(x: x, y: y)
        }
        .task(id: parentID) { await loadMore(reset: true) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(map.nodes[parentID]?.name ?? "Folder").font(.headline).lineLimit(1)
                Text("\(Format.count(Int64(total))) items").foregroundStyle(.secondary)
                Spacer()
                Button { map.moreGridParent = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 6)], spacing: 6) {
                    ForEach(items) { node in
                        cell(node)
                            .onAppear { if node.id == items.last?.id { Task { await loadMore(reset: false) } } }
                    }
                }
                if loading { ProgressView().padding() }
            }
            Text("Click to select · double-click to open or add to the map").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    private func cell(_ node: Node) -> some View {
        let selected = map.selection.contains(.node(node.id))
        return HStack(spacing: 8) {
            GlyphText(glyph: GlyphTable.glyph(name: node.name, uti: node.uti, kind: node.kind, isFolder: node.isFolder), size: 14,
                      color: Theme(.dark).accent(node.isFolder ? .folder : node.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(Format.bytes(node.size)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(node) }
        .onTapGesture { select(node) }
        .contextMenu {
            Button("Open") { map.fileOps?.open([node]) }
            Button("Show on Map") { show(node) }
            Button("Quick Look") { select(node); map.quickLookHandler?() }
            Button("Reveal in Finder") { map.fileOps?.revealInFinder([node]) }
            Button("Copy Path") { map.fileOps?.copyPath([node]) }
            Divider()
            Button("Move to Trash") { map.fileOps?.trash([node]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select(node) }
        .accessibilityAction(named: "Open") { open(node) }
    }

    private func select(_ node: Node) {
        map.nodes[node.id] = node
        map.select(.node(node.id))
    }

    private func show(_ node: Node) {
        map.promote(node, into: parentID)
        map.moreGridParent = nil
        Task { await map.reveal(nodeID: node.id) }
    }

    private func open(_ node: Node) {
        if node.isFolder {
            show(node)
            Task { await map.expand(node.id) }
        } else {
            map.fileOps?.open([node])
        }
    }

    private func loadMore(reset: Bool) async {
        guard !loading else { return }
        if !reset, items.count >= total { return }
        loading = true
        defer { loading = false }
        let offset = reset ? 0 : items.count
        let filter = map.filter
        let parentID = self.parentID
        let size = pageSize
        do {
            let (page, count) = try await map.store.read { db in
                (try NodeQueries.childrenPage(db, of: parentID, filter: filter, offset: offset, limit: size),
                 try NodeQueries.childCount(db, of: parentID, filter: filter))
            }
            items = reset ? page : items + page
            total = count
        } catch {
            map.report("Couldn't list the folder", error)
        }
    }
}
