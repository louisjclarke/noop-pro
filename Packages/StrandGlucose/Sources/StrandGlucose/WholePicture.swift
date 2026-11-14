import Foundation

/// One day's whole-body read-out: every domain NOOP Pro can see, scored 0–100 on a common scale, plus
/// the specific deviations that drove it. A domain is nil when there wasn't enough data — it is never
/// filled with a guess.
public struct WholePictureDay: Equatable, Sendable {
    public struct Domain: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let score: Double
        public let headline: String
    }

    public struct Flag: Equatable, Sendable, Identifiable {
        public enum Severity: Int, Sendable { case info = 0, watch = 1, act = 2 }
        public var id: String { text }
        public let severity: Severity
        public let text: String
    }

    public let day: String
    public let domains: [Domain]
    public let flags: [Flag]
    /// Weighted mean of the domains present; nil if fewer than two are.
    public let overall: Double?
}

/// Personal baseline for one metric: rolling median and a robust spread (1.4826 × MAD).
public struct Baseline: Equatable, Sendable {
    public let median: Double
    public let spread: Double
    public let n: Int

    public init?(_ values: [Double]) {
        let v = values.filter(\.isFinite).sorted()
        guard v.count >= 7 else { return nil }
        let med = Self.median(v)
        let mad = Self.median(v.map { abs($0 - med) }.sorted())
        median = med
        spread = max(1.4826 * mad, 1e-6)
        n = v.count
    }

    public func z(_ x: Double) -> Double { (x - median) / spread }

    static func median(_ s: [Double]) -> Double {
        s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

public enum WholePicture {
    /// Score `day` against the 30 days before it.
    public static func build(day: FusionDay, history: [FusionDay], glucose: GlucoseSummary?, night: NightGlucose?,
                             profile: GlucoseProfile, sleepNeedMin: Double = 480,
                             overnightGlucoseBaseline: Double? = nil, nightExplanation: NightExplanation? = nil) -> WholePictureDay {
        let prior = history.filter { $0.day < day.day }.suffix(30)
        var domains: [WholePictureDay.Domain] = []
        var flags: [WholePictureDay.Flag] = []

        if let r = day.recovery {
            domains.append(.init(name: "Recovery", score: r, headline: "\(Int(r.rounded()))% recovered"))
        }

        if let s = day.sleepMin {
            let score = max(0, min(100, s / sleepNeedMin * 100))
            let h = Int(s) / 60, m = Int(s) % 60
            domains.append(.init(name: "Sleep", score: score, headline: "\(h)h \(m)m of \(Int(sleepNeedMin / 60))h need"))
            if s < sleepNeedMin - 90 { flags.append(.init(severity: .watch, text: "Sleep was \(Int((sleepNeedMin - s).rounded())) min short of your need.")) }
        }

        if let st = day.strain, let rec = day.recovery {
            // Recovery-matched target band (WHOOP-style): a 33% day suits ~8–11, a 90% day ~14–18.
            let target = 6 + rec / 100 * 11
            let off = abs(st - target)
            domains.append(.init(name: "Load balance", score: max(0, 100 - off * 12),
                                 headline: String(format: "Strain %.1f vs %.1f suggested", st, target)))
        }

        if let g = glucose {
            let tit = g.timeInTarget(profile)
            let cvScore = max(0, min(100, (40 - g.cv) / 22 * 100))           // 18% → 100, 40% → 0
            let riskScore = max(0, 100 - g.gri * 2)
            let score = 0.5 * tit + 0.3 * cvScore + 0.2 * riskScore
            let unit = GlucoseUnit.mmol
            domains.append(.init(name: "Metabolic", score: score,
                                 headline: "\(Int(tit.rounded()))% in target · mean \(unit.format(g.mean)) · CV \(Int(g.cv.rounded()))%"))
            if g.veryLow > 0 { flags.append(.init(severity: .act, text: "Time below 3.0 mmol/L: \(String(format: "%.1f", g.veryLow))% of the day.")) }
            if g.cv > 36 { flags.append(.init(severity: .watch, text: "Glucose variability \(Int(g.cv.rounded()))% — above the 36% stability threshold.")) }
        }
        if let n = night {
            if !n.lows.isEmpty {
                flags.append(.init(severity: n.lows.contains(where: \.isLevel2) ? .act : .watch,
                                   text: "\(n.lows.count) overnight low\(n.lows.count == 1 ? "" : "s") (nadir \(GlucoseUnit.mmol.format(n.lows.map(\.nadir).min() ?? 0)) mmol/L)."))
            }
            if let gap = n.lastRiseToSleepMinutes, gap < 90, (n.lastRiseSize ?? 0) >= 30 {
                flags.append(.init(severity: .info, text: "Glucose was still rising \(Int(gap)) min before sleep — late eating tends to raise sleeping HR."))
            }
        }

        // Autonomic + vitals vs personal baseline.
        var autonomic: [Double] = []
        if let hrv = day.hrv, let b = Baseline(prior.compactMap(\.hrv)) {
            let z = b.z(hrv); autonomic.append(z)
            if z < -1.5 { flags.append(.init(severity: .watch, text: String(format: "HRV %.0f ms — well below your %.0f ms baseline.", hrv, b.median))) }
        }
        if let rhr = day.restingHr, let b = Baseline(prior.compactMap { $0.restingHr.map(Double.init) }) {
            let z = -b.z(Double(rhr)); autonomic.append(z)
            if Double(rhr) - b.median >= 5 { flags.append(.init(severity: .watch, text: "Resting HR \(rhr) — \(Int((Double(rhr) - b.median).rounded())) bpm above baseline.")) }
        }
        if !autonomic.isEmpty {
            let z = autonomic.reduce(0, +) / Double(autonomic.count)
            domains.append(.init(name: "Nervous system", score: max(0, min(100, 50 + z * 20)),
                                 headline: z >= 0.5 ? "Parasympathetic, well rested" : (z <= -0.5 ? "Under strain" : "Near your normal")))
        }
        if let t = day.skinTempDevC, t >= 0.5 {
            flags.append(.init(severity: t >= 1.0 ? .act : .watch, text: String(format: "Skin temperature +%.1f °C vs baseline.", t)))
        }
        if let rr = day.respRate, let b = Baseline(prior.compactMap(\.respRate)), rr - b.median >= 1.0 {
            flags.append(.init(severity: .watch, text: String(format: "Breathing rate %.1f/min, %.1f above baseline.", rr, rr - b.median)))
        }
        if let sp = day.spo2, sp < 93 {
            flags.append(.init(severity: .watch, text: String(format: "Overnight SpO₂ averaged %.0f%%.", sp)))
        }
        // Infection and inflammation push overnight glucose up alongside temperature and heart rate, so a
        // raised overnight glucose counts as one more vital in the illness pattern below.
        if let n = night, let b = overnightGlucoseBaseline, n.summary.mean - b >= 15 {
            flags.append(.init(severity: .watch, text: "Overnight glucose \(GlucoseUnit.mmol.format(n.summary.mean)) mmol/L — \(GlucoseUnit.mmol.format(n.summary.mean - b)) above your usual night."))
        }
        // Why last night's recovery inputs moved, from glucose.
        if let e = nightExplanation, e.glucoseLikelyContributed {
            // The low and late-meal facts already have their own flags above; add only the other reasons.
            for r in e.reasons where !r.hasPrefix("Glucose went low") && !r.hasPrefix("Your last glucose rise") {
                flags.append(.init(severity: .info, text: r))
            }
        }
        // Two or more vitals off at once is the classic early-illness pattern.
        let vitalHits = flags.filter { $0.text.hasPrefix("Resting HR") || $0.text.hasPrefix("Skin temperature") || $0.text.hasPrefix("Breathing rate") || $0.text.hasPrefix("HRV") || $0.text.hasPrefix("Overnight glucose") }.count
        if vitalHits >= 2 {
            flags.insert(.init(severity: .act, text: "Several vitals are off baseline together — a common early sign of illness or overreaching. Consider an easy day."), at: 0)
        }

        let weights: [String: Double] = ["Recovery": 0.25, "Sleep": 0.2, "Metabolic": 0.2, "Nervous system": 0.2, "Load balance": 0.15]
        let present = domains.compactMap { d in weights[d.name].map { (d.score, $0) } }
        let wsum = present.map(\.1).reduce(0, +)
        let overall = present.count >= 2 && wsum > 0 ? present.map { $0.0 * $0.1 }.reduce(0, +) / wsum : nil
        return WholePictureDay(day: day.day, domains: domains, flags: flags.sorted { $0.severity.rawValue > $1.severity.rawValue }, overall: overall)
    }
}
