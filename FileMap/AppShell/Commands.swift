import AppKit
import SwiftUI

/// Menu bar commands. Every action has a menu item (and most a shortcut) for full keyboard access.
struct FileMapCommands: Commands {
    let app: AppModel

    private var map: MapModel? { app.map }
    private var actions: MapActions? { map.map { MapActions(model: $0) } }
    private var hasSelection: Bool { !(map?.selectedNodes.isEmpty ?? true) }
    /// Destructive shortcuts only fire while the map itself has keyboard focus (not a text field).
    private var mapHasFocus: Bool { NSApp.keyWindow?.firstResponder is InteractionView }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { Task { await actions?.newFolder() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open") { Task { await actions?.open() } }
                .keyboardShortcut("o")
                .disabled(!hasSelection)
            Button("Quick Look") { actions?.quickLook() }
                .keyboardShortcut("y")
                .disabled(!hasSelection)
            Button("Rename") { actions?.rename() }
                .disabled(!hasSelection)
            Button("Move to Trash") { if mapHasFocus { actions?.trash() } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasSelection)
            Divider()
            Button("Get Info") { actions?.getInfo() }
                .keyboardShortcut("i")
            Button("Reveal in Finder") { actions?.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Button("Copy Path") { actions?.copyPath() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!hasSelection)
            Button("Open in Terminal") { actions?.openInTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!hasSelection)
            Button("Pin / Unpin") { Task { await actions?.togglePin() } }
                .keyboardShortcut("d")
                .disabled(!hasSelection)
        }

        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { n, mode in
                Button("\(mode.title) View") { map?.setMode(mode) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n + 1))))
            }
            Divider()
            Button("Fit Whole Map") { map?.fitAll() }
                .keyboardShortcut("0")
            Button("Zoom In") { map?.moveCamera { $0.zoom(by: 1.4, around: CGPoint(x: (map?.viewSize.width ?? 0) / 2, y: (map?.viewSize.height ?? 0) / 2), in: map?.viewSize ?? .zero) } }
                .keyboardShortcut("+")
            Button("Zoom Out") { map?.moveCamera { $0.zoom(by: 1 / 1.4, around: CGPoint(x: (map?.viewSize.width ?? 0) / 2, y: (map?.viewSize.height ?? 0) / 2), in: map?.viewSize ?? .zero) } }
                .keyboardShortcut("-")
            Button("Zoom to Selection") { map?.fitSelection() }
                .keyboardShortcut("=", modifiers: [.command, .option])
            Divider()
            Toggle("Show Pins", isOn: Binding(get: { app.settings.showPins }, set: { app.settings.showPins = $0 }))
                .keyboardShortcut("p", modifiers: [.command, .option])
            Toggle("Show Info", isOn: Binding(get: { app.settings.showInfo }, set: { app.settings.showInfo = $0 }))
            Toggle("Show Mini-Map", isOn: Binding(get: { app.settings.showMiniMap }, set: { app.settings.showMiniMap = $0 }))
                .keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu("Go") {
            Button("Find…") { app.search?.isPresented = true }
                .keyboardShortcut("f")
            Button("Enclosing Folder") { map?.goToParent() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Home") { Task { await map?.goHome() } }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Select Parent's Children") { map?.selectAll() }
        }

        CommandMenu("Scan") {
            if app.scanProgress?.phase == .paused {
                Button("Resume Scan") { app.resumeScan() }
            } else {
                Button("Pause Scan") { app.pauseScan() }.disabled(!app.isScanning)
            }
            Button("Stop Scan") { app.cancelScan() }.disabled(!app.isScanning)
            if app.scanInterrupted && !app.isScanning {
                Button("Resume Interrupted Scan") { app.startScan(resume: true) }
            }
            Divider()
            Button("Rescan Now") { app.rescan() }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
        }

        CommandMenu("Debug") {
            Button("Build 1M-Node Test Tree") { map?.enterDebugTree() }
            Button("Exit Test Tree") { map?.exitDebugTree() }
            Toggle("Show Frame Rate", isOn: Binding(get: { app.showFPS }, set: { app.showFPS = $0 }))
        }
    }
}
