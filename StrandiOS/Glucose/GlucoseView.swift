#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandGlucose

/// NOOP Pro's glucose screen: live value, today's curve, the consensus CGM metrics, the 14-day
/// ambulatory profile, detected rises, and glucose joined to each night and workout the strap scored.
struct GlucoseView: View {
    @ObservedObject private var hub = GlucoseHub.shared
    @EnvironmentObject private var repo: Repository
    @AppStorage(GlucosePrefs.unit) private var unitRaw = GlucoseUnit.mmol.rawValue
    @AppStorage(GlucosePrefs.profile) private var profileRaw = GlucoseProfile.generalHealth.rawValue

    private var unit: GlucoseUnit { GlucoseUnit(rawValue: unitRaw) ?? .mmol }
    private var profile: GlucoseProfile { GlucoseProfile(rawValue: profileRaw) ?? .generalHealth }
    private func v(_ mgdl: Double) -> Double { unit == .mmol ? mgdl / mgdlPerMmol : mgdl }

    var body: some View {
        ScreenScaffold(title: "Glucose", subtitle: "Dexcom G7, joined to everything your strap sees",
                       onRefresh: refresh) {
            liveCard
            todayChart
            metricsGrid
            agpChart
            risesCard
            nightsCard
            workoutsCard
            trendCard
            footnote
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { GlucoseSettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        hub.reload()
        await hub.pollShare(force: true)
        await hub.analyse(repo: repo)
    }

    // MARK: Live

    private func color(_ mgdl: Double) -> Color {
        if mgdl < 70 { return StrandPalette.statusCritical }
        if mgdl > profile.targetHigh { return StrandPalette.statusWarning }
        return StrandPalette.statusPositive
    }

    private var liveCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("NOW").strandOverline()
                if let r = hub.latest {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(unit.format(r.mgdl))
                            .font(StrandFont.number(56, weight: .semibold))
                            .foregroundStyle(color(r.mgdl))
                        Text(r.trend?.arrow ?? "")
                            .font(StrandFont.number(34, weight: .medium))
                            .foregroundStyle(color(r.mgdl))
                        Text(unit.label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Text(ageText(hub.latestAge ?? 0)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        SourceBadge(LocalizedStringKey(sourceLabel(r.source)))
                        if let rate = r.ratePerMinute {
                            Text(String(format: "%+.1f %@/min", unit == .mmol ? rate / mgdlPerMmol : rate, unit.label))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                } else {
                    Text("No readings yet").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text("Keep the Dexcom G7 app installed and running on this iPhone. NOOP Pro picks up the sensor's next 5-minute check-in — or add Dexcom Share in settings as a backup.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                Divider().overlay(StrandPalette.hairline)
                Label(hub.bleState.label, systemImage: "antenna.radiowaves.left.and.right")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Label("Share: \(hub.shareStatus)", systemImage: "icloud")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func ageText(_ s: Int) -> String {
        if s < 90 { return "Just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h \((s % 3600) / 60) min ago — stale"
    }

    private func sourceLabel(_ s: GlucoseSource) -> String {
        switch s {
        case .g7Live: return "G7 Bluetooth"
        case .g7Backfill: return "G7 backfill"
        case .dexcomShare: return "Dexcom Share"
        case .appleHealth: return "Apple Health"
        case .manual: return "Finger-prick"
        }
    }

    // MARK: Charts

    private var todayChart: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last 24 hours", trailing: unit.label)
                if hub.recent.count < 2 {
                    Text("Not enough data yet.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Chart {
                        RectangleMark(xStart: .value("s", hub.recent.first!.date), xEnd: .value("e", hub.recent.last!.date),
                                      yStart: .value("lo", v(profile.targetLow)), yEnd: .value("hi", v(profile.targetHigh)))
                            .foregroundStyle(StrandPalette.statusPositive.opacity(0.10))
                        ForEach(hub.recent, id: \.ts) { r in
                            LineMark(x: .value("Time", r.date), y: .value("Glucose", v(r.mgdl)))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(StrandPalette.accent)
                        }
                        ForEach(hub.analysis.todayExcursions) { e in
                            PointMark(x: .value("Peak", Date(timeIntervalSince1970: TimeInterval(e.peakTs))), y: .value("v", v(e.peak)))
                                .foregroundStyle(StrandPalette.statusWarning)
                                .symbolSize(40)
                        }
                    }
                    .chartYScale(domain: unit == .mmol ? 2...16 : 40...290)
                    .frame(height: NoopMetrics.chartHeight)
                }
            }
        }
    }

    private var metricsGrid: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Glucose metrics", overline: "LAST 24 H · 14 DAYS")
            if let d = hub.analysis.day {
                let f = hub.analysis.fortnight
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NoopMetrics.gap) {
                    StatTile(label: "Time in target", value: pct(d.timeInTarget(profile)),
                             caption: f.map { "14 d: " + pct($0.timeInTarget(profile)) }, accent: StrandPalette.statusPositive)
                    StatTile(label: "Average", value: unit.format(d.mean), caption: f.map { "14 d: " + unit.format($0.mean) })
                    StatTile(label: "Variability (CV)", value: pct(d.cv),
                             caption: d.cv <= 36 ? "Stable (≤36%)" : "Unstable (>36%)",
                             accent: d.cv <= 36 ? StrandPalette.textPrimary : StrandPalette.statusWarning)
                    StatTile(label: "GMI (est. HbA1c)", value: f.map { String(format: "%.1f%%", $0.gmi) } ?? String(format: "%.1f%%", d.gmi),
                             caption: f.map { String(format: "%.0f mmol/mol", ($0.gmi - 2.15) * 10.929) })
                    StatTile(label: "Time below 3.9", value: pct(d.low + d.veryLow),
                             caption: "Below 3.0: " + pct(d.veryLow),
                             accent: d.low + d.veryLow > 4 ? StrandPalette.statusCritical : StrandPalette.textPrimary)
                    StatTile(label: "Glycemia Risk Index", value: String(format: "%.0f", d.gri), caption: "0 best · 100 worst")
                    StatTile(label: "MAGE (swing size)", value: d.mage.map { unit.format($0) } ?? "—", caption: "Mean excursion")
                    StatTile(label: "Low / high risk", value: String(format: "%.1f / %.1f", d.lbgi, d.hbgi), caption: "LBGI / HBGI")
                }
                if let dawn = hub.analysis.dawnRise {
                    Text("Dawn rise this morning: \(unit.format(dawn)) \(unit.label) above the overnight low.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            } else {
                NoopCard { Text("Metrics appear after a few hours of readings.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary) }
            }
        }
    }

    private func pct(_ x: Double) -> String { String(format: "%.0f%%", x) }

    private var agpChart: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Your typical day", overline: "14-DAY PROFILE", trailing: "median · 25–75% · 5–95%")
                if hub.analysis.agp.count < 6 {
                    Text("Builds up over your first few days.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Chart {
                        ForEach(hub.analysis.agp, id: \.hour) { h in
                            AreaMark(x: .value("Hour", h.hour), yStart: .value("p5", v(h.p5)), yEnd: .value("p95", v(h.p95)))
                                .foregroundStyle(StrandPalette.accent.opacity(0.12))
                                .interpolationMethod(.monotone)
                        }
                        ForEach(hub.analysis.agp, id: \.hour) { h in
                            AreaMark(x: .value("Hour", h.hour), yStart: .value("p25", v(h.p25)), yEnd: .value("p75", v(h.p75)))
                                .foregroundStyle(StrandPalette.accent.opacity(0.28))
                                .interpolationMethod(.monotone)
                        }
                        ForEach(hub.analysis.agp, id: \.hour) { h in
                            LineMark(x: .value("Hour", h.hour), y: .value("Median", v(h.p50)))
                                .foregroundStyle(StrandPalette.accent)
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartXScale(domain: 0...23)
                    .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
                    .frame(height: NoopMetrics.chartHeight)
                }
            }
        }
    }

    // MARK: Events

    private func time(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .omitted, time: .shortened)
    }

    private func dayTime(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var risesCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Today's rises", overline: "MEALS & SPIKES")
                if hub.analysis.todayExcursions.isEmpty {
                    Text("No rises over 1.7 mmol/L so far today.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(hub.analysis.todayExcursions) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(time(e.startTs)) · +\(unit.format(e.rise)) to \(unit.format(e.peak))")
                                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            Text("Peak after \(Int(e.minutesToPeak)) min · " + (e.minutesToRecover.map { "back to baseline in \(Int($0)) min" } ?? "not back to baseline yet"))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        Text(String(format: "%.0f", e.responseScore))
                            .font(StrandFont.number(22, weight: .semibold))
                            .foregroundStyle(e.responseScore >= 70 ? StrandPalette.statusPositive : (e.responseScore >= 40 ? StrandPalette.statusWarning : StrandPalette.statusCritical))
                    }
                }
                if !hub.analysis.fortnightExcursions.isEmpty {
                    let ex = hub.analysis.fortnightExcursions
                    let avgRise = ex.map(\.rise).reduce(0, +) / Double(ex.count)
                    let avgScore = ex.map(\.responseScore).reduce(0, +) / Double(ex.count)
                    Text("14 days: \(ex.count) rises, average +\(unit.format(avgRise)) \(unit.label), response score \(Int(avgScore)).")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var nightsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Glucose while you slept", overline: "SLEEP × GLUCOSE")
                if hub.analysis.nights.isEmpty {
                    Text("Shows once a night's sleep and glucose overlap.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(hub.analysis.nights.prefix(7), id: \.night.startTs) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(Date(timeIntervalSince1970: TimeInterval(n.night.endTs)).formatted(.dateTime.weekday(.wide).day().month()))
                                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text("avg \(unit.format(n.summary.mean)) · CV \(Int(n.summary.cv))%")
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                        }
                        let bits: [String] = [
                            n.bedtimeGlucose.map { "bed \(unit.format($0))" },
                            n.lows.isEmpty ? nil : "\(n.lows.count) low\(n.lows.count == 1 ? "" : "s")",
                            n.lastRiseToSleepMinutes.map { "last rise \(Int($0)) min before sleep" },
                            n.night.restingHr.map { "RHR \($0)" },
                            n.night.avgHrv.map { String(format: "HRV %.0f", $0) },
                        ].compactMap { $0 }
                        Text(bits.joined(separator: " · ")).font(StrandFont.caption)
                            .foregroundStyle(n.lows.isEmpty ? StrandPalette.textTertiary : StrandPalette.statusCritical)
                    }
                }
            }
        }
    }

    private var workoutsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Glucose in training", overline: "WORKOUTS × GLUCOSE")
                if hub.analysis.workouts.isEmpty {
                    Text("Shows once a workout overlaps your readings.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(hub.analysis.workouts.prefix(8), id: \.workout.startTs) { w in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(w.workout.sport.capitalized) · \(dayTime(w.workout.startTs))")
                                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            Text([w.start.map { "start \(unit.format($0))" }, w.end.map { "end \(unit.format($0))" },
                                  w.minAfter.map { "lowest 3 h after \(unit.format($0))" }].compactMap { $0 }.joined(separator: " · "))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        if let d = w.delta {
                            Text((d >= 0 ? "+" : "−") + unit.format(abs(d)))
                                .font(StrandFont.number(20, weight: .semibold))
                                .foregroundStyle(d < -30 ? StrandPalette.statusWarning : StrandPalette.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private var trendCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Time in target by day", overline: "LAST 30 DAYS")
                if hub.analysis.dailyTIT.count < 2 {
                    Text("Fills in day by day.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Chart(hub.analysis.dailyTIT) { d in
                        BarMark(x: .value("Day", String(d.day.suffix(5))), y: .value("TIT", d.tit))
                            .foregroundStyle(d.tit >= 70 ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis(.hidden)
                    .frame(height: 140)
                }
            }
        }
    }

    private var footnote: some View {
        Text("NOOP Pro reads glucose for analysis only. It is not a medical device: keep the Dexcom app as your source for alerts and any treatment decision.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            .padding(.bottom, NoopMetrics.tabBarClearance)
    }
}
#endif
