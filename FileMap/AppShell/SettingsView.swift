import AppKit
import SwiftUI

struct SettingsView: View {
    let app: AppModel
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Show") {
                Toggle("Show system files", isOn: $settings.showSystemFiles)
                Text("System locations such as /System and /Library appear dimmed and can't be moved, renamed, or trashed.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
                Toggle("Show mini-map", isOn: $settings.showMiniMap)
            }
            Section("Scanning") {
                Toggle("Treat packages as single items", isOn: $settings.treatPackagesAsItems)
                Text("Apps and other bundles count as one item. Changes apply after the next rescan.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Excluded folders and volumes")
                    List {
                        ForEach(settings.excludedPaths, id: \.self) { Text($0).font(.callout.monospaced()) }
                            .onDelete { settings.excludedPaths.remove(atOffsets: $0) }
                    }
                    .frame(minHeight: 70, maxHeight: 120)
                    HStack {
                        Button("Add…") { addExcluded() }
                        Button("Remove") { if !settings.excludedPaths.isEmpty { settings.excludedPaths.removeLast() } }
                            .disabled(settings.excludedPaths.isEmpty)
                    }
                }
            }
            Section("Clusters") {
                Picker("Date used for clustering", selection: $settings.clusterDateField) {
                    ForEach(ClusterDateField.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Trash") {
                Stepper("Ask before trashing more than \(settings.trashConfirmCount) items", value: $settings.trashConfirmCount, in: 1...10_000, step: 10)
                Stepper(String(format: "…or more than %.1f GB", settings.trashConfirmGB), value: $settings.trashConfirmGB, in: 0.1...1000, step: 0.5)
            }
            Section("Index") {
                HStack {
                    Button("Rescan Now") { app.rescan() }
                    Button("Clear Index…", role: .destructive) { confirmClear = true }
                }
                if app.hasFullDiskAccess {
                    Label("Full Disk Access is on", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                } else {
                    HStack {
                        Label("Full Disk Access is off", systemImage: "lock.shield").foregroundStyle(.secondary)
                        Button("Turn On…") { FullDiskAccess.openSystemSettings(); app.watchForPermission() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .confirmationDialog("Clear the index?", isPresented: $confirmClear) {
            Button("Clear Index", role: .destructive) { app.clearIndex() }
        } message: {
            Text("The map will be empty until you rescan. Your files are not touched; pins are kept.")
        }
    }

    private func addExcluded() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !app.settings.excludedPaths.contains(url.path) {
            app.settings.excludedPaths.append(url.path)
        }
    }
}
