import Foundation

/// A glucose rise — usually a meal, sometimes stress hormones or a hard effort. Detected without any
/// food log: a rise of at least `minRise` above a pre-rise baseline.
public struct GlucoseExcursion: Equatable, Sendable, Identifiable {
    public var id: Int { startTs }
    public let startTs: Int
    public let peakTs: Int
    /// When glucose came back within 10 mg/dL of baseline, nil if it hadn't by the end of the data.
    public let recoveredTs: Int?
    public let baseline: Double
    public let peak: Double
    /// Incremental area under the curve above baseline, mg/dL·h — the standard meal-response measure.
    public let iAUC: Double
    public var rise: Double { peak - baseline }
    public var minutesToPeak: Double { Double(peakTs - startTs) / 60 }
    public var minutesToRecover: Double? { recoveredTs.map { Double($0 - startTs) / 60 } }

    /// 0–100 "how gentle was this response". 100 = barely moved; 0 = a large, slow-to-clear spike.
    /// Built from rise (half), iAUC (third) and recovery time (sixth).
    public var responseScore: Double {
        let r = max(0, min(1, (rise - 15) / 85))           // 15 → 100 mg/dL rise
        let a = max(0, min(1, iAUC / 150))                 // 0 → 150 mg/dL·h
        let t = max(0, min(1, ((minutesToRecover ?? 240) - 60) / 180))
        return (1 - (0.5 * r + 0.33 * a + 0.17 * t)) * 100
    }
}

public struct GlucoseLowEvent: Equatable, Sendable, Identifiable {
    public var id: Int { startTs }
    public let startTs: Int
    public let endTs: Int
    public let nadir: Double
    public var minutes: Double { Double(endTs - startTs) / 60 + 5 }
    /// < 54 mg/dL (3.0 mmol/L) — the consensus "level 2".
    public var isLevel2: Bool { nadir < 54 }
}

public enum GlucoseEvents {
    /// Detect rises of ≥ `minRise` mg/dL. Baseline is the 30-minute minimum before the rise starts.
    public static func excursions(_ series: [GlucoseReading], minRise: Double = 30) -> [GlucoseExcursion] {
        guard series.count >= 6 else { return [] }
        var out: [GlucoseExcursion] = []
        var i = 0
        while i < series.count - 2 {
            let t = series[i].ts
            let window = GlucoseSeries.slice(series, from: t - 1800, to: t + 1)
            let baseline = window.map(\.mgdl).min() ?? series[i].mgdl
            // Rising start: two consecutive increases.
            guard series[i + 1].mgdl > series[i].mgdl, series[i + 2].mgdl > series[i + 1].mgdl else { i += 1; continue }
            // Follow to peak (allow one small dip so noise doesn't end it).
            var peakIdx = i
            var j = i + 1
            while j < series.count, series[j].ts - series[j - 1].ts <= 900 {
                if series[j].mgdl >= series[peakIdx].mgdl { peakIdx = j }
                else if series[peakIdx].mgdl - series[j].mgdl > 15 { break }
                j += 1
            }
            let peak = series[peakIdx].mgdl
            // A climb out of a low is a rebound (often from treating it), not a meal-type response.
            guard peak - baseline >= minRise, baseline >= 70 else { i = max(i + 1, peakIdx); continue }
            // Recovery & iAUC.
            var k = peakIdx
            var recovered: Int?
            while k < series.count, series[k].ts - series[peakIdx].ts <= 4 * 3600 {
                if series[k].mgdl <= baseline + 10 { recovered = series[k].ts; break }
                if k > peakIdx, series[k].ts - series[k - 1].ts > 900 { break }
                k += 1
            }
            let endIdx = min(k, series.count - 1)
            var auc = 0.0
            if endIdx > i {
                for m in (i + 1)...endIdx {
                    let dtH = Double(series[m].ts - series[m - 1].ts) / 3600
                    guard dtH <= 0.25 else { continue }
                    let a = max(0, series[m - 1].mgdl - baseline), b = max(0, series[m].mgdl - baseline)
                    auc += (a + b) / 2 * dtH
                }
            }
            out.append(GlucoseExcursion(startTs: series[i].ts, peakTs: series[peakIdx].ts, recoveredTs: recovered,
                                        baseline: baseline, peak: peak, iAUC: auc))
            i = max(endIdx, peakIdx + 1)
        }
        return out
    }

    /// Runs below `threshold` lasting ≥ 15 minutes (consensus event definition).
    public static func lows(_ series: [GlucoseReading], threshold: Double = 70, minMinutes: Double = 15) -> [GlucoseLowEvent] {
        var out: [GlucoseLowEvent] = []
        var start: Int?
        var nadir = Double.infinity
        var last = 0
        for r in series {
            if r.mgdl < threshold {
                if let _ = start, r.ts - last > 900 {
                    if Double(last - start!) / 60 + 5 >= minMinutes { out.append(GlucoseLowEvent(startTs: start!, endTs: last, nadir: nadir)) }
                    start = nil
                }
                if start == nil { start = r.ts; nadir = r.mgdl }
                nadir = min(nadir, r.mgdl)
                last = r.ts
            } else if let s = start {
                if Double(last - s) / 60 + 5 >= minMinutes { out.append(GlucoseLowEvent(startTs: s, endTs: last, nadir: nadir)) }
                start = nil
            }
        }
        if let s = start, Double(last - s) / 60 + 5 >= minMinutes { out.append(GlucoseLowEvent(startTs: s, endTs: last, nadir: nadir)) }
        return out
    }

    /// Dawn rise: mean 05:00–08:00 minus the overnight nadir between 00:00 and 05:00, for the night
    /// ending on `morning` (a date inside that morning). Nil if either window is too sparsely covered.
    public static func dawnRise(_ series: [GlucoseReading], morning: Date, calendar: Calendar = .current) -> Double? {
        let midnight = calendar.startOfDay(for: morning)
        let t0 = Int(midnight.timeIntervalSince1970)
        let night = GlucoseSeries.slice(series, from: t0, to: t0 + 5 * 3600)
        let dawn = GlucoseSeries.slice(series, from: t0 + 5 * 3600, to: t0 + 8 * 3600)
        guard night.count >= 24, dawn.count >= 18, let nadir = night.map(\.mgdl).min() else { return nil }
        return dawn.map(\.mgdl).reduce(0, +) / Double(dawn.count) - nadir
    }
}
