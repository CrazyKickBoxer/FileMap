import SwiftUI

/// SwiftUI `Canvas` backend.
struct CanvasMapRenderer: MapRenderer {
    func makeView(model: MapModel) -> some View {
        CanvasMapView(model: model)
    }
}

struct CanvasMapView: View {
    let model: MapModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Read observed state here (not inside the Canvas closure) so SwiftUI tracks it.
        let scene = model.displayScene
        let state = model.renderState
        let animating = model.isAnimating
        let camera = model.camera
        let theme = Theme(colorScheme)
        let fontName = FontLoader.glyphFontName
        let frameSink = model.frameSink
        TimelineView(.animation(minimumInterval: nil, paused: !animating)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                let cam = model.cameraAt(timeline.date) ?? camera
                let frame = SceneBuilder.build(scene: scene, camera: cam, viewSize: size, state: state, time: timeline.date)
                frameSink.record(frame)
                CanvasDrawing(theme: theme, glyphFont: fontName).draw(frame, in: &ctx)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Draws a `RenderFrame` into a SwiftUI `GraphicsContext`, batching paths where possible.
struct CanvasDrawing {
    let theme: Theme
    let glyphFont: String

    func draw(_ frame: RenderFrame, in ctx: inout GraphicsContext) {
        drawBands(frame, &ctx)
        drawEdges(frame, &ctx)
        if frame.level == .far {
            drawFarBoxes(frame, &ctx)
        } else {
            drawGlassBoxes(frame, &ctx)
        }
        drawDecorations(frame, &ctx)
        drawLabels(frame, &ctx)
        if let m = frame.marquee {
            let p = Path(m)
            ctx.fill(p, with: .color(theme.selection.opacity(0.10)))
            ctx.stroke(p, with: .color(theme.selection.opacity(0.8)), lineWidth: 1)
        }
    }

    private func corner(_ r: CGRect, scale: CGFloat) -> CGFloat {
        min(r.height / 2, max(2, 11 * min(1.2, scale)))
    }

    private func drawBands(_ frame: RenderFrame, _ ctx: inout GraphicsContext) {
        guard !frame.bands.isEmpty else { return }
        var path = Path()
        for b in frame.bands where b.width > 0.5 {
            path.addRoundedRect(in: b, cornerSize: CGSize(width: 2, height: 2))
        }
        ctx.fill(path, with: .color(theme.band))
    }

    private func curve(_ e: EdgeItem, into path: inout Path) {
        path.move(to: e.from)
        let mid = (e.from.x + e.to.x) / 2
        path.addCurve(to: e.to, control1: CGPoint(x: mid, y: e.from.y), control2: CGPoint(x: mid, y: e.to.y))
    }

    private func drawEdges(_ frame: RenderFrame, _ ctx: inout GraphicsContext) {
        guard !frame.edges.isEmpty else { return }
        var normal = Path()
        var glowing = Path()
        var fading = Path()
        for e in frame.edges {
            if e.highlighted { curve(e, into: &glowing) } else if e.alpha < 1 { curve(e, into: &fading) } else { curve(e, into: &normal) }
        }
        let thin = max(0.6, min(1.4, 1.2 * frame.scale))
        if frame.level != .far {
            ctx.stroke(normal, with: .color(theme.edgeGlow), lineWidth: thin * 4)
        }
        ctx.stroke(normal, with: .color(theme.edge), lineWidth: thin)
        ctx.stroke(fading, with: .color(theme.edge.opacity(0.4)), lineWidth: thin)
        if !glowing.isEmpty {
            ctx.stroke(glowing, with: .color(theme.selection.opacity(0.18)), lineWidth: thin * 7)
            ctx.stroke(glowing, with: .color(theme.selection.opacity(0.85)), lineWidth: thin * 1.6)
        }
    }

    /// Far zoom: flat coloured boxes, one fill per kind.
    private func drawFarBoxes(_ frame: RenderFrame, _ ctx: inout GraphicsContext) {
        var byKind: [FileKind: Path] = [:]
        var containers = Path()
        for b in frame.boxes where b.alpha > 0.02 {
            if b.display.isContainer {
                containers.addRoundedRect(in: b.rect, cornerSize: CGSize(width: 6, height: 6))
                continue
            }
            let c = min(b.rect.height / 2, 3)
            byKind[b.display.kind, default: Path()].addRoundedRect(in: b.rect, cornerSize: CGSize(width: c, height: c))
        }
        ctx.fill(containers, with: .color(theme.containerFill))
        ctx.stroke(containers, with: .color(theme.glassStroke), lineWidth: 1)
        for (kind, path) in byKind {
            ctx.fill(path, with: .color(theme.accent(kind).opacity(kind == .folder ? 0.55 : 0.7)))
        }
    }

    /// Mid/near zoom: frosted glass panels with a highlight edge and a kind accent.
    private func drawGlassBoxes(_ frame: RenderFrame, _ ctx: inout GraphicsContext) {
        var folders = Path(), files = Path(), strokes = Path(), highlights = Path(), containers = Path()
        var accents: [FileKind: Path] = [:]
        var faded: [BoxItem] = []
        for b in frame.boxes {
            if b.alpha < 0.99 || b.display.flags.contains(.dimmed) {
                faded.append(b)
                continue
            }
            let r = b.rect
            let c = corner(r, scale: frame.scale)
            let rr = Path(roundedRect: r, cornerRadius: c, style: .continuous)
            if b.display.isContainer {
                containers.addPath(Path(roundedRect: r, cornerRadius: min(28, 22 * frame.scale + 4), style: .continuous))
                continue
            }
            if b.display.role == .file || b.display.role == .package || b.display.role == .more { files.addPath(rr) } else { folders.addPath(rr) }
            strokes.addPath(rr)
            if r.width > c * 2 + 2 {
                highlights.move(to: CGPoint(x: r.minX + c, y: r.minY + 0.75))
                highlights.addLine(to: CGPoint(x: r.maxX - c, y: r.minY + 0.75))
            }
            if b.display.role != .more {
                let lr = Self.labelRect(r, scale: frame.scale)
                let bar = CGRect(x: lr.minX + max(3, c * 0.35), y: lr.minY + lr.height * 0.28, width: max(1.5, 3 * frame.scale), height: lr.height * 0.44)
                accents[b.display.kind, default: Path()].addRoundedRect(in: bar, cornerSize: CGSize(width: 1.5, height: 1.5))
            }
        }
        ctx.fill(containers, with: .color(theme.containerFill))
        ctx.stroke(containers, with: .color(theme.glassStroke), lineWidth: 1)
        ctx.fill(folders, with: .color(theme.glassFill))
        ctx.fill(files, with: .color(theme.glassFillFile))
        ctx.stroke(strokes, with: .color(theme.glassStroke), lineWidth: 1)
        ctx.stroke(highlights, with: .color(theme.glassHighlight), lineWidth: 1)
        for (kind, path) in accents { ctx.fill(path, with: .color(theme.accent(kind).opacity(0.9))) }

        for b in faded {
            var layer = ctx
            layer.opacity = b.alpha * (b.display.flags.contains(.dimmed) ? 0.45 : 1)
            let rr = Path(roundedRect: b.rect, cornerRadius: corner(b.rect, scale: frame.scale), style: .continuous)
            layer.fill(rr, with: .color(b.display.isContainer ? theme.containerFill : theme.glassFill))
            layer.stroke(rr, with: .color(theme.glassStroke), lineWidth: 1)
        }
    }

    private func drawDecorations(_ frame: RenderFrame, _ ctx: inout GraphicsContext) {
        for b in frame.boxes where b.selected || b.focused || b.dropTarget || b.pulse != nil || b.onPath {
            let c = b.display.isContainer ? min(28, 22 * frame.scale + 4) : corner(b.rect, scale: frame.scale)
            let rr = Path(roundedRect: b.rect, cornerRadius: c, style: .continuous)
            if b.dropTarget {
                ctx.fill(rr, with: .color(theme.selection.opacity(0.16)))
                ctx.stroke(rr, with: .color(theme.selection), lineWidth: 2.5)
            } else if b.selected {
                ctx.fill(rr, with: .color(theme.selection.opacity(0.12)))
                ctx.stroke(rr, with: .color(theme.selection.opacity(0.95)), lineWidth: b.focused ? 2.2 : 1.6)
            } else if b.onPath, frame.level != .far, !b.display.isContainer {
                ctx.stroke(rr, with: .color(theme.selection.opacity(0.35)), lineWidth: 1)
            }
            if let p = b.pulse {
                let grow = CGFloat(p) * 18
                let ring = Path(roundedRect: b.rect.insetBy(dx: -grow, dy: -grow), cornerRadius: c + grow, style: .continuous)
                ctx.stroke(ring, with: .color(theme.selection.opacity(Double(1 - p) * 0.9)), lineWidth: 2.5)
            }
        }
    }

    private func drawLabels(_ frame: RenderFrame, _ ctx: inout GraphicsContext) {
        for b in frame.boxes where b.text != .none {
            var layer = ctx
            layer.opacity = b.alpha * (b.display.flags.contains(.dimmed) ? 0.6 : 1)
            if b.display.isContainer {
                drawHeader(b, frame: frame, in: &layer)
            } else {
                drawBoxLabel(b, frame: frame, in: &layer)
            }
        }
    }

    private func truncated(_ s: String, width: CGFloat, fontSize: CGFloat) -> String {
        let maxChars = max(1, Int(width / (fontSize * 0.56)))
        guard s.count > maxChars else { return s }
        return String(s.prefix(max(1, maxChars - 1))) + "…"
    }

    /// The strip of a box that holds its text: the whole box, or the top of a tall (size-view) box.
    static func labelRect(_ r: CGRect, scale: CGFloat) -> CGRect {
        let band = TreeInputBuilder.folderSize.height * scale
        guard r.height > band * 1.25 else { return r }
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: band)
    }

    private func drawBoxLabel(_ b: BoxItem, frame: RenderFrame, in ctx: inout GraphicsContext) {
        let r = Self.labelRect(b.rect, scale: frame.scale)
        let showSub = b.text >= .titleSubtitle && r.height >= 30
        let titleSize = min(16, max(9, r.height * (showSub ? 0.27 : 0.42)))
        let subSize = titleSize * 0.82
        let showGlyph = b.text >= .titleSubtitle || frame.level == .near
        let leftPad = max(8, r.height * 0.22) + (b.display.role == .more ? 0 : 5)
        var x = r.minX + leftPad
        if showGlyph {
            let gs = titleSize * 1.15
            let glyph = Text(b.display.glyph).font(.custom(glyphFont, size: gs)).foregroundStyle(theme.accent(b.display.kind))
            ctx.draw(glyph, at: CGPoint(x: x + gs * 0.5, y: r.midY), anchor: .center)
            x += gs * 1.5
        }
        var trailing: CGFloat = 8
        var markers = ""
        if b.display.flags.contains(.pinned) { markers += GlyphTable.pin }
        if b.display.flags.contains(.noAccess) { markers += GlyphTable.lock }
        if b.display.flags.contains(.link) { markers += GlyphTable.link }
        if b.display.role == .folder || b.display.role == .root, b.display.flags.contains(.hasChildren) {
            markers += b.display.flags.contains(.expanded) ? "\u{F104}" : "\u{F105}"  // nf-fa-angle_left / angle_right
        }
        if !markers.isEmpty {
            let ms = titleSize * 0.95
            let text = Text(markers).font(.custom(glyphFont, size: ms)).foregroundStyle(theme.secondaryText)
            ctx.draw(text, at: CGPoint(x: r.maxX - 8, y: r.midY), anchor: .trailing)
            trailing += ms * CGFloat(markers.count) * 1.1
        }
        let width = max(10, r.maxX - trailing - x)
        let titleY = showSub ? r.midY - subSize * 0.62 : r.midY
        let weight: Font.Weight = (b.display.role == .file || b.display.role == .package) ? .regular : .medium
        let title = Text(truncated(b.display.title, width: width, fontSize: titleSize))
            .font(.system(size: titleSize, weight: weight)).foregroundStyle(theme.primaryText)
        ctx.draw(title, at: CGPoint(x: x, y: titleY), anchor: .leading)
        if showSub {
            var sub = b.display.subtitle
            if b.text == .full, let m = b.display.modifiedAt, r.width * 1 > 200 { sub += "  ·  " + Format.day(m) }
            let subtitle = Text(truncated(sub, width: width, fontSize: subSize))
                .font(.system(size: subSize)).foregroundStyle(theme.secondaryText)
            ctx.draw(subtitle, at: CGPoint(x: x, y: r.midY + titleSize * 0.62), anchor: .leading)
        }
    }

    private func drawHeader(_ b: BoxItem, frame: RenderFrame, in ctx: inout GraphicsContext) {
        var r = b.rect
        var header = min(r.height, NestedGridLayout.Spacing().header * frame.scale)
        if b.display.role == .cluster, header < 30 {
            // Zoomed out: put a fixed-size title just above the region instead of inside it.
            header = 34
            r = CGRect(x: r.minX - 8, y: r.minY - header, width: max(r.width, 180), height: header)
        }
        let titleSize = min(26, max(10, header * (b.display.role == .cluster ? 0.36 : 0.30)))
        let pad = max(8, 16 * frame.scale)
        let gs = titleSize * 1.1
        let glyph = Text(b.display.glyph).font(.custom(glyphFont, size: gs)).foregroundStyle(theme.accent(b.display.kind))
        ctx.draw(glyph, at: CGPoint(x: r.minX + pad + gs / 2, y: r.minY + header * 0.42), anchor: .center)
        let x = r.minX + pad + gs * 1.6
        let width = r.maxX - pad - x
        let title = Text(truncated(b.display.title, width: width, fontSize: titleSize))
            .font(.system(size: titleSize, weight: .semibold)).foregroundStyle(theme.primaryText)
        ctx.draw(title, at: CGPoint(x: x, y: r.minY + header * 0.42), anchor: .leading)
        if b.text >= .titleSubtitle {
            let s = titleSize * 0.62
            let sub = Text(truncated(b.display.subtitle, width: width, fontSize: s)).font(.system(size: s)).foregroundStyle(theme.secondaryText)
            ctx.draw(sub, at: CGPoint(x: x, y: r.minY + header * 0.42 + titleSize * 0.85), anchor: .leading)
        }
    }
}

/// Keeps the last drawn frame for hit-testing helpers, accessibility, and the FPS meter,
/// without triggering SwiftUI updates.
final class FrameSink: @unchecked Sendable {
    private(set) var last = RenderFrame()
    private var stamps: [CFTimeInterval] = []

    func record(_ frame: RenderFrame) {
        last = frame
        let now = CACurrentMediaTime()
        stamps.append(now)
        if stamps.count > 120 { stamps.removeFirst(stamps.count - 120) }
    }

    /// Frames per second over the last second of drawing.
    var fps: Double {
        let now = CACurrentMediaTime()
        let recent = stamps.filter { now - $0 < 1 }
        return Double(recent.count)
    }
}
