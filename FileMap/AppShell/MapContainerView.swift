import SwiftUI

/// The map surface: renderer, input layer, and in-place overlays (rename field, "+ N more" grid).
struct MapContainerView: View {
    let map: MapModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ActiveMapRenderer().makeView(model: map)
            InteractionLayer(model: map)
            if let id = map.renaming, let node = map.nodes[id], let rect = map.screenRect(.node(id)) {
                RenameField(name: node.name) { newName in
                    map.renaming = nil
                    map.fileOps?.rename(node, to: newName)
                } onCancel: {
                    map.renaming = nil
                }
                .frame(width: max(140, rect.width - 50), height: 24)
                .position(x: rect.minX + 30 + max(140, rect.width - 50) / 2, y: rect.midY)
            }
            if let parent = map.moreGridParent {
                MoreGridOverlay(map: map, parentID: parent)
            }
        }
        .clipped()
    }
}

/// Inline name editor shown over a box.
struct RenameField: View {
    @State var name: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool
    @State private var finished = false

    init(name: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _name = State(initialValue: name)
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        TextField("Name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5))
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { if !focused { finish(commit: true) } }
            .accessibilityLabel("New name")
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if commit { onCommit(name) } else { onCancel() }
    }
}
