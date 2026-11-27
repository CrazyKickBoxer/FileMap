import SwiftUI

/// Scan progress: items, rough percentage, current path, and pause/resume/stop.
struct ScanStatusView: View {
    let app: AppModel

    var body: some View {
        if let p = app.scanProgress, p.isActive {
            HStack(spacing: 12) {
                ProgressView(value: p.fraction).frame(width: 90)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(p)).font(.callout.weight(.medium)).monospacedDigit()
                    Text(p.currentPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 320, alignment: .leading)
                }
                if p.phase == .paused {
                    Button { app.resumeScan() } label: { Image(systemName: "play.fill") }.help("Resume scan")
                } else {
                    Button { app.pauseScan() } label: { Image(systemName: "pause.fill") }.help("Pause scan")
                        .disabled(p.phase == .finishing)
                }
                Button { app.cancelScan() } label: { Image(systemName: "xmark") }.help("Stop scan")
                    .disabled(p.phase == .finishing)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassPanel(cornerRadius: 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Scan progress")
        } else if app.scanInterrupted {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                Text("The scan didn't finish.").font(.callout)
                Button("Resume") { app.startScan(resume: true) }.buttonStyle(.glass)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule()
        }
    }

    private func title(_ p: ScanProgress) -> String {
        let items = Format.count(Int64(p.items))
        switch p.phase {
        case .preparing: return "Preparing…"
        case .paused: return "Paused · \(items) items"
        case .finishing: return "Finishing up · \(items) items"
        default: return "Scanning · \(items) items · \(Int(p.fraction * 100))%"
        }
    }
}
