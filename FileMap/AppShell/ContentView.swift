import SwiftUI

struct ContentView: View {
    let app: AppModel

    var body: some View {
        ZStack {
            BackgroundView()
            switch app.phase {
            case .onboarding:
                OnboardingView(app: app)
            case .failed(let message):
                ContentUnavailableView("FileMap can't start", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                if let map = app.map, let search = app.search {
                    MapScreen(app: app, map: map, search: search)
                }
            }
        }
    }
}

/// The main map screen: the map itself with floating glass panels around it.
struct MapScreen: View {
    let app: AppModel
    let map: MapModel
    let search: SearchModel

    var body: some View {
        ZStack {
            MapContainerView(map: map)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    BreadcrumbBar(map: map)
                    Spacer(minLength: 0)
                }
                if app.isLimited {
                    LimitedAccessBanner()
                }
                HStack(alignment: .top, spacing: 12) {
                    if app.settings.showPins, let pins = app.pins {
                        PinSidebarView(pins: pins, map: map)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if app.settings.showInfo {
                        InfoPanelView(map: map)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    ScanStatusView(app: app)
                    Spacer(minLength: 0)
                    if app.showFPS { FPSMeter(map: map) }
                    if app.settings.showMiniMap && !map.isDebugActive {
                        MiniMapView(map: map)
                    }
                }
            }
            .padding(14)
            .animation(.easeInOut(duration: 0.22), value: app.settings.showPins)
            .animation(.easeInOut(duration: 0.22), value: app.settings.showInfo)

            if search.isPresented {
                SearchBarView(search: search, map: map)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            if map.isBuildingDebugTree {
                ProgressView("Building 1,111,111 boxes…").padding(20).glassPanel()
            }
        }
        .animation(.easeOut(duration: 0.18), value: search.isPresented)
        .toolbar { MapToolbar(app: app, map: map, search: search) }
        .navigationTitle(map.mode == .cluster ? "FileMap — Clusters" : "FileMap")
        .alert(map.alert?.title ?? "", isPresented: Binding(get: { map.alert != nil }, set: { if !$0 { map.alert = nil } })) {
            Button("OK") { map.alert = nil }
        } message: {
            Text(map.alert?.message ?? "")
        }
        .onChange(of: app.settings.showHiddenFiles) { Task { await map.reloadForVisibilityChange(); app.policyChanged() } }
        .onChange(of: app.settings.showSystemFiles) { Task { await map.reloadForVisibilityChange(); app.policyChanged() } }
        .onChange(of: app.settings.clusterDateField) {
            map.clusters.invalidate()
            if map.mode == .cluster { map.relayout(animated: false) }
        }
        .onChange(of: app.settings.excludedPaths) { app.policyChanged() }
    }
}

struct LimitedAccessBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
            Text("FileMap can only see your home folder, Applications, and external drives.")
                .font(.callout)
            Button("Turn On Full Disk Access") { FullDiskAccess.openSystemSettings() }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCapsule()
    }
}

struct FPSMeter: View {
    let map: MapModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text("\(Int(map.frameSink.fps)) fps · \(map.frameSink.last.boxes.count) boxes")
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassCapsule()
        }
    }
}
