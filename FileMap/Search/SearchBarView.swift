import SwiftUI

/// ⌘F glass search bar with filters; picking a result flies the map there.
struct SearchBarView: View {
    let search: SearchModel
    let map: MapModel
    @FocusState private var focused: Bool

    private let sizeOptions: [(String, Int64)] = [("Any size", 0), ("> 1 MB", 1_000_000), ("> 100 MB", 100_000_000), ("> 1 GB", 1_000_000_000)]
    private let dateOptions: [(String, Int?)] = [("Any time", nil), ("Past day", 1), ("Past week", 7), ("Past month", 30), ("Past year", 365)]

    var body: some View {
        @Bindable var search = search
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name", text: $search.text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { pick(search.highlighted) }
                    .onKeyPress(.downArrow) { search.moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { search.moveHighlight(-1); return .handled }
                    .onExitCommand { close() }
                if !search.text.isEmpty {
                    Text("\(search.results.count) · \(Int(search.elapsedMS.rounded())) ms")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button { close() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close search")
            }
            HStack(spacing: 8) {
                Picker("Kind", selection: $search.filters.kind) {
                    Text("Any kind").tag(FileKind?.none)
                    ForEach(FileKind.allCases, id: \.self) { Text($0.displayName).tag(FileKind?.some($0)) }
                }
                Picker("Size", selection: $search.filters.minSize) {
                    ForEach(sizeOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("Modified", selection: $search.filters.modifiedWithinDays) {
                    ForEach(dateOptions, id: \.0) { Text($0.0).tag($0.1) }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            if !search.results.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(search.results.enumerated()), id: \.element.id) { n, node in
                                row(node, highlighted: n == search.highlighted)
                                    .id(n)
                                    .onTapGesture { pick(n) }
                                    .accessibilityAction { pick(n) }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: search.highlighted) { proxy.scrollTo(search.highlighted, anchor: .center) }
                }
            } else if search.text.count > 0 {
                Text("No matches").foregroundStyle(.secondary).padding(.vertical, 6)
            }
        }
        .padding(14)
        .frame(width: 600)
        .glassPanel(cornerRadius: 22)
        .onAppear { focused = true }
    }

    private func row(_ node: Node, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            GlyphText(glyph: GlyphTable.glyph(name: node.name, uti: node.uti, kind: node.kind, isFolder: node.isFolder), size: 15,
                      color: Theme(.dark).accent(node.isFolder ? .folder : node.kind))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                Text(node.path.parentPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Format.bytes(node.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(highlighted ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func pick(_ index: Int) {
        guard search.results.indices.contains(index) else { return }
        let node = search.results[index]
        close()
        Task { await map.reveal(nodeID: node.id) }
    }

    private func close() {
        search.dismiss()
    }
}
