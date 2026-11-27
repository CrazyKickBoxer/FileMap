import SwiftUI

/// Soft, slowly drifting blurred gradient behind the map. No images or textures.
struct BackgroundView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        let dark = scheme == .dark
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                (dark ? Color(hex: 0x0D1015) : Color(hex: 0xEDF0F4))
                blob(dark ? 0x2A3D57 : 0xC9D8EA, size: max(w, h) * 0.75)
                    .offset(x: drift ? -w * 0.18 : -w * 0.30, y: drift ? -h * 0.22 : -h * 0.10)
                blob(dark ? 0x37304F : 0xDCD3EC, size: max(w, h) * 0.65)
                    .offset(x: drift ? w * 0.28 : w * 0.16, y: drift ? h * 0.18 : h * 0.30)
                blob(dark ? 0x1E4140 : 0xCFE6E0, size: max(w, h) * 0.5)
                    .offset(x: drift ? w * 0.05 : w * 0.22, y: drift ? -h * 0.05 : -h * 0.25)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 28).repeatForever(autoreverses: true)) { drift = true }
        }
        .accessibilityHidden(true)
    }

    private func blob(_ hex: UInt32, size: CGFloat) -> some View {
        Circle()
            .fill(Color(hex: hex).opacity(scheme == .dark ? 0.55 : 0.75))
            .frame(width: size, height: size)
            .blur(radius: size * 0.22)
    }
}
