import Foundation

/// Target bands. Two profiles because NOOP Pro is a health app first: the "general health" profile
/// scores against the tight 70–140 mg/dL (3.9–7.8 mmol/L) range seen in people without diabetes, while
/// the diabetes profile uses the international consensus 70–180 (3.9–10.0) range. Both sets of numbers
/// are always computed; the profile only decides which one headlines.
public enum GlucoseProfile: String, Codable, CaseIterable, Sendable {
    case generalHealth = "general"
    case diabetes = "diabetes"

    public var targetLow: Double { 70 }
    public var targetHigh: Double { self == .generalHealth ? 140 : 180 }
    public var label: String { self == .generalHealth ? "General health (3.9–7.8)" : "Diabetes consensus (3.9–10.0)" }
}

/// Standard CGM summary statistics over a window. Definitions follow the International Consensus on
/// Time in Range (Battelino et al., Diabetes Care 2019), Kovatchev's risk indices, and Klonoff's GRI
/// (J Diabetes Sci Technol 2023).
public struct GlucoseSummary: Equatable, Sendable {
    public let count: Int
    /// Fraction of the window actually covered by readings (5-minute cadence assumed).
    public let coverage: Double
    public let mean: Double
    public let sd: Double
    /// Coefficient of variation, %. ≤36% is the consensus stability threshold.
    public let cv: Double
    public let min: Double
    public let max: Double
    public let median: Double
    /// Glucose Management Indicator, % (Bergenstal 2018): 3.31 + 0.02392 × mean mg/dL.
    public let gmi: Double
    /// Percent of readings in each band.
    public let veryLow: Double     // < 54
    public let low: Double         // 54–69
    public let inRange: Double     // 70–180
    public let tight: Double       // 70–140
    public let high: Double        // 181–250
    public let veryHigh: Double    // > 250
    public let jIndex: Double
    public let lbgi: Double
    public let hbgi: Double
    /// Glycemia Risk Index, 0–100 (lower is better).
    public let gri: Double
    /// Mean Amplitude of Glycemic Excursions, mg/dL.
    public let mage: Double?
    /// Continuous Overall Net Glycemic Action at 1 h, mg/dL.
    public let conga1: Double?
    /// Mean Of Daily Differences, mg/dL.
    public let modd: Double?
    /// Average Daily Risk Range.
    public let adrr: Double?

    public func timeInTarget(_ p: GlucoseProfile) -> Double { p == .generalHealth ? tight : inRange }
}

public enum GlucoseMetrics {
    public static func summary(_ series: [GlucoseReading], windowSeconds: Int? = nil) -> GlucoseSummary? {
        let v = series.map(\.mgdl)
        guard v.count >= 3 else { return nil }
        let n = Double(v.count)
        let mean = v.reduce(0, +) / n
        let sd = sqrt(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(1, n - 1))
        let sortedV = v.sorted()
        let median = sortedV.count % 2 == 1 ? sortedV[sortedV.count / 2]
            : (sortedV[sortedV.count / 2 - 1] + sortedV[sortedV.count / 2]) / 2
        func pct(_ f: (Double) -> Bool) -> Double { Double(v.filter(f).count) / n * 100 }
        let vLow = pct { $0 < 54 }
        let low = pct { $0 >= 54 && $0 < 70 }
        let high = pct { $0 > 180 && $0 <= 250 }
        let vHigh = pct { $0 > 250 }
        var lr = 0.0, hr = 0.0
        for g in v {
            let r = risk(g)
            if r < 0 { lr += 10 * r * r } else { hr += 10 * r * r }
        }
        let span = windowSeconds ?? ((series.last?.ts ?? 0) - (series.first?.ts ?? 0) + 300)
        let expected = max(1.0, Double(span) / 300)
        let gri = Swift.min(100, 3.0 * vLow + 2.4 * low + 1.6 * vHigh + 0.8 * high)
        return GlucoseSummary(
            count: v.count, coverage: Swift.min(1, n / expected),
            mean: mean, sd: sd, cv: mean > 0 ? sd / mean * 100 : 0,
            min: sortedV.first ?? 0, max: sortedV.last ?? 0, median: median,
            gmi: 3.31 + 0.02392 * mean,
            veryLow: vLow, low: low, inRange: pct { $0 >= 70 && $0 <= 180 }, tight: pct { $0 >= 70 && $0 <= 140 },
            high: high, veryHigh: vHigh,
            jIndex: 0.001 * (mean + sd) * (mean + sd),
            lbgi: lr / n, hbgi: hr / n, gri: gri,
            mage: mage(series), conga1: conga(series, hours: 1), modd: modd(series), adrr: adrr(series))
    }

    /// Kovatchev symmetrised risk transform: negative = hypo side, positive = hyper side.
    public static func risk(_ mgdl: Double) -> Double {
        let g = Swift.max(20, mgdl)
        return 1.509 * (pow(log(g), 1.084) - 5.381)
    }

    /// MAGE (Service 1970): mean of peak-to-nadir swings that exceed one SD, counted in the direction
    /// of the first qualifying excursion. Smoothed over 3 points first so sensor noise isn't counted.
    public static func mage(_ series: [GlucoseReading]) -> Double? {
        guard series.count >= 12 else { return nil }
        let raw = series.map(\.mgdl)
        var v = raw
        for i in 1..<(raw.count - 1) { v[i] = (raw[i - 1] + raw[i] + raw[i + 1]) / 3 }
        let mean = v.reduce(0, +) / Double(v.count)
        let sd = sqrt(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1))
        guard sd > 0 else { return nil }
        // Peak/nadir sequence: walk the series, closing an extremum only when the curve has moved at
        // least 1 SD back the other way. That both alternates and ignores sub-SD wiggles.
        var ext: [Double] = []
        var candidate = v[0]
        var rising: Bool? = nil
        for x in v.dropFirst() {
            switch rising {
            case nil:
                if x - candidate >= sd { ext.append(candidate); rising = true; candidate = x }
                else if candidate - x >= sd { ext.append(candidate); rising = false; candidate = x }
                else if abs(x - v[0]) > abs(candidate - v[0]) { candidate = x }
            case true?:
                if x > candidate { candidate = x }
                else if candidate - x >= sd { ext.append(candidate); rising = false; candidate = x }
            case false?:
                if x < candidate { candidate = x }
                else if x - candidate >= sd { ext.append(candidate); rising = true; candidate = x }
            }
        }
        ext.append(candidate)
        guard ext.count >= 2 else { return nil }
        var swings: [Double] = []
        for i in 1..<ext.count {
            let d = abs(ext[i] - ext[i - 1])
            if d >= sd { swings.append(d) }
        }
        return swings.isEmpty ? nil : swings.reduce(0, +) / Double(swings.count)
    }

    /// CONGA(n): SD of the differences between each reading and the one n hours earlier.
    public static func conga(_ series: [GlucoseReading], hours: Int) -> Double? {
        let lag = hours * 3600
        var d: [Double] = []
        for r in series {
            if let prev = GlucoseSeries.value(at: r.ts - lag, in: series, maxGapSeconds: 600) { d.append(r.mgdl - prev) }
        }
        guard d.count >= 6 else { return nil }
        let m = d.reduce(0, +) / Double(d.count)
        return sqrt(d.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(d.count - 1))
    }

    /// MODD: mean absolute difference between readings 24 h apart — day-to-day reproducibility.
    public static func modd(_ series: [GlucoseReading]) -> Double? {
        var d: [Double] = []
        for r in series {
            if let prev = GlucoseSeries.value(at: r.ts - 86_400, in: series, maxGapSeconds: 600) { d.append(abs(r.mgdl - prev)) }
        }
        return d.count >= 24 ? d.reduce(0, +) / Double(d.count) : nil
    }

    /// ADRR: mean over days of (max low-risk + max high-risk). Needs ≥ 2 days with ≥ 14 readings.
    public static func adrr(_ series: [GlucoseReading], calendar: Calendar = .current) -> Double? {
        var byDay: [DateComponents: (lr: Double, hr: Double, n: Int)] = [:]
        for r in series {
            let key = calendar.dateComponents([.year, .month, .day], from: r.date)
            let k = risk(r.mgdl)
            var e = byDay[key] ?? (0, 0, 0)
            if k < 0 { e.lr = Swift.max(e.lr, 10 * k * k) } else { e.hr = Swift.max(e.hr, 10 * k * k) }
            e.n += 1
            byDay[key] = e
        }
        let days = byDay.values.filter { $0.n >= 14 }
        guard days.count >= 2 else { return nil }
        return days.map { $0.lr + $0.hr }.reduce(0, +) / Double(days.count)
    }

    /// Hourly glucose profile (the "AGP" ambulatory glucose profile): median and 5/25/75/95th
    /// percentiles per hour of day across the window.
    public struct AGPHour: Equatable, Sendable {
        public let hour: Int
        public let p5, p25, p50, p75, p95: Double
        public let n: Int
    }

    public static func agp(_ series: [GlucoseReading], calendar: Calendar = .current) -> [AGPHour] {
        var buckets = [[Double]](repeating: [], count: 24)
        for r in series { buckets[calendar.component(.hour, from: r.date)].append(r.mgdl) }
        return buckets.enumerated().compactMap { h, vals in
            guard vals.count >= 3 else { return nil }
            let s = vals.sorted()
            func q(_ p: Double) -> Double {
                let x = p * Double(s.count - 1)
                let lo = Int(x.rounded(.down)), hi = Int(x.rounded(.up))
                return s[lo] + (s[hi] - s[lo]) * (x - Double(lo))
            }
            return AGPHour(hour: h, p5: q(0.05), p25: q(0.25), p50: q(0.5), p75: q(0.75), p95: q(0.95), n: s.count)
        }
    }
}
