import SwiftUI

struct MapToolbar: ToolbarContent {
    let app: AppModel
    let map: MapModel
    let search: SearchModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { app.settings.showPins.toggle() } label: { Label("Pins", systemImage: "sidebar.left") }
                .help("Show or hide pins (⌥⌘P)")
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: Binding(get: { map.mode }, set: { map.setMode($0) })) {
                ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Tree, Size, or Cluster view (⌘1–⌘3)")
        }
        if map.mode == .cluster {
            ToolbarItem {
                ClusterOptions(app: app, map: map)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { map.fitAll() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Fit the whole map (⌘0)")
            Button { search.isPresented.toggle() } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search by name (⌘F)")
            Button { app.settings.showInfo.toggle() } label: { Label("Info", systemImage: "info.circle") }
                .help("Get Info (⌘I)")
        }
    }
}

struct ClusterOptions: View {
    let app: AppModel
    let map: MapModel

    var body: some View {
        let clusters = map.clusters
        HStack(spacing: 8) {
            Picker("Group by", selection: Binding(get: { clusters.grouping }, set: { clusters.grouping = $0; map.relayout(animated: false); map.fitAll(animated: false) })) {
                ForEach(ClusterGrouping.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if clusters.grouping == .date || clusters.grouping == .type {
                Picker("Date", selection: Binding(get: { app.settings.clusterDateField }, set: { app.settings.clusterDateField = $0 })) {
                    ForEach(ClusterDateField.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Which date to group by")
            }
            Picker("Scope", selection: Binding(get: { clusters.scopeToSelection }, set: { scoped in
                if scoped {
                    // Scope to the folder selected in the tree (or the folder holding the selected file).
                    let n = map.focusedNode
                    let folder = n.flatMap { $0.isFolder ? $0 : $0.parentID.flatMap { map.nodes[$0] } }
                    clusters.scopePath = folder?.path ?? NSHomeDirectory()
                }
                clusters.scopeToSelection = scoped
                map.relayout(animated: false)
                map.fitAll(animated: false)
            })) {
                Text("Whole Drive").tag(false)
                Text(clusters.scopeToSelection ? "In \(clusters.scopePath?.lastPathComponentFast ?? "Folder")" : "Selected Folder").tag(true)
            }
            .pickerStyle(.menu)
            .fixedSize()
            if clusters.isLoading { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
    }
}
