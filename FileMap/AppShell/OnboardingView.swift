import SwiftUI

/// First-launch screen asking for Full Disk Access.
struct OnboardingView: View {
    let app: AppModel
    @State private var opened = false

    var body: some View {
        VStack(spacing: 22) {
            GlyphText(glyph: GlyphTable.volume, size: 46, color: .accentColor)
            Text("Map your whole drive").font(.largeTitle.weight(.semibold))
            Text("FileMap draws every folder on your Mac as a zoomable map. To see everything — including Mail, Messages, Safari data, and other protected folders — it needs **Full Disk Access**.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Click **Open System Settings**.")
                step(2, "Turn on **FileMap** in the list (use **+** to add it if it isn't there).")
                step(3, "Come back here — FileMap continues on its own.")
            }
            .padding(16)
            .glassPanel(cornerRadius: 14)
            HStack(spacing: 12) {
                Button {
                    opened = true
                    FullDiskAccess.openSystemSettings()
                    app.watchForPermission()
                } label: {
                    Text("Open System Settings").padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button("Continue Without Full Disk Access") { app.continueWithoutAccess() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            if opened {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…").foregroundStyle(.secondary)
                }
            }
            Text("Without it, FileMap maps your home folder, Applications, and external drives.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: 640)
        .glassPanel(cornerRadius: 28)
        .padding(40)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.monospacedDigit().weight(.semibold)).frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            Text(text)
        }
    }
}
