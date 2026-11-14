import Foundation

// Cross-signal analysis: glucose joined to what the strap measured. Inputs are plain structs so this
// package stays independent of WhoopStore; the app maps its own rows into them.

public struct FusionNight: Equatable, Sendable {
    public let startTs: Int
    public let endTs: Int
    public let efficiency: Double?      // 0–1 or 0–100, normalised on use
    public let restingHr: Int?
    public let avgHrv: Double?
    public let deepMin: Double?
    public let remMin: Double?
    public let disturbances: Int?

    public init(startTs: Int, endTs: Int, efficiency: Double?, restingHr: Int?, avgHrv: Double?,
                deepMin: Double? = nil, remMin: Double? = nil, disturbances: Int? = nil) {
        self.startTs = startTs; self.endTs = endTs; self.efficiency = efficiency; self.restingHr = restingHr
        self.avgHrv = avgHrv; self.deepMin = deepMin; self.remMin = remMin; self.disturbances = disturbances
    }

    public var efficiencyPct: Double? { efficiency.map { $0 <= 1.0 ? $0 * 100 : $0 } }
}

public struct FusionDay: Equatable, Sendable {
    public let day: String        // YYYY-MM-DD, local
    public let recovery: Double?  // 0–100
    public let strain: Double?    // 0–21
    public let hrv: Double?       // ms
    public let restingHr: Int?
    public let sleepMin: Double?
    public let skinTempDevC: Double?
    public let respRate: Double?
    public let spo2: Double?
    public let steps: Int?
    /// Sleep efficiency 0–100 (or 0–1, normalised on use), deep minutes and disturbances for the night
    /// ending this morning; mean daytime stress (0–3) for the day.
    public let sleepEfficiency: Double?
    public let deepMin: Double?
    public let disturbances: Int?
    public let dayStress: Double?

    public init(day: String, recovery: Double?, strain: Double?, hrv: Double?, restingHr: Int?, sleepMin: Double?,
                skinTempDevC: Double? = nil, respRate: Double? = nil, spo2: Double? = nil, steps: Int? = nil,
                sleepEfficiency: Double? = nil, deepMin: Double? = nil, disturbances: Int? = nil, dayStress: Double? = nil) {
        self.day = day; self.recovery = recovery; self.strain = strain; self.hrv = hrv; self.restingHr = restingHr
        self.sleepMin = sleepMin; self.skinTempDevC = skinTempDevC; self.respRate = respRate; self.spo2 = spo2
        self.steps = steps; self.sleepEfficiency = sleepEfficiency; self.deepMin = deepMin
        self.disturbances = disturbances; self.dayStress = dayStress
    }

    public var efficiencyPct: Double? { sleepEfficiency.map { $0 <= 1.0 ? $0 * 100 : $0 } }
}

public struct FusionWorkout: Equatable, Sendable {
    public let startTs: Int
    public let endTs: Int
    public let sport: String
    public let avgHr: Int?
    public let strain: Double?

    public init(startTs: Int, endTs: Int, sport: String, avgHr: Int?, strain: Double?) {
        self.startTs = startTs; self.endTs = endTs; self.sport = sport; self.avgHr = avgHr; self.strain = strain
    }
}

/// Glucose across one sleep.
public struct NightGlucose: Equatable, Sendable {
    public let night: FusionNight
    public let summary: GlucoseSummary
    public let bedtimeGlucose: Double?
    public let lows: [GlucoseLowEvent]
    /// Minutes from the peak of the last rise before bed to sleep onset. Short gaps (late eating) are a
    /// known drag on sleep heart rate and HRV.
    public let lastRiseToSleepMinutes: Double?
    public let lastRiseSize: Double?
}

/// Glucose across one workout.
public struct WorkoutGlucose: Equatable, Sendable {
    public let workout: FusionWorkout
    public let start: Double?
    public let end: Double?
    public let minDuring: Double?
    public let maxDuring: Double?
    /// Lowest value in the 3 hours after — exercise-delayed dips show up here.
    public let minAfter: Double?
    public var delta: Double? { (start != nil && end != nil) ? end! - start! : nil }
    public var ratePerHour: Double? {
        guard let d = delta else { return nil }
        let h = Double(workout.endTs - workout.startTs) / 3600
        return h > 0.1 ? d / h : nil
    }
}

/// One discovered relationship between a glucose feature and a strap outcome.
public struct FusionFinding: Equatable, Sendable, Identifiable {
    public var id: String { "\(feature)→\(outcome)" }
    public let feature: String
    public let outcome: String
    /// Spearman rank correlation.
    public let rho: Double
    public let n: Int
    /// Mean outcome when the feature is in its best vs worst third of days.
    public let bestThirdOutcome: Double
    public let worstThirdOutcome: Double
    public let sentence: String
    /// Rough two-sided p-value from the t approximation; shown as a confidence label, not a test.
    public let p: Double

    public var confidence: String {
        if n >= 30 && p < 0.01 { return "Strong" }
        if n >= 14 && p < 0.05 { return "Moderate" }
        return "Early signal"
    }
}

struct FusionLink {
    let feature: String
    let phrase: String
    let outcome: String
    let higherIsWorse: Bool
    let outcomeHigherIsBetter: Bool
    let x: (FusionDay) -> Double?
    let y: (FusionDay) -> Double?
}

public enum GlucoseFusion {
    public static func night(_ night: FusionNight, series: [GlucoseReading]) -> NightGlucose? {
        let s = GlucoseSeries.slice(series, from: night.startTs, to: night.endTs)
        guard let sum = GlucoseMetrics.summary(s, windowSeconds: night.endTs - night.startTs), sum.coverage >= 0.5 else { return nil }
        let pre = GlucoseSeries.slice(series, from: night.startTs - 6 * 3600, to: night.startTs)
        let last = GlucoseEvents.excursions(pre).last
        return NightGlucose(night: night, summary: sum,
                            bedtimeGlucose: GlucoseSeries.value(at: night.startTs, in: series),
                            lows: GlucoseEvents.lows(s),
                            lastRiseToSleepMinutes: last.map { Double(night.startTs - $0.peakTs) / 60 },
                            lastRiseSize: last?.rise)
    }

    public static func workout(_ w: FusionWorkout, series: [GlucoseReading]) -> WorkoutGlucose? {
        let during = GlucoseSeries.slice(series, from: w.startTs, to: w.endTs + 1)
        guard during.count >= 2 else { return nil }
        let after = GlucoseSeries.slice(series, from: w.endTs, to: w.endTs + 3 * 3600)
        return WorkoutGlucose(workout: w,
                              start: GlucoseSeries.value(at: w.startTs, in: series),
                              end: GlucoseSeries.value(at: w.endTs, in: series),
                              minDuring: during.map(\.mgdl).min(), maxDuring: during.map(\.mgdl).max(),
                              minAfter: after.map(\.mgdl).min())
    }

    /// Per-local-day glucose summaries keyed "YYYY-MM-DD".
    public static func dailySummaries(_ series: [GlucoseReading], calendar: Calendar = .current) -> [String: GlucoseSummary] {
        var byDay: [String: [GlucoseReading]] = [:]
        for r in series { byDay[dayKey(r.date, calendar), default: []].append(r) }
        var out: [String: GlucoseSummary] = [:]
        for (k, v) in byDay {
            if let s = GlucoseMetrics.summary(v, windowSeconds: 86_400), s.coverage >= 0.5 { out[k] = s }
        }
        return out
    }

    public static func dayKey(_ d: Date, _ cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func previousDay(_ key: String, _ cal: Calendar) -> String? {
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key), let p = cal.date(byAdding: .day, value: -1, to: d) else { return nil }
        return f.string(from: p)
    }

    /// Next local day key.
    static func nextDay(_ key: String, _ cal: Calendar) -> String? {
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key), let n = cal.date(byAdding: .day, value: 1, to: d) else { return nil }
        return f.string(from: n)
    }

    /// Every relationship NOOP Pro tests, in both directions — glucose shapes the body (HRV, RHR,
    /// recovery, sleep, stress) and the body shapes glucose (short sleep → worse next-day control, hard
    /// training → lower overnight glucose, high stress → higher glucose). Each pairing respects time
    /// order: the cause is measured before the effect. Findings need |ρ| ≥ 0.3 and n ≥ 10 days.
    public static func findings(series: [GlucoseReading], days: [FusionDay], nights: [FusionNight],
                                calendar: Calendar = .current) -> [FusionFinding] {
        let daily = dailySummaries(series, calendar: calendar)
        var nightByWakeDay: [String: NightGlucose] = [:]
        for n in nights {
            if let ng = night(n, series: series) {
                nightByWakeDay[dayKey(Date(timeIntervalSince1970: TimeInterval(n.endTs)), calendar)] = ng
            }
        }
        var spikesByDay: [String: Double] = [:]
        for e in GlucoseEvents.excursions(series) {
            spikesByDay[dayKey(Date(timeIntervalSince1970: TimeInterval(e.startTs)), calendar), default: 0] += 1
        }
        for k in daily.keys where spikesByDay[k] == nil { spikesByDay[k] = 0 }
        let prev: (String) -> String? = { previousDay($0, calendar) }
        let next: (String) -> String? = { nextDay($0, calendar) }
        func above140(_ s: GlucoseSummary) -> Double { max(0, 100 - s.tight - s.low - s.veryLow) }

        var links: [FusionLink] = []
        // ── Glucose → body (feature measured the day before / during the night; outcome scored on wake day D)
        let gFeatures: [(String, String, (String) -> Double?, Bool)] = [
            ("Day-before glucose variability (CV)", "more variable glucose the day before", { d in prev(d).flatMap { daily[$0]?.cv } }, true),
            ("Day-before mean glucose", "higher average glucose the day before", { d in prev(d).flatMap { daily[$0]?.mean } }, true),
            ("Day-before time above 7.8", "more time above 7.8 mmol/L the day before", { d in prev(d).flatMap { daily[$0].map(above140) } }, true),
            ("Day-before spikes", "more glucose spikes the day before", { d in prev(d).flatMap { spikesByDay[$0] } }, true),
            ("Overnight glucose variability", "a less stable night-time glucose", { d in nightByWakeDay[d]?.summary.cv }, true),
            ("Overnight mean glucose", "higher overnight glucose", { d in nightByWakeDay[d]?.summary.mean }, true),
            ("Overnight lowest glucose", "a lower overnight minimum", { d in nightByWakeDay[d]?.summary.min }, false),
            ("Bedtime glucose", "higher glucose at bedtime", { d in nightByWakeDay[d]?.bedtimeGlucose }, true),
            ("Last rise → sleep gap", "a shorter gap between your last glucose rise and sleep", { d in nightByWakeDay[d]?.lastRiseToSleepMinutes }, false),
        ]
        let bOutcomes: [(String, (FusionDay) -> Double?, Bool)] = [
            ("recovery", { $0.recovery }, true),
            ("HRV", { $0.hrv }, true),
            ("resting heart rate", { $0.restingHr.map(Double.init) }, false),
            ("sleep duration", { $0.sleepMin }, true),
            ("sleep efficiency", { $0.efficiencyPct }, true),
            ("deep sleep", { $0.deepMin }, true),
            ("sleep disturbances", { $0.disturbances.map(Double.init) }, false),
            ("skin temperature", { $0.skinTempDevC }, false),
            ("breathing rate", { $0.respRate }, false),
        ]
        for f in gFeatures {
            for o in bOutcomes {
                links.append(FusionLink(feature: f.0, phrase: f.1, outcome: o.0, higherIsWorse: f.3, outcomeHigherIsBetter: o.2,
                                        x: { d in f.2(d.day) }, y: o.1))
            }
        }
        // Same-day stress ↔ glucose (concurrent; direction can't be separated, so phrased as "comes with").
        links.append(FusionLink(feature: "Daytime stress", phrase: "a more stressed day", outcome: "average glucose",
                                higherIsWorse: true, outcomeHigherIsBetter: false,
                                x: { $0.dayStress }, y: { daily[$0.day]?.mean }))
        links.append(FusionLink(feature: "Daytime stress", phrase: "a more stressed day", outcome: "glucose variability",
                                higherIsWorse: true, outcomeHigherIsBetter: false,
                                x: { $0.dayStress }, y: { daily[$0.day]?.cv }))

        // ── Body → glucose
        // Last night's sleep (scored on day D) → glucose control during day D.
        let sleepFeatures: [(String, String, (FusionDay) -> Double?, Bool)] = [
            ("Last night's sleep duration", "shorter sleep", { $0.sleepMin }, false),
            ("Last night's sleep efficiency", "less efficient sleep", { $0.efficiencyPct }, false),
            ("Morning recovery", "a lower recovery", { $0.recovery }, false),
            ("Morning HRV", "a lower HRV", { $0.hrv }, false),
        ]
        let gOutcomes: [(String, (FusionDay) -> Double?, Bool)] = [
            ("average glucose that day", { daily[$0.day]?.mean }, false),
            ("glucose variability that day", { daily[$0.day]?.cv }, false),
            ("time above 7.8 mmol/L that day", { daily[$0.day].map(above140) }, false),
            ("spike count that day", { spikesByDay[$0.day] }, false),
        ]
        for f in sleepFeatures {
            for o in gOutcomes {
                links.append(FusionLink(feature: f.0, phrase: f.1, outcome: o.0, higherIsWorse: f.3, outcomeHigherIsBetter: o.2,
                                        x: f.2, y: o.1))
            }
        }
        // Training on day D → glucose the following night (scored on wake day D+1).
        links.append(FusionLink(feature: "Day strain", phrase: "a harder training day", outcome: "lowest glucose that night",
                                higherIsWorse: true, outcomeHigherIsBetter: true,
                                x: { $0.strain }, y: { d in next(d.day).flatMap { nightByWakeDay[$0]?.summary.min } }))
        links.append(FusionLink(feature: "Day strain", phrase: "a harder training day", outcome: "average glucose next day",
                                higherIsWorse: true, outcomeHigherIsBetter: false,
                                x: { $0.strain }, y: { d in next(d.day).flatMap { daily[$0]?.mean } }))
        links.append(FusionLink(feature: "Daily steps", phrase: "fewer steps", outcome: "average glucose that day",
                                higherIsWorse: false, outcomeHigherIsBetter: false,
                                x: { $0.steps.map(Double.init) }, y: { daily[$0.day]?.mean }))

        var out: [FusionFinding] = []
        for l in links {
            var pairs: [(Double, Double)] = []
            for d in days { if let x = l.x(d), let y = l.y(d) { pairs.append((x, y)) } }
            guard pairs.count >= 10 else { continue }
            let rho = spearman(pairs)
            guard rho.isFinite, abs(rho) >= 0.3 else { continue }
            let sorted = pairs.sorted { $0.0 < $1.0 }
            let third = max(1, sorted.count / 3)
            let lowX = sorted.prefix(third).map(\.1).reduce(0, +) / Double(third)
            let highX = sorted.suffix(third).map(\.1).reduce(0, +) / Double(third)
            let best = l.higherIsWorse ? lowX : highX
            let worst = l.higherIsWorse ? highX : lowX
            let worseOutcome = l.outcomeHigherIsBetter ? worst < best : worst > best
            let verb = worseOutcome ? "comes with" : "surprisingly comes with"
            let dir = worst > best ? "higher" : "lower"
            let lead: String = l.phrase.prefix(1).uppercased() + String(l.phrase.dropFirst())
            let sentence: String = "\(lead) \(verb) \(dir) \(l.outcome) (\(fmt(worst)) vs \(fmt(best)), \(pairs.count) days)."
            out.append(FusionFinding(feature: l.feature, outcome: l.outcome, rho: rho, n: pairs.count,
                                     bestThirdOutcome: best, worstThirdOutcome: worst, sentence: sentence,
                                     p: pValue(rho: rho, n: pairs.count)))
        }
        return out.sorted { abs($0.rho) * log(Double($0.n)) > abs($1.rho) * log(Double($1.n)) }
    }

    static func fmt(_ x: Double) -> String { abs(x) >= 10 ? String(format: "%.0f", x) : String(format: "%.1f", x) }

    public static func spearman(_ pairs: [(Double, Double)]) -> Double {
        pearson(zip(rank(pairs.map(\.0)), rank(pairs.map(\.1))).map { ($0, $1) })
    }

    public static func pearson(_ p: [(Double, Double)]) -> Double {
        let n = Double(p.count)
        guard n >= 3 else { return .nan }
        let mx = p.map(\.0).reduce(0, +) / n, my = p.map(\.1).reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in p { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my) }
        guard sxx > 0, syy > 0 else { return .nan }
        return sxy / sqrt(sxx * syy)
    }

    static func rank(_ v: [Double]) -> [Double] {
        let idx = v.indices.sorted { v[$0] < v[$1] }
        var r = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < idx.count {
            var j = i
            while j + 1 < idx.count, v[idx[j + 1]] == v[idx[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[idx[k]] = avg }
            i = j + 1
        }
        return r
    }

    /// Two-sided p from t = r√((n−2)/(1−r²)) using a normal approximation for the t tail (fine for the
    /// coarse confidence label it feeds).
    static func pValue(rho: Double, n: Int) -> Double {
        guard n > 3, abs(rho) < 1 else { return 0 }
        let t = abs(rho) * sqrt(Double(n - 2) / (1 - rho * rho))
        return erfc(t / sqrt(2))
    }
}
