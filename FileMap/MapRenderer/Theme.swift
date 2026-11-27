import SwiftUI

/// Muted colours for light and dark appearance. One accent per file kind.
struct Theme {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    private static let accents: [FileKind: (light: UInt32, dark: UInt32)] = [
        .folder: (0x7F95AD, 0x9DB3CB),
        .picture: (0x4FA38F, 0x6CC3AE),
        .video: (0x8A74C4, 0xA894E0),
        .audio: (0xC9728F, 0xE492AE),
        .document: (0x5B8BC9, 0x7FA8E0),
        .code: (0xC4924A, 0xDDB070),
        .archive: (0xA08A6C, 0xC2AA8A),
        .app: (0x6C7BD6, 0x8E9BEB),
        .other: (0x8C929A, 0xA8AEB6),
    ]

    func accent(_ kind: FileKind) -> Color {
        let pair = Self.accents[kind] ?? (0x8C929A, 0xA8AEB6)
        return Color(hex: dark ? pair.dark : pair.light)
    }

    var glassFill: Color { dark ? Color.white.opacity(0.075) : Color.white.opacity(0.58) }
    var glassFillFile: Color { dark ? Color.white.opacity(0.05) : Color.white.opacity(0.42) }
    var glassStroke: Color { dark ? Color.white.opacity(0.16) : Color.black.opacity(0.09) }
    var glassHighlight: Color { dark ? Color.white.opacity(0.14) : Color.white.opacity(0.9) }
    var primaryText: Color { dark ? Color.white.opacity(0.92) : Color.black.opacity(0.82) }
    var secondaryText: Color { dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5) }
    var edge: Color { dark ? Color.white.opacity(0.28) : Color(hex: 0x51627A).opacity(0.35) }
    var edgeGlow: Color { dark ? Color(hex: 0x9DB3CB).opacity(0.10) : Color(hex: 0x7F95AD).opacity(0.12) }
    var selection: Color { Color.accentColor }
    var band: Color { dark ? Color.white.opacity(0.10) : Color(hex: 0x51627A).opacity(0.14) }
    var containerFill: Color { dark ? Color.white.opacity(0.045) : Color.white.opacity(0.35) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
