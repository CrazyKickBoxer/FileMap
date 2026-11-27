import SwiftUI

/// Corner overview of the whole map with the visible area outlined. Click or drag to move there.
struct MiniMapView: View {
    let map: MapModel
    @Environment(\.colorScheme) private var scheme
    private let size = CGSize(width: 220, height: 150)

    var body: some View {
        let scene = map.displayScene
        let fit = Camera.fit(scene.bounds, in: size, padding: 8, maxScale: 1)
        ZStack(alignment: .topLeading) {
            MiniMapContent(scene: scene, camera: fit, theme: Theme(scheme)).equatable()
            ViewportOutline(map: map, fit: fit, size: size)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 14))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let world = fit.toWorld(value.location, in: size)
            map.moveCamera { $0.center = world }
        })
        .glassPanel(cornerRadius: 14)
        .accessibilityElement()
        .accessibilityLabel("Mini-map")
        .accessibilityHint("Click to move the view")
    }
}

/// Redraws only when the scene changes, not on every pan.
private struct MiniMapContent: View, Equatable {
    let scene: MapScene
    let camera: Camera
    let theme: Theme

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.camera == b.camera && a.scene.nodes.count == b.scene.nodes.count && a.scene.bounds == b.scene.bounds && a.theme.dark == b.theme.dark
    }

    var body: some View {
        Canvas { ctx, size in
            let frame = SceneBuilder.build(scene: scene, camera: camera, viewSize: size, state: RenderState(), time: Date())
            var far = frame
            far.level = .far
            far.edges = []
            CanvasDrawing(theme: theme, glyphFont: FontLoader.glyphFontName).draw(far, in: &ctx)
        }
    }
}

private struct ViewportOutline: View {
    let map: MapModel
    let fit: Camera
    let size: CGSize

    var body: some View {
        let visible = map.camera.visibleRect(in: map.viewSize)
        let r = fit.toScreen(visible, in: size)
        Rectangle()
            .path(in: r)
            .stroke(Color.accentColor, lineWidth: 1.5)
            .background(Rectangle().path(in: r).fill(Color.accentColor.opacity(0.08)))
            .allowsHitTesting(false)
    }
}
