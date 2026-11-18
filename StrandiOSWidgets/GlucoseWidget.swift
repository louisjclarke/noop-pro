import StrandDesign
import SwiftUI
import WidgetKit

/// NOOP Pro: glucose on the Home Screen and Lock Screen. The app reloads this widget whenever a new
/// reading lands; the minutes-ago label counts up on its own, so a stalled feed is obvious.
struct GlucoseEntry: TimelineEntry {
    let date: Date
    let state: GlucoseWidgetState?
}

struct GlucoseProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlucoseEntry {
        GlucoseEntry(date: Date(), state: GlucoseWidgetState(mgdl: 104, rate: 0.3, ts: Date(), mmol: true,
                                                             targetLow: 70, targetHigh: 140,
                                                             trace: [96, 99, 104, 112, 118, 113, 106, 104],
                                                             timeInTarget: 92))
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseEntry) -> Void) {
        completion(GlucoseEntry(date: Date(), state: GlucoseWidgetState.load() ?? placeholder(in: context).state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseEntry>) -> Void) {
        let entry = GlucoseEntry(date: Date(), state: GlucoseWidgetState.load())
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

private struct GlucoseTraceShape: Shape {
    let values: [Double]
    let lo: Double, hi: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count >= 2 else { return p }
        for (i, v) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1)
            let f = (min(max(v, lo), hi) - lo) / (hi - lo)
            let y = rect.maxY - rect.height * CGFloat(f)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

struct GlucoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlucoseEntry

    private func tint(_ s: GlucoseWidgetState) -> Color {
        switch s.band {
        case -1: return StrandPalette.statusCritical
        case 1: return StrandPalette.statusWarning
        default: return StrandPalette.statusPositive
        }
    }

    private func stale(_ s: GlucoseWidgetState) -> Bool { entry.date.timeIntervalSince(s.ts) > 15 * 60 }

    var body: some View {
        if let s = entry.state {
            switch family {
            case .accessoryInline:
                Text("\(s.valueText) \(s.arrow)  ") + Text(s.ts, style: .relative)
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Text(s.valueText).font(.system(size: 20, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Text(s.arrow).font(.system(size: 12, weight: .semibold))
                }
                .opacity(stale(s) ? 0.5 : 1)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(s.valueText).font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text(s.arrow).font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 0)
                        Text(s.ts, style: .relative).font(.caption2).multilineTextAlignment(.trailing)
                    }
                    GlucoseTraceShape(values: s.trace, lo: 54, hi: 250).stroke(lineWidth: 1.5)
                        .frame(height: 16)
                }
                .opacity(stale(s) ? 0.5 : 1)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("GLUCOSE").font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        Text(s.ts, style: .relative).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(s.valueText).font(StrandFont.number(38, weight: .semibold)).foregroundStyle(tint(s))
                        Text(s.arrow).font(StrandFont.number(22, weight: .semibold)).foregroundStyle(tint(s))
                    }
                    Text(s.unitText).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    GlucoseTraceShape(values: s.trace, lo: 54, hi: 250)
                        .stroke(tint(s), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(maxHeight: .infinity)
                    if let t = s.timeInTarget {
                        Text("\(Int(t))% in target today").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .opacity(stale(s) ? 0.55 : 1)
            }
        } else {
            Text("Open NOOP Pro → Glucose to start").font(.caption).multilineTextAlignment(.center)
        }
    }
}

struct GlucoseWidget: Widget {
    static let kind = "NOOPProGlucoseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlucoseProvider()) { entry in
            GlucoseWidgetView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
                .widgetURL(URL(string: "noop://glucose"))
        }
        .configurationDisplayName("Glucose")
        .description("Your latest Dexcom G7 glucose, trend and the last 3 hours.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
