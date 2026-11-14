import Foundation

// How glucose explains what the strap measured — and how the strap explains glucose. The strap's own
// numbers (HRV, resting HR, stress, sleep) are never altered: they are measurements. What glucose adds
// is the *reason* behind a deviation, which is what makes a number actionable.
//
// Physiology used (well established, conservative thresholds):
//  • Hypoglycaemia triggers an adrenaline/counter-regulatory response: heart rate rises and HRV falls,
//    which a wearable reads as "stress" and, at night, as a raised resting HR, lower HRV and awakenings.
//  • Acute hyperglycaemia and large evening meals raise sleeping heart rate and lower HRV.
//  • Psychological stress (cortisol, adrenaline) raises glucose without a meal.
//  • Hard or long exercise lowers glucose for up to ~24 h, classically as a delayed overnight low.
//  • Short or fragmented sleep reduces next-day insulin sensitivity (higher, spikier glucose).
//  • Infection and inflammation raise fasting/overnight glucose alongside temperature and resting HR.

public enum GlucoseCause: String, Sendable, Equatable {
    case low, fallingFast, rising, high, steady

    public var label: String {
        switch self {
        case .low: return "low glucose"
        case .fallingFast: return "fast-falling glucose"
        case .rising: return "a glucose rise"
        case .high: return "high glucose"
        case .steady: return "steady glucose"
        }
    }
}

/// One high-stress hour with what glucose was doing at the time.
public struct StressGlucoseContext: Equatable, Sendable, Identifiable {
    public var id: Int { startTs }
    public let startTs: Int
    public let stressLevel: Double
    public let cause: GlucoseCause
    public let minGlucose: Double
    public let maxGlucose: Double

    /// Plain-English reading of the hour.
    public var explanation: String {
        switch cause {
        case .low: return "Glucose dipped low — the adrenaline response to a low raises heart rate and lowers HRV, which reads as stress."
        case .fallingFast: return "Glucose was falling fast — the body releases stress hormones to stop the drop."
        case .rising: return "Glucose was rising — digestion and the glucose rise lift heart rate, so part of this is a meal, not stress."
        case .high: return "Glucose was high — high glucose lowers HRV, adding to the stress reading."
        case .steady: return "Glucose was steady, so this looks like genuine stress (mental, physical or environmental)."
        }
    }
}

/// Why last night's recovery inputs moved, from glucose.
public struct NightExplanation: Equatable, Sendable {
    public let reasons: [String]
    /// True when glucose plausibly accounts for a worse-than-baseline night (HRV down / RHR up / restless).
    public let glucoseLikelyContributed: Bool
}

public enum GlucoseAttribution {
    /// Characterise glucose across [from, to).
    public static func cause(series: [GlucoseReading], from: Int, to: Int) -> (GlucoseCause, Double, Double)? {
        let s = GlucoseSeries.slice(series, from: from - 900, to: to)
        guard s.count >= 3, let lo = s.map(\.mgdl).min(), let hi = s.map(\.mgdl).max() else { return nil }
        let rates = GlucoseSeries.withRates(s).compactMap(\.ratePerMinute)
        let minRate = rates.min() ?? 0
        let first = s.first!.mgdl, peakAfter = hi
        if lo < 70 { return (.low, lo, hi) }
        if minRate <= -2 { return (.fallingFast, lo, hi) }
        if peakAfter - first >= 30 || (rates.max() ?? 0) >= 2 { return (.rising, lo, hi) }
        if hi > 180 { return (.high, lo, hi) }
        return (.steady, lo, hi)
    }

    /// Label every high-stress hour (level ≥ `highFloor`, the strap's own high band) with glucose.
    public static func stressHours(_ hours: [(startTs: Int, level: Double)], series: [GlucoseReading],
                                   highFloor: Double = 2.0, bucketSeconds: Int = 3600) -> [StressGlucoseContext] {
        hours.filter { $0.level >= highFloor }.compactMap { h in
            guard let r = cause(series: series, from: h.startTs, to: h.startTs + bucketSeconds) else { return nil }
            return StressGlucoseContext(startTs: h.startTs, stressLevel: h.level, cause: r.0, minGlucose: r.1, maxGlucose: r.2)
        }
    }

    /// Short summary across a day's high-stress hours, e.g. "2 of 3 high-stress hours line up with low
    /// or falling glucose".
    public static func stressSummary(_ ctx: [StressGlucoseContext]) -> String? {
        guard !ctx.isEmpty else { return nil }
        let glucoseDriven = ctx.filter { $0.cause == .low || $0.cause == .fallingFast }.count
        let meal = ctx.filter { $0.cause == .rising }.count
        let genuine = ctx.filter { $0.cause == .steady || $0.cause == .high }.count
        var parts: [String] = []
        if glucoseDriven > 0 { parts.append("\(glucoseDriven) with low or falling glucose") }
        if meal > 0 { parts.append("\(meal) during a glucose rise") }
        if genuine > 0 { parts.append("\(genuine) with steady glucose (genuine stress)") }
        return "\(ctx.count) high-stress hour\(ctx.count == 1 ? "" : "s") today: " + parts.joined(separator: ", ") + "."
    }

    /// Explain a night against the wearer's own baselines. `baselineHRV`/`baselineRHR` are medians of
    /// recent nights; `priorDayStrain` is the training load of the day before the night.
    public static func night(_ ng: NightGlucose, baselineHRV: Double?, baselineRHR: Double?,
                             overnightBaselineMean: Double?, priorDayStrain: Double?, typicalStrain: Double?) -> NightExplanation {
        var reasons: [String] = []
        let hrvDown = ng.night.avgHrv.flatMap { h in baselineHRV.map { h < $0 * 0.9 } } ?? false
        let rhrUp = ng.night.restingHr.flatMap { r in baselineRHR.map { Double(r) >= $0 + 3 } } ?? false
        let unit = GlucoseUnit.mmol
        if !ng.lows.isEmpty {
            let nadir = ng.lows.map(\.nadir).min() ?? 0
            let t = Date(timeIntervalSince1970: TimeInterval(ng.lows[0].startTs))
            reasons.append("Glucose went low overnight (\(unit.format(nadir)) mmol/L from \(t.formatted(date: .omitted, time: .shortened))) — lows wake the nervous system, raising heart rate and lowering HRV.")
            if let s = priorDayStrain, let t = typicalStrain, s > t * 1.25 {
                reasons.append("It followed a harder-than-usual training day, the classic setup for a delayed overnight low.")
            }
        }
        if let gap = ng.lastRiseToSleepMinutes, gap < 120, (ng.lastRiseSize ?? 0) >= 30 {
            reasons.append("Your last glucose rise peaked \(Int(gap)) min before sleep — late meals keep heart rate up into the night.")
        }
        if ng.summary.mean > 140 || (overnightBaselineMean.map { ng.summary.mean - $0 >= 15 } ?? false) {
            reasons.append("Overnight glucose ran high (avg \(unit.format(ng.summary.mean)) mmol/L) — raised glucose lowers HRV. If you're also warm or your heart rate is up, this can be an early sign of illness.")
        }
        if ng.summary.cv > 20 {
            reasons.append("Glucose was unstable overnight (CV \(Int(ng.summary.cv))%), which tends to fragment sleep.")
        }
        let contributed = !reasons.isEmpty && (hrvDown || rhrUp)
        if reasons.isEmpty && (hrvDown || rhrUp) {
            reasons.append("Glucose was stable overnight, so it doesn't explain the lower HRV / higher resting HR — look at alcohol, illness, training load or stress instead.")
        }
        return NightExplanation(reasons: reasons, glucoseLikelyContributed: contributed)
    }
}

/// Daily glucose metrics keyed by local day, in the units NOOP's metric store uses. These become
/// ordinary NOOP metrics: plotted in Explore, compared in Compare, and correlated against every other
/// metric automatically.
public enum GlucoseDailyMetrics {
    public static let keys: [String] = [
        "glucose_mean", "glucose_cv", "glucose_tight_pct", "glucose_tir_pct", "glucose_low_pct",
        "glucose_gmi", "glucose_spikes", "glucose_peak_rise", "glucose_night_mean", "glucose_night_min",
        "glucose_bedtime", "glucose_last_rise_gap",
    ]

    /// day → key → value. Values are in mmol/L for concentrations (the UK unit NOOP Pro defaults to).
    public static func compute(series: [GlucoseReading], nights: [FusionNight], calendar: Calendar = .current) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        let daily = GlucoseFusion.dailySummaries(series, calendar: calendar)
        for (day, s) in daily {
            var m: [String: Double] = [
                "glucose_mean": s.mean / mgdlPerMmol, "glucose_cv": s.cv,
                "glucose_tight_pct": s.tight, "glucose_tir_pct": s.inRange, "glucose_low_pct": s.low + s.veryLow,
            ]
            m["glucose_spikes"] = 0
            out[day] = m
        }
        for e in GlucoseEvents.excursions(series) {
            let k = GlucoseFusion.dayKey(Date(timeIntervalSince1970: TimeInterval(e.startTs)), calendar)
            guard out[k] != nil else { continue }
            out[k]!["glucose_spikes", default: 0] += 1
            out[k]!["glucose_peak_rise"] = max(out[k]!["glucose_peak_rise"] ?? 0, e.rise / mgdlPerMmol)
        }
        // 14-day rolling GMI, only where ≥ 10 of the 14 days have ≥ 50% coverage (consensus minimum ≈ 14 d / 70%).
        let sortedDays = daily.keys.sorted()
        for (i, day) in sortedDays.enumerated() {
            let window = sortedDays[max(0, i - 13)...i]
            guard window.count >= 10 else { continue }
            let means = window.compactMap { daily[$0]?.mean }
            let mean = means.reduce(0, +) / Double(means.count)
            out[day]?["glucose_gmi"] = 3.31 + 0.02392 * mean
        }
        for n in nights {
            guard let ng = GlucoseFusion.night(n, series: series) else { continue }
            let k = GlucoseFusion.dayKey(Date(timeIntervalSince1970: TimeInterval(n.endTs)), calendar)
            var m = out[k] ?? [:]
            m["glucose_night_mean"] = ng.summary.mean / mgdlPerMmol
            m["glucose_night_min"] = ng.summary.min / mgdlPerMmol
            if let b = ng.bedtimeGlucose { m["glucose_bedtime"] = b / mgdlPerMmol }
            if let g = ng.lastRiseToSleepMinutes { m["glucose_last_rise_gap"] = g }
            out[k] = m
        }
        return out
    }
}
