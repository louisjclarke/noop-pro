#if os(iOS)
import SwiftUI
import StrandDesign
import StrandGlucose

/// The whole-body read-out: recovery, sleep, load, metabolic (glucose) and nervous-system domains on one
/// scale, what's off baseline today, and the glucose → body relationships found in your own history.
struct WholePictureView: View {
    @ObservedObject private var hub = GlucoseHub.shared
    @EnvironmentObject private var repo: Repository

    var body: some View {
        ScreenScaffold(title: "Whole Picture", subtitle: "Every signal, one read-out", onRefresh: refresh) {
            overallCard
            domainsCard
            flagsCard
            findingsCard
            NavigationLink { GlucoseView() } label: {
                NoopCard {
                    HStack {
                        Label("Open Glucose", systemImage: "drop.fill").font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        if let r = hub.latest {
                            Text("\(hub.unit.format(r.mgdl)) \(r.trend?.arrow ?? "")")
                                .font(StrandFont.number(20, weight: .semibold)).foregroundStyle(StrandPalette.accent)
                        }
                        Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            Text("Scores compare you with your own last 30 days. They are estimates from consumer sensors, not a diagnosis.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .padding(.bottom, NoopMetrics.tabBarClearance)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        hub.reload()
        await hub.analyse(repo: repo)
    }

    private func tone(_ s: Double) -> Color {
        s >= 67 ? StrandPalette.statusPositive : (s >= 34 ? StrandPalette.statusWarning : StrandPalette.statusCritical)
    }

    private var overallCard: some View {
        NoopCard {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(StrandPalette.hairline, lineWidth: 10)
                    if let o = hub.analysis.wholePicture?.overall {
                        Circle().trim(from: 0, to: o / 100)
                            .stroke(tone(o), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(o.rounded()))").font(StrandFont.number(34, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                    } else {
                        Text("—").font(StrandFont.number(34, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 6) {
                    Text("TODAY").strandOverline()
                    Text(headline).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(subline).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var headline: String {
        guard let o = hub.analysis.wholePicture?.overall else { return "Gathering data" }
        switch o {
        case 80...: return "Primed — a day to push"
        case 60..<80: return "Solid — train as planned"
        case 40..<60: return "Mixed — keep intensity in check"
        default: return "Run down — prioritise recovery"
        }
    }

    private var subline: String {
        let wp = hub.analysis.wholePicture
        let acts = wp?.flags.filter { $0.severity == .act }.count ?? 0
        let watches = wp?.flags.filter { $0.severity == .watch }.count ?? 0
        if acts + watches == 0 { return "Nothing off your baseline." }
        return "\(acts + watches) thing\(acts + watches == 1 ? "" : "s") to look at below."
    }

    private var domainsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Domains")
                ForEach(hub.analysis.wholePicture?.domains ?? []) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(d.name).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text("\(Int(d.score.rounded()))").font(StrandFont.bodyNumber).foregroundStyle(tone(d.score))
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(StrandPalette.surfaceInset)
                                Capsule().fill(tone(d.score)).frame(width: g.size.width * max(0.02, min(1, d.score / 100)))
                            }
                        }
                        .frame(height: 6)
                        Text(d.headline).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                if (hub.analysis.wholePicture?.domains ?? []).isEmpty {
                    Text("Sync your strap to fill this in.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var flagsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Off baseline today")
                let flags = hub.analysis.wholePicture?.flags ?? []
                if flags.isEmpty {
                    Text("Everything's within your normal range.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(flags) { f in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: f.severity == .act ? "exclamationmark.triangle.fill" : (f.severity == .watch ? "eye.fill" : "info.circle.fill"))
                            .foregroundStyle(f.severity == .act ? StrandPalette.statusCritical : (f.severity == .watch ? StrandPalette.statusWarning : StrandPalette.textTertiary))
                        Text(f.text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var findingsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("What glucose does to your body", overline: "LEARNED FROM YOUR DATA")
                if hub.analysis.findings.isEmpty {
                    Text("Needs about 10 days of glucose alongside your strap before patterns can be trusted.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(hub.analysis.findings.prefix(8)) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.sentence).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("\(f.confidence) · ρ = \(String(format: "%.2f", f.rho))")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }
}
#endif
