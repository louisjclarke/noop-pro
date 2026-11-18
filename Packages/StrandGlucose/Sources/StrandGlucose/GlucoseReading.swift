import Foundation

/// mg/dL per mmol/L for glucose (molar mass 180.16 g/mol).
public let mgdlPerMmol: Double = 18.0182

/// Where a glucose value came from. Ordered by trust: a value read off the sensor's own radio beats a
/// cloud relay, which beats the three-hour-delayed Apple Health copy.
public enum GlucoseSource: String, Codable, CaseIterable, Sendable {
    case g7Live = "g7_live"          // passive BLE, the 5-minute control-characteristic reading
    case g7Backfill = "g7_backfill"  // passive BLE, backfill records the Dexcom app requested
    case dexcomShare = "dexcom_share"
    case appleHealth = "apple_health"
    case manual = "manual"           // finger-prick entered by the wearer
    case clarity = "dexcom_clarity"  // imported from a Dexcom Clarity CSV export (history)

    public var priority: Int {
        switch self {
        case .g7Live: return 5
        case .g7Backfill: return 4
        case .manual: return 3
        case .dexcomShare: return 2
        case .clarity: return 2
        case .appleHealth: return 1
        }
    }
}

/// Dexcom's arrow, derived from rate of change (mg/dL per minute).
public enum GlucoseTrend: Int, Codable, Sendable, CaseIterable {
    case doubleDown = -3, singleDown = -2, fortyFiveDown = -1, flat = 0, fortyFiveUp = 1, singleUp = 2, doubleUp = 3

    public init(ratePerMinute r: Double) {
        switch r {
        case ..<(-3.0): self = .doubleDown
        case ..<(-2.0): self = .singleDown
        case ..<(-1.0): self = .fortyFiveDown
        case ..<1.0: self = .flat
        case ..<2.0: self = .fortyFiveUp
        case ..<3.0: self = .singleUp
        default: self = .doubleUp
        }
    }

    public var arrow: String {
        switch self {
        case .doubleDown: return "↓↓"
        case .singleDown: return "↓"
        case .fortyFiveDown: return "↘"
        case .flat: return "→"
        case .fortyFiveUp: return "↗"
        case .singleUp: return "↑"
        case .doubleUp: return "↑↑"
        }
    }
}

/// One glucose value. `ts` is wall-clock unix seconds of the *measurement* (not of the radio packet).
public struct GlucoseReading: Codable, Equatable, Hashable, Sendable {
    public let ts: Int
    public let mgdl: Double
    /// mg/dL per minute, when the source supplied one.
    public let ratePerMinute: Double?
    public let source: GlucoseSource
    /// Sensor serial / BLE name when known (e.g. "DXCM4K"), so a sensor change is visible in the data.
    public let sensorId: String?

    public init(ts: Int, mgdl: Double, ratePerMinute: Double? = nil, source: GlucoseSource, sensorId: String? = nil) {
        self.ts = ts
        self.mgdl = mgdl
        self.ratePerMinute = ratePerMinute
        self.source = source
        self.sensorId = sensorId
    }

    public var mmol: Double { mgdl / mgdlPerMmol }
    public var trend: GlucoseTrend? { ratePerMinute.map(GlucoseTrend.init(ratePerMinute:)) }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

public enum GlucoseUnit: String, Codable, CaseIterable, Sendable {
    case mmol, mgdl

    public func format(_ mgdl: Double) -> String {
        switch self {
        case .mmol: return String(format: "%.1f", mgdl / mgdlPerMmol)
        case .mgdl: return String(format: "%.0f", mgdl)
        }
    }

    public var label: String { self == .mmol ? "mmol/L" : "mg/dL" }
}

public enum GlucoseSeries {
    /// Merge readings from every source into one 5-minute-resolution series. Readings within
    /// `bucketSeconds` of each other are treated as the same measurement and the higher-priority source
    /// wins. Output is sorted ascending and physiologically implausible values are dropped.
    public static func merge(_ readings: [GlucoseReading], bucketSeconds: Int = 150) -> [GlucoseReading] {
        let plausible = readings.filter { $0.mgdl >= 20 && $0.mgdl <= 600 }
        let sorted = plausible.sorted { $0.ts == $1.ts ? $0.source.priority > $1.source.priority : $0.ts < $1.ts }
        var out: [GlucoseReading] = []
        out.reserveCapacity(sorted.count)
        for r in sorted {
            if let last = out.last, r.ts - last.ts < bucketSeconds {
                if r.source.priority > last.source.priority { out[out.count - 1] = r }
                continue
            }
            out.append(r)
        }
        return out
    }

    /// Fill in a rate of change for readings that lack one, from the neighbouring readings.
    public static func withRates(_ series: [GlucoseReading]) -> [GlucoseReading] {
        guard series.count >= 2 else { return series }
        var out = series
        for i in 0..<series.count where series[i].ratePerMinute == nil {
            let j = max(0, i - 1)
            let k = min(series.count - 1, i + 1)
            let dt = Double(series[k].ts - series[j].ts) / 60
            guard dt > 0, dt <= 20 else { continue }
            let rate = (series[k].mgdl - series[j].mgdl) / dt
            out[i] = GlucoseReading(ts: series[i].ts, mgdl: series[i].mgdl, ratePerMinute: rate,
                                    source: series[i].source, sensorId: series[i].sensorId)
        }
        return out
    }

    /// Readings with `from <= ts < to`. Input must be sorted.
    public static func slice(_ series: [GlucoseReading], from: Int, to: Int) -> [GlucoseReading] {
        guard !series.isEmpty, from < to else { return [] }
        let lo = lowerBound(series, from)
        let hi = lowerBound(series, to)
        return lo < hi ? Array(series[lo..<hi]) : []
    }

    /// Linear interpolation at `ts`, refusing to bridge gaps longer than `maxGapSeconds`.
    public static func value(at ts: Int, in series: [GlucoseReading], maxGapSeconds: Int = 900) -> Double? {
        guard !series.isEmpty else { return nil }
        let i = lowerBound(series, ts)
        if i < series.count, series[i].ts == ts { return series[i].mgdl }
        guard i > 0, i < series.count else {
            if i == 0, series[0].ts - ts <= maxGapSeconds / 2 { return series[0].mgdl }
            if i == series.count, ts - series[series.count - 1].ts <= maxGapSeconds / 2 { return series[series.count - 1].mgdl }
            return nil
        }
        let a = series[i - 1], b = series[i]
        guard b.ts - a.ts <= maxGapSeconds else { return nil }
        let f = Double(ts - a.ts) / Double(b.ts - a.ts)
        return a.mgdl + f * (b.mgdl - a.mgdl)
    }

    static func lowerBound(_ s: [GlucoseReading], _ ts: Int) -> Int {
        var lo = 0, hi = s.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if s[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
