import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// NOOP Pro Body Age v2 on the Health tab: the weekly Body Age, what every one of its eleven inputs adds or
/// takes away, the pace of aging and the weekly trend. Everything here is READ BACK from what
/// `BodyAgeService` stored, never recomputed, so the figure, its breakdown and the trend always agree.
struct BodyAgeSection: View {
    @ObservedObject private var service = BodyAgeService.shared
    @State private var showVO2Entry = false

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Body Age", overline: "Weekly",
                          trailing: service.snapshot.map { String(localized: "Vitality \(Int($0.vitality.rounded()))") })
            if let s = service.snapshot {
                card(s)
            } else if service.loaded {
                ComingSoon(what: "A few more days of wearing the strap and your Body Age appears here.", symbol: "figure.stand")
            } else {
                ComingSoon(what: "Working out your Body Age…", symbol: "figure.stand")
            }
        }
        .task {
            await service.reloadStored()
            service.schedule()
        }
        .sheet(isPresented: $showVO2Entry) {
            VO2EntrySheet(current: service.measuredVO2?.value) { service.setMeasuredVO2($0) }
        }
    }

    // MARK: Card

    private func card(_ s: BodyAgeService.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            hero(s)
            pace(s)
            if s.history.count >= 2 { trend(s) }
            Divider().overlay(StrandPalette.hairline)
            Text("What makes it up").strandOverline()
            ForEach(s.factors.sorted(by: Self.order)) { f in factorRow(f) }
            sumLine(s)
            Text("A wellness estimate from your habits over the last week, compared with the typical person of your age. Not a clinical or biological age.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(NoopMetrics.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { FrostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: NoopMetrics.cardRadius) }
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }

    /// Factors with data first (largest effect first), then the ones without data.
    private static func order(_ a: BodyAgeService.Factor, _ b: BodyAgeService.Factor) -> Bool {
        switch (a.years, b.years) {
        case let (x?, y?): return abs(x) > abs(y)
        case (_?, nil): return true
        case (nil, _?): return false
        default: return (VitalityEngine.factorKeys.firstIndex(of: a.key) ?? 0) < (VitalityEngine.factorKeys.firstIndex(of: b.key) ?? 0)
        }
    }

    private func hero(_ s: BodyAgeService.Snapshot) -> some View {
        let delta = s.bodyAge - s.chronoAge
        return HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space4) {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("Body Age").strandOverline()
                Text(String(format: "%.1f", s.bodyAge))
                    .font(StrandFont.number(40))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: NoopMetrics.space1) {
                Text(deltaLine(delta))
                    .font(StrandFont.headline)
                    .foregroundStyle(delta <= -0.05 ? StrandPalette.statusPositive
                                     : (delta >= 0.05 ? StrandPalette.statusWarning : StrandPalette.textSecondary))
                Text(String(format: String(localized: "Your age %.1f"), s.chronoAge))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func deltaLine(_ delta: Double) -> String {
        let y = abs(delta)
        if y < 0.05 { return String(localized: "Right at your age") }
        return delta < 0
            ? String(format: String(localized: "%.1f yrs younger"), y)
            : String(format: String(localized: "%.1f yrs older"), y)
    }

    // MARK: Pace of aging

    @ViewBuilder private func pace(_ s: BodyAgeService.Snapshot) -> some View {
        if let p = s.pace {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Text("Pace of aging").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text(String(format: "%.2f×", p.pace))
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(paceColor(p))
                }
                PaceBar(pace: p.pace, tint: paceColor(p))
                    .frame(height: 8)
                Text("\(paceWords(p)) · \(confidenceWords(p)), from \(p.weeks) weeks")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        } else {
            Text("Pace of aging appears after 6 weekly readings across 5 weeks (\(s.history.count) so far).")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func paceColor(_ p: PaceOfAging.Result) -> Color {
        switch p.band {
        case .slower: return StrandPalette.statusPositive
        case .normal: return StrandPalette.textPrimary
        case .faster: return StrandPalette.statusWarning
        }
    }

    private func paceWords(_ p: PaceOfAging.Result) -> String {
        switch p.band {
        case .slower: return String(localized: "Ageing slower than the calendar")
        case .normal: return String(localized: "Ageing at the calendar's pace")
        case .faster: return String(localized: "Ageing faster than the calendar")
        }
    }

    private func confidenceWords(_ p: PaceOfAging.Result) -> String {
        switch p.confidence {
        case .early: return String(localized: "early estimate")
        case .building: return String(localized: "building")
        case .solid: return String(localized: "solid")
        }
    }

    // MARK: Trend

    private struct TrendPoint: Identifiable {
        let date: Date
        let body: Double
        let real: Double
        var id: Date { date }
    }

    private func trend(_ s: BodyAgeService.Snapshot) -> some View {
        let pts: [TrendPoint] = s.history.compactMap { h in
            guard let d = BodyAgeService.date(h.day) else { return nil }
            return TrendPoint(date: d, body: h.bodyAge, real: h.chronoAge)
        }
        let all = pts.flatMap { [$0.body, $0.real] }
        let lo = floor((all.min() ?? 0) - 1), hi = ceil((all.max() ?? 1) + 1)
        return Chart {
            ForEach(pts) { p in
                LineMark(x: .value("Week", p.date), y: .value("Years", p.real), series: .value("Line", "Real age"))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            ForEach(pts) { p in
                LineMark(x: .value("Week", p.date), y: .value("Years", p.body), series: .value("Line", "Body Age"))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("Week", p.date), y: .value("Years", p.body))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .symbolSize(18)
            }
        }
        .chartYScale(domain: lo...max(hi, lo + 1))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
        .frame(height: 120)
        .accessibilityLabel("Body Age by week, with your real age as a dashed line")
    }

    // MARK: Factors

    @ViewBuilder private func factorRow(_ f: BodyAgeService.Factor) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(f.label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(f.years == nil ? Self.needs(f.key) : Self.valueText(f))
                    .font(StrandFont.caption)
                    .foregroundStyle(f.years == nil ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(f.years.map(Self.yearsText) ?? String(localized: "No data"))
                .font(StrandFont.captionNumber)
                .foregroundStyle(Self.yearsColor(f.years))
        }
        .padding(.vertical, 2)
        if f.key == "vo2max" {
            Button { showVO2Entry = true } label: { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Enter a measured VO₂ max")
        } else {
            row
        }
    }

    private func sumLine(_ s: BodyAgeService.Snapshot) -> some View {
        let sum = s.factors.compactMap(\.years).reduce(0, +)
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(format: String(localized: "Together: %@ on your age of %.1f"), Self.yearsText(sum), s.chronoAge))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            if abs(s.clampYears) >= 0.05 {
                Text("Body Age is kept within 25 years of your age, which trims \(Self.yearsText(-s.clampYears)) here.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    static func yearsText(_ y: Double) -> String {
        if abs(y) < 0.05 { return "0.0 yrs" }
        return String(format: "%@%.1f yrs", y < 0 ? "−" : "+", abs(y))
    }

    static func yearsColor(_ y: Double?) -> Color {
        guard let y else { return StrandPalette.textTertiary }
        if y <= -0.05 { return StrandPalette.statusPositive }
        if y >= 0.05 { return StrandPalette.statusWarning }
        return StrandPalette.textSecondary
    }

    static func valueText(_ f: BodyAgeService.Factor) -> String {
        guard let v = f.value else { return "" }
        switch f.key {
        case "rhr": return String(format: String(localized: "%.0f bpm (asleep), neutral at 60"), v)
        case "hrv": return String(format: String(localized: "%.0f ms, against the typical value for your age"), v)
        case "vo2max": return String(format: String(localized: "%.1f ml/kg/min against your age's median · tap to update"), v)
        case "sleep": return String(format: String(localized: "%.1f h a night, best at 7–8 h"), v)
        case "consistency": return String(format: String(localized: "%.0f%% steady night to night"), v)
        case "steps": return String(format: String(localized: "%@ a day, neutral at 7,000"),
                                    v.formatted(.number.precision(.fractionLength(0))))
        case "zonesLow": return String(format: String(localized: "%.0f min this week, neutral at 92"), v)
        case "zonesHigh": return String(format: String(localized: "%.0f min this week, neutral at 10"), v)
        case "strength": return String(format: String(localized: "%.0f min this week, neutral at 45"), v)
        case "leanMass": return String(format: String(localized: "%.0f%% lean (body fat %.0f%%)"), v, 100 - v)
        case "glucose": return String(format: String(localized: "GMI %.1f%%, only above 5.7%% adds years"), v)
        default: return String(format: "%.1f", v)
        }
    }

    static func needs(_ key: String) -> String {
        switch key {
        case "rhr", "hrv": return String(localized: "Needs nights with the strap on.")
        case "vo2max": return String(localized: "Tap to enter a measured VO₂ max (lab or watch test), or add your waist in Profile.")
        case "sleep": return String(localized: "Needs nights with the strap on.")
        case "consistency": return String(localized: "Needs 3 nights of sleep this week.")
        case "steps": return String(localized: "Needs 3 days of steps: phone steps or the calibrated WHOOP 4.0 estimate.")
        case "zonesLow", "zonesHigh": return String(localized: "Needs 4 days this week with 12+ hours of heart rate.")
        case "strength": return String(localized: "Counts once the week has 4 worn days or a logged strength session.")
        case "leanMass": return String(localized: "Needs a body-fat reading from the last 90 days.")
        case "glucose": return String(localized: "Needs 10 days of CGM data.")
        default: return String(localized: "No data yet.")
        }
    }
}

/// The pace dial as a bar from −1× to 3×, with a mark at 1× (the calendar's pace).
private struct PaceBar: View {
    let pace: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (v: Double) -> CGFloat in CGFloat((min(max(v, -1), 3) + 1) / 4) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                Rectangle().fill(StrandPalette.textTertiary).frame(width: 1.5).offset(x: x(1) - 0.75)
                Circle().fill(tint).frame(width: geo.size.height + 4, height: geo.size.height + 4)
                    .offset(x: x(pace) - (geo.size.height + 4) / 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Enter (or clear) a measured VO₂ max: a lab test, or a watch's running/cycling estimate.
private struct VO2EntrySheet: View {
    let current: Double?
    let onSave: (Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. 52.5", text: $text)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("VO₂ max (ml/kg/min)")
                } footer: {
                    Text("Use a measured value: a lab test, or a sports watch's estimate from running or cycling. It counts for a year from today. Leave empty and save to remove it.")
                }
            }
            .navigationTitle("Measured VO₂ max")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let v = Double(text.replacingOccurrences(of: ",", with: "."))
                        onSave(v)
                        dismiss()
                    }
                    .disabled(!(text.isEmpty || isValid))
                }
            }
            .onAppear { if let current { text = String(format: "%.1f", current) } }
        }
    }

    private var isValid: Bool {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")) else { return false }
        return v >= 15 && v <= 95
    }
}
