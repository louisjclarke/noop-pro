#if os(iOS)
import SwiftUI
import StrandDesign
import StrandGlucose

/// Today screen: live glucose and the Whole Picture score, one tap from each full screen. Renders
/// nothing until the first glucose reading exists, so a WHOOP-only user never sees an empty card.
struct GlucoseTodayCard: View {
    @ObservedObject private var hub = GlucoseHub.shared
    @AppStorage(GlucosePrefs.unit) private var unitRaw = GlucoseUnit.mmol.rawValue
    @AppStorage(GlucosePrefs.profile) private var profileRaw = GlucoseProfile.generalHealth.rawValue

    private var unit: GlucoseUnit { GlucoseUnit(rawValue: unitRaw) ?? .mmol }
    private var profile: GlucoseProfile { GlucoseProfile(rawValue: profileRaw) ?? .generalHealth }

    var body: some View {
        if let r = hub.latest {
            HStack(spacing: NoopMetrics.gap) {
                NavigationLink { GlucoseView() } label: { glucoseTile(r) }
                    .buttonStyle(.plain)
                NavigationLink { WholePictureView() } label: { pictureTile }
                    .buttonStyle(.plain)
            }
        }
    }

    private func tint(_ mgdl: Double) -> Color {
        mgdl < profile.targetLow ? StrandPalette.statusCritical
            : (mgdl > profile.targetHigh ? StrandPalette.statusWarning : StrandPalette.statusPositive)
    }

    private func glucoseTile(_ r: GlucoseReading) -> some View {
        let now = Int(Date().timeIntervalSince1970)
        let trace = GlucoseSeries.slice(hub.recent, from: now - 3 * 3600, to: now + 600)
        let stale = now - r.ts > 15 * 60
        return NoopCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("GLUCOSE").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(unit.format(r.mgdl)).font(StrandFont.number(30, weight: .semibold)).foregroundStyle(tint(r.mgdl))
                    Text(r.trend?.arrow ?? "").font(StrandFont.number(18, weight: .semibold)).foregroundStyle(tint(r.mgdl))
                    Spacer(minLength: 0)
                }
                MiniTrace(values: trace.map(\.mgdl), color: tint(r.mgdl)).frame(height: 22)
                Text(stale ? "\((now - r.ts) / 60) min ago — check the G7" : "\(max(0, (now - r.ts) / 60)) min ago")
                    .font(StrandFont.caption)
                    .foregroundStyle(stale ? StrandPalette.statusWarning : StrandPalette.textTertiary)
            }
            .opacity(stale ? 0.7 : 1)
        }
    }

    private var pictureTile: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("WHOLE PICTURE").strandOverline()
                if let o = hub.analysis.wholePicture?.overall {
                    Text("\(Int(o.rounded()))").font(StrandFont.number(30, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                } else {
                    Text("—").font(StrandFont.number(30, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
                }
                let flags = hub.analysis.wholePicture?.flags.filter { $0.severity != .info } ?? []
                Text(flags.isEmpty ? "Nothing off baseline" : "\(flags.count) to look at")
                    .font(StrandFont.caption)
                    .foregroundStyle(flags.contains { $0.severity == .act } ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct MiniTrace: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count >= 2 else { return }
                let lo = 54.0, hi = 250.0
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = g.size.height * (1 - CGFloat((min(max(v, lo), hi) - lo) / (hi - lo)))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
#endif
