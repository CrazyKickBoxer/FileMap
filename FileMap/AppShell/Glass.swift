import SwiftUI

extension View {
    /// Frosted Liquid Glass panel (macOS 26+ `glassEffect`).
    func glassPanel(cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
    }

    func glassCapsule() -> some View {
        glassEffect(.regular, in: .capsule)
    }
}

/// Text in the bundled Nerd Font, for glyph icons.
struct GlyphText: View {
    let glyph: String
    var size: CGFloat = 14
    var color: Color = .secondary

    var body: some View {
        Text(glyph).font(.custom(FontLoader.glyphFontName, size: size)).foregroundStyle(color)
    }
}
