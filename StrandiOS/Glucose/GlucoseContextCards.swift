#if os(iOS)
import SwiftUI
import StrandDesign
import StrandGlucose

/// Sleep screen: last night's glucose and how it shaped HRV, resting HR and sleep.
struct GlucoseSleepCard: View {
    @ObservedObject private var hub = GlucoseHub.shared

    var body: some View {
        if let n = hub.analysis.nights.first {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    HStack {
                        Text("GLUCOSE LAST NIGHT").strandOverline()
                        Spacer()
                        NavigationLink { GlucoseView() } label: {
                            Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    HStack(spacing: 18) {
                        stat("Average", GlucoseUnit.mmol.format(n.summary.mean))
                        stat("Lowest", GlucoseUnit.mmol.format(n.summary.min),
                             tint: n.summary.min < 70 ? StrandPalette.statusCritical : StrandPalette.textPrimary)
                        stat("Bedtime", n.bedtimeGlucose.map { GlucoseUnit.mmol.format($0) } ?? "—")
                        stat("Variability", "\(Int(n.summary.cv))%")
                    }
                    let reasons = hub.analysis.nightExplanations[n.night.startTs]?.reasons ?? []
                    if reasons.isEmpty {
                        Text("Glucose was steady overnight and isn't a factor in tonight's numbers.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        ForEach(reasons, id: \.self) { r in
                            Text("• " + r).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(StrandFont.number(20, weight: .semibold)).foregroundStyle(tint)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

/// Stress screen: today's high-stress hours with what glucose was doing in each.
struct GlucoseStressCard: View {
    @ObservedObject private var hub = GlucoseHub.shared

    var body: some View {
        if let summary = hub.analysis.stressSummary {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    Text("GLUCOSE BEHIND TODAY'S STRESS").strandOverline()
                    Text(summary).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    ForEach(hub.analysis.stressContexts) { c in
                        HStack(alignment: .top, spacing: 10) {
                            Text(Date(timeIntervalSince1970: TimeInterval(c.startTs)).formatted(date: .omitted, time: .shortened))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                                .frame(width: 58, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(GlucoseUnit.mmol.format(c.minGlucose))–\(GlucoseUnit.mmol.format(c.maxGlucose)) mmol/L")
                                    .font(StrandFont.caption).foregroundStyle(color(c.cause))
                                Text(c.explanation).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func color(_ c: GlucoseCause) -> Color {
        switch c {
        case .low, .fallingFast: return StrandPalette.statusCritical
        case .rising, .high: return StrandPalette.statusWarning
        case .steady: return StrandPalette.textPrimary
        }
    }
}
#endif
