import SwiftUI

/// Slim glass sidebar listing pins. Click to fly; drag to reorder; right-click to rename or remove.
struct PinSidebarView: View {
    let pins: PinStore
    let map: MapModel
    @State private var renaming: PinItem?
    @State private var newLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                GlyphText(glyph: GlyphTable.pin, size: 12)
                Text("Pins").font(.headline)
            }
            .padding(.horizontal, 6)
            if pins.pins.isEmpty {
                Text("Pin files or folders with ⌘D or the right-click menu.")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            } else {
                List {
                    ForEach(pins.pins) { pin in
                        row(pin)
                    }
                    .onMove { source, dest in Task { await pins.move(fromOffsets: source, toOffset: dest) } }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 420)
            }
        }
        .padding(10)
        .frame(width: 220)
        .fixedSize(horizontal: false, vertical: true)
        .glassPanel(cornerRadius: 18)
        .alert("Rename Pin", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newLabel)
            Button("Rename") {
                if let pin = renaming { Task { await pins.rename(pin, to: newLabel) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ pin: PinItem) -> some View {
        HStack(spacing: 8) {
            if pin.isBroken {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            } else {
                GlyphText(glyph: map.nodes[pin.nodeID ?? -1].map { GlyphTable.glyph(name: $0.name, uti: $0.uti, kind: $0.kind, isFolder: $0.isFolder) } ?? GlyphTable.folder, size: 12)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(pin.label).lineLimit(1).foregroundStyle(pin.isBroken ? .secondary : .primary)
                if pin.isBroken { Text("Missing").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if pin.isBroken {
                Button { Task { await pins.remove(pin) } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).help("Remove pin").accessibilityLabel("Remove \(pin.label)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let id = pin.nodeID else { return }
            Task { await map.reveal(nodeID: id) }
        }
        .contextMenu {
            Button("Rename…") { newLabel = pin.label; renaming = pin }
            Button("Remove Pin") { Task { await pins.remove(pin); map.relayout(animated: false) } }
        }
        .accessibilityAction {
            guard let id = pin.nodeID else { return }
            Task { await map.reveal(nodeID: id) }
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(pin.isBroken ? "\(pin.label), missing" : pin.label)
    }
}
